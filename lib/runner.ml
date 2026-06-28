type run_error =
  [ `Close_event_error of int * Close_event.create_error
  | `Output_event_error of int * Output_event.create_error
  | `Run_result_error of Run_result.create_error
  | `Unsupported_kill_signal of string
  | `Unexpected_runner_error of string ]

type running_process_kind = Main_command | Teardown_command

type running_process = {
  command_index : int;
  command : Command.t;
  process : Runner_backend.process;
  kind : running_process_kind;
}

type pending_teardown_signal_error = {
  error_command_index : int;
  error_command : Command.t;
  failed_signal : int;
  error_message : string;
}

type pending_teardown_parent_signal = {
  signal_command_index : int;
  delivered_signal : int;
}

type command_result = Closed of Close_event.t | Skipped | Failed of run_error

exception Fatal_runner_error of run_error

let output_event_create_error_message = function
  | `Invalid_next_attempt (attempt, next_attempt) ->
      Printf.sprintf "invalid next attempt %d for attempt %d" next_attempt
        attempt
  | `Negative_attempt -> "negative attempt"
  | `Negative_delay_ms -> "negative delay"

let impossible_output_event context error =
  raise
    (Fatal_runner_error
       (`Unexpected_runner_error
          (Printf.sprintf "Runner.%s: %s" context
             (output_event_create_error_message error))))

let impossible_command_result context =
  raise
    (Fatal_runner_error
       (`Unexpected_runner_error
          (Printf.sprintf "Runner.%s: skipped command result" context)))

let with_parent_termination_signals ~cleanup run =
  let previous_handlers = ref [] in
  let received_signal = ref None in
  let restore_handlers () =
    List.iter
      (fun (signal, previous_handler) -> Sys.set_signal signal previous_handler)
      !previous_handlers
  in
  let handle signal =
    if Option.is_none !received_signal then received_signal := Some signal;
    cleanup signal
  in
  let install_signal_handler signal =
    match Sys.signal signal (Sys.Signal_handle handle) with
    | previous_handler -> Some (signal, previous_handler)
    | exception Invalid_argument _ -> None
  in
  previous_handlers :=
    List.filter_map install_signal_handler
      [ Sys.sighup; Sys.sigint; Sys.sigterm ];
  let result = Fun.protect ~finally:restore_handlers run in
  match !received_signal with
  | None -> `Completed result
  | Some signal -> `Interrupted (signal, result)

let create_lifecycle_event ~command ~attempt lifecycle =
  match Output_event.lifecycle ~command ~attempt ~lifecycle with
  | Ok event -> event
  | Error error -> impossible_output_event "create_lifecycle_event" error

let create_lifecycle_event_with_process_id ~process_id ~command ~attempt
    lifecycle =
  match
    Output_event.lifecycle_with_process_id ~process_id ~command ~attempt
      ~lifecycle
  with
  | Ok event -> event
  | Error error ->
      impossible_output_event "create_lifecycle_event_with_process_id" error

let emit_lifecycle ~emit_event ~command ~attempt lifecycle =
  create_lifecycle_event ~command ~attempt lifecycle |> emit_event

let emit_lifecycle_with_process_id ~process_id ~emit_event ~command ~attempt
    lifecycle =
  create_lifecycle_event_with_process_id ~process_id ~command ~attempt lifecycle
  |> emit_event

let emit_lifecycle_best_effort ~emit_event ~command ~attempt lifecycle =
  match emit_lifecycle ~emit_event ~command ~attempt lifecycle with
  | () -> ()
  | exception _ -> ()

let emit_lifecycle_with_process_id_best_effort ~process_id ~emit_event ~command
    ~attempt lifecycle =
  match
    emit_lifecycle_with_process_id ~process_id ~emit_event ~command ~attempt
      lifecycle
  with
  | () -> ()
  | exception _ -> ()

let stopped_lifecycle close_event =
  Output_event.Stopped_with_status
    {
      status = Close_event.status close_event;
      killed = Close_event.killed close_event;
    }

let create_close_event ~command ~attempt ~killed ~status ~started_at ~ended_at =
  match
    Close_event.create ~command ~attempt ~killed ~status ~started_at ~ended_at
  with
  | Ok close_event -> Closed close_event
  | Error error -> Failed (`Close_event_error (Command.index command, error))

let signaled_status signal =
  Close_event.Signaled (string_of_int (Sys.signal_to_int signal))

let cancelled_close_event ~now ~attempt ~signal command =
  let timestamp = now () in
  create_close_event ~command ~attempt ~killed:true
    ~status:(signaled_status signal) ~started_at:timestamp ~ended_at:timestamp

let teardown_error_event ~command ~message =
  match
    Output_event.output_chunk ~command ~attempt:0 ~process_id:None
      ~stream:Output_event.Stderr ~chunk:message ~line_terminated:true
  with
  | Ok event -> event
  | Error error -> impossible_output_event "teardown_error_event" error

let teardown_spawn_error_event ~command ~message =
  teardown_error_event ~command
    ~message:("teardown command failed to spawn: " ^ message)

let timer_warning_message = function
  | Run_policy.Timeout_nan ->
      Printf.sprintf
        "(node:%d) TimeoutNaNWarning: NaN is not a number.\n\
         Timeout duration was set to 1.\n\
         (Use `node --trace-warnings ...` to show where the warning was \
         created)\n"
        (Unix.getpid ())
  | Run_policy.Timeout_negative value ->
      Printf.sprintf
        "(node:%d) TimeoutNegativeWarning: %s is a negative number.\n\
         Timeout duration was set to 1.\n\
         (Use `node --trace-warnings ...` to show where the warning was \
         created)\n"
        (Unix.getpid ()) value

let normalized_kill_timeout_ms timeout_ms =
  if timeout_ms < 0 then 1 else timeout_ms

let run ~input ~input_source ~backend ~now ~sleep ~spec ~on_output_event =
  let commands = Run_spec.commands spec in
  let command_count = List.length commands in
  let policy = Run_spec.policy spec in
  let stdin_should_follow_input =
    Option.is_some input && Option.is_some input_source
  in
  let run_after_validation () =
    let max_processes =
      match Run_policy.max_processes policy with
      | None -> max 1 command_count
      | Some value -> max 1 (min value command_count)
    in
    let output_event_count = ref 0 in
    let parent_signal = ref None in
    let parent_signal_generation = ref 0 in
    let parent_signal_skipped_command_indexes = ref [] in
    let parent_signal_pending_starting_commands = ref [] in
    let parent_signal_forwarded_command_attempts = ref [] in
    let termination_signal = ref None in
    let termination_cancelled = ref false in
    let running_processes : running_process list ref = ref [] in
    let input_queue = Runner_input_queue.create ~command_count () in
    let active_command_indexes = ref [] in
    let starting_command_indexes = ref [] in
    let exited_command_indexes = ref [] in
    let retry_pending_command_indexes = ref [] in
    let killed_command_indexes = ref [] in
    let force_killed_command_indexes = ref [] in
    let timed_out_cleanup_signals = ref [] in
    let pending_force_kill_completions = Hashtbl.create command_count in
    let closed_command_indexes = ref [] in
    let current_attempts = Array.make command_count 0 in
    let state_mutex = Eio.Mutex.create () in
    let event_mutex = Eio.Mutex.create () in
    let error_mutex = Eio.Mutex.create () in
    let restart_delay_warning_emitted = ref false in
    let kill_timeout_warning_emitted = ref false in
    let pending_teardown_signal_errors :
        pending_teardown_signal_error list ref =
      ref []
    in
    let pending_teardown_parent_signals :
        pending_teardown_parent_signal list ref =
      ref []
    in
    let teardown_parent_signal_delivery_generations = ref [] in
    let run_errors = ref [] in
    let close_events =
      Eio.Stream.create (max 1 (Run_spec.close_event_capacity spec))
    in
    let process_slots = Eio.Semaphore.make max_processes in
    let emit event =
      Eio.Mutex.use_rw ~protect:true event_mutex (fun () ->
          incr output_event_count;
          on_output_event event)
    in
    let emit_best_effort event =
      match emit event with () -> () | exception _ -> ()
    in
    let emit_timer_warning warning =
      Output_event.runtime_warning ~stream:Output_event.Stderr
        ~chunk:(timer_warning_message warning)
      |> emit_best_effort
    in
    let emit_once emitted warning =
      if not !emitted then (
        emitted := true;
        emit_timer_warning warning)
    in
    let emit_kill_status ~after_command =
      Output_event.status_message ~after_command:(Some after_command)
        ~stream:Output_event.Stdout
        ~chunk:
          (Printf.sprintf "--> Sending %s to other processes.."
             (Process_signal.kill_label (Run_policy.kill_signal policy)))
      |> emit_best_effort
    in
    let record_failure error =
      Eio.Mutex.use_rw ~protect:true error_mutex (fun () ->
          run_errors := error :: !run_errors);
      Eio.Stream.add close_events (Failed error)
    in
    let recorded_failure () =
      Eio.Mutex.use_ro error_mutex (fun () ->
          match List.rev !run_errors with
          | [] -> None
          | error :: _ -> Some error)
    in
    let emit_lifecycle ~command ~attempt lifecycle =
      emit_lifecycle ~emit_event:emit ~command ~attempt lifecycle
    in
    let emit_lifecycle_with_process_id ~process_id ~command ~attempt lifecycle =
      emit_lifecycle_with_process_id ~process_id ~emit_event:emit ~command
        ~attempt lifecycle
    in
    let remove_running command_index =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          teardown_parent_signal_delivery_generations :=
            List.remove_assoc command_index
              !teardown_parent_signal_delivery_generations;
          pending_teardown_parent_signals :=
            List.filter
              (fun pending_signal ->
                pending_signal.signal_command_index <> command_index)
              !pending_teardown_parent_signals;
          timed_out_cleanup_signals :=
            List.remove_assoc command_index !timed_out_cleanup_signals;
          running_processes :=
            List.filter
              (fun process -> process.command_index <> command_index)
              !running_processes;
          exited_command_indexes :=
            List.filter
              (fun exited_command_index ->
                exited_command_index <> command_index)
              !exited_command_indexes)
    in
    let mark_exited command_index =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          exited_command_indexes :=
            command_index :: !exited_command_indexes
            |> List.sort_uniq Int.compare)
    in
    let remove_pending_parent_signal command_index =
      parent_signal_pending_starting_commands :=
        List.filter
          (fun (pending_command_index, _) ->
            pending_command_index <> command_index)
          !parent_signal_pending_starting_commands
    in
    let take_parent_signal_skipped_command command_index =
      let skipped =
        List.mem command_index !parent_signal_skipped_command_indexes
      in
      if skipped then
        parent_signal_skipped_command_indexes :=
          List.filter
            (fun skipped_command_index ->
              skipped_command_index <> command_index)
            !parent_signal_skipped_command_indexes;
      skipped
    in
    let mark_command_starting_attempt command_index attempt =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          current_attempts.(command_index) <- attempt;
          if
            Option.is_some !termination_signal
            || List.mem command_index !closed_command_indexes
          then false
          else (
            retry_pending_command_indexes :=
              List.filter
                (fun retry_command_index ->
                  retry_command_index <> command_index)
                !retry_pending_command_indexes;
            active_command_indexes :=
              command_index :: !active_command_indexes
              |> List.sort_uniq Int.compare;
            starting_command_indexes :=
              command_index :: !starting_command_indexes
              |> List.sort_uniq Int.compare;
            true))
    in
    let remove_active command_index =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          active_command_indexes :=
            List.filter
              (fun active_command_index ->
                active_command_index <> command_index)
              !active_command_indexes)
    in
    let remove_starting command_index =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          starting_command_indexes :=
            List.filter
              (fun starting_command_index ->
                starting_command_index <> command_index)
              !starting_command_indexes)
    in
    let command_was_killed command_index =
      Eio.Mutex.use_ro state_mutex (fun () ->
          List.mem command_index !killed_command_indexes)
    in
    let command_was_force_killed command_index =
      Eio.Mutex.use_ro state_mutex (fun () ->
          List.mem command_index !force_killed_command_indexes)
    in
    let command_timed_out_cleanup_signal command_index =
      Eio.Mutex.use_ro state_mutex (fun () ->
          List.assoc_opt command_index !timed_out_cleanup_signals)
    in
    let pending_force_kill_completion command_index =
      Eio.Mutex.use_ro state_mutex (fun () ->
          Hashtbl.find_opt pending_force_kill_completions command_index)
    in
    let remove_pending_force_kill command_index =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          Hashtbl.remove pending_force_kill_completions command_index)
    in
    let pending_force_kill_is_current command_index completion =
      Eio.Mutex.use_ro state_mutex (fun () ->
          match Hashtbl.find_opt pending_force_kill_completions command_index with
          | Some (current_completion, _) -> current_completion == completion
          | None -> false)
    in
    let pending_force_kill_for_status ~process_status:_ command_index =
      match pending_force_kill_completion command_index with
      | None -> None
      | Some (completion, _initial_signal) -> Some completion
    in
    let command_is_closed command_index =
      Eio.Mutex.use_ro state_mutex (fun () ->
          List.mem command_index !closed_command_indexes)
    in
    let command_is_running command_index =
      Eio.Mutex.use_ro state_mutex (fun () ->
          List.exists
            (fun process -> process.command_index = command_index)
            !running_processes)
    in
    let rec command_running_after_yields command_index remaining_yields =
      if not (command_is_running command_index) then false
      else if remaining_yields = 0 then true
      else (
        Eio.Fiber.yield ();
        command_running_after_yields command_index (remaining_yields - 1))
    in
    let process_for_input command_index =
      Eio.Mutex.use_ro state_mutex (fun () ->
          List.find_opt
            (fun process -> process.command_index = command_index)
            !running_processes)
    in
    let write_process_input command_index process payload =
      match process.Runner_backend.write_stdin payload with
      | () -> ()
      | exception exn ->
          if command_running_after_yields command_index 8 then
            record_failure (`Unexpected_runner_error (Printexc.to_string exn))
          else ()
    in
    let missing_input_target_emitted = Hashtbl.create 4 in
    let emit_missing_input_target target =
      let count =
        match Hashtbl.find_opt missing_input_target_emitted target with
        | Some n -> n
        | None -> 0
      in
      if count < 3 then (
        Hashtbl.replace missing_input_target_emitted target (count + 1);
        Output_event.status_message ~after_command:None
          ~stream:Output_event.Stdout
          ~chunk:
            (Printf.sprintf
               "--> Unable to find command \"%s\", or it has no stdin open\n--> "
               target)
        |> emit_best_effort)
    in
    let close_process_stdin process =
      match process.Runner_backend.close_stdin () with
      | () -> ()
      | exception exn ->
          record_failure
            (`Unexpected_runner_error
               ("close_stdin failed: " ^ Printexc.to_string exn))
    in
    let write_input route =
      match process_for_input route.Input_router.target_index with
      | Some running_process ->
          write_process_input route.Input_router.target_index
            running_process.process route.Input_router.payload
      | None -> (
          let enqueue_result =
            Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                Runner_input_queue.enqueue input_queue
                  ~closed_command_indexes:!closed_command_indexes route)
          in
          match enqueue_result with
          | Runner_input_queue.Queued -> ()
          | Runner_input_queue.Missing target ->
              emit_missing_input_target target
          | Runner_input_queue.Overflow ->
              record_failure
                (`Unexpected_runner_error
                   "pending input buffer exceeded for command"))
    in
    let close_running_stdins () =
      let processes =
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
            Runner_input_queue.mark_source_closed input_queue;
            !running_processes)
      in
      List.iter
        (fun running_process -> close_process_stdin running_process.process)
        processes
    in
    let run_input_router router source =
      Runner_input_reader.read ~source ~router ~write_input
        ~close_running_stdins ~record_unexpected_error:(fun message ->
          record_failure (`Unexpected_runner_error message))
    in
    let queue_teardown_parent_signal command_index signal =
      pending_teardown_parent_signals :=
        { signal_command_index = command_index; delivered_signal = signal }
        :: !pending_teardown_parent_signals
    in
    let queue_teardown_signal_error ~command_index ~command ~signal ~error_message
        =
      pending_teardown_signal_errors :=
        {
          error_command_index = command_index;
          error_command = command;
          failed_signal = signal;
          error_message;
        }
        :: !pending_teardown_signal_errors
    in
    let signal_running_process_groups signal =
      let current_generation = !parent_signal_generation in
      let signaled_main_command_indexes = ref [] in
      List.iter
        (fun running_process ->
          match running_process.process.signal signal with
          | Ok true -> (
              match running_process.kind with
              | Main_command ->
                  signaled_main_command_indexes :=
                    running_process.command_index
                    :: !signaled_main_command_indexes
              | Teardown_command ->
                  queue_teardown_parent_signal running_process.command_index
                    signal;
                  teardown_parent_signal_delivery_generations :=
                    (running_process.command_index, current_generation)
                    :: List.remove_assoc running_process.command_index
                         !teardown_parent_signal_delivery_generations)
          | Ok false -> ()
          | Error message -> (
              match running_process.kind with
              | Main_command -> ()
              | Teardown_command ->
                  queue_teardown_signal_error
                    ~command_index:running_process.command_index
                    ~command:running_process.command ~signal
                    ~error_message:message))
        !running_processes;
      List.rev !signaled_main_command_indexes
    in
    let signal_process_after_parent_termination command_index process signal =
      match process.Runner_backend.signal signal with
      | Ok true ->
          Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
              parent_signal_forwarded_command_attempts :=
                (command_index, current_attempts.(command_index))
                :: !parent_signal_forwarded_command_attempts
                |> List.sort_uniq Stdlib.compare;
              killed_command_indexes :=
                command_index :: !killed_command_indexes
                |> List.sort_uniq Int.compare)
      | Ok false -> ()
      | Error message ->
          if command_running_after_yields command_index 32 then
            record_failure (`Unexpected_runner_error message)
          else ()
    in
    let force_kill_after_timeout ~sw ~initial_signal running_processes =
      match (running_processes, Run_policy.kill_timeout_ms policy) with
      | [], _ | _, None | _, Some 0 -> ()
      | _, Some timeout_ms when initial_signal = Sys.sigkill -> ()
      | _, Some timeout_ms ->
          Option.iter (emit_once kill_timeout_warning_emitted)
            (Run_policy.kill_timeout_warning policy);
          let pending_force_kills =
            Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                running_processes
                |> List.filter_map (fun running_process ->
                       match
                         Hashtbl.find_opt pending_force_kill_completions
                           running_process.command_index
                       with
                       | Some _ -> None
                       | None ->
                           let completion, resolve_completion =
                             Eio.Promise.create ()
                           in
                           Hashtbl.add pending_force_kill_completions
                             running_process.command_index
                             (completion, initial_signal);
                           Some (running_process, completion, resolve_completion)))
          in
          if pending_force_kills <> [] then
            let complete_pending_force_kills () =
              List.iter
                (fun (running_process, completion, resolve_completion) ->
                  ignore (Eio.Promise.try_resolve resolve_completion ());
                  if
                    pending_force_kill_is_current running_process.command_index
                      completion
                  then remove_pending_force_kill running_process.command_index)
                pending_force_kills
            in
            Eio.Fiber.fork_daemon ~sw (fun () ->
                (match
                   Fun.protect ~finally:complete_pending_force_kills (fun () ->
                       sleep
                         (float_of_int (normalized_kill_timeout_ms timeout_ms)
                         /. 1000.0);
                       let force_kill_results =
                         pending_force_kills
                         |> List.filter_map
                              (fun (running_process, completion, _) ->
                                if
                                  not
                                    (pending_force_kill_is_current
                                       running_process.command_index completion)
                                then None
                                else
                                  let root_already_exited =
                                    Eio.Mutex.use_ro state_mutex (fun () ->
                                        List.mem running_process.command_index
                                          !exited_command_indexes)
                                  in
                                  match
                                    running_process.process.Runner_backend.signal
                                      Sys.sigkill
                                  with
                                  | Ok true ->
                                      Some (running_process, root_already_exited)
                                  | Ok false -> None
                                  | Error message ->
                                      if
                                        command_running_after_yields
                                          running_process.command_index 32
                                      then
                                        record_failure
                                          (`Unexpected_runner_error message);
                                      None)
                       in
                       if force_kill_results <> [] then
                         Output_event.status_message ~after_command:None
                           ~stream:Output_event.Stdout
                           ~chunk:
                             (Printf.sprintf
                                "--> Sending SIGKILL to %d processes.."
                                (List.length force_kill_results))
                         |> emit_best_effort;
                       let root_force_killed_command_indexes =
                         force_kill_results
                         |> List.filter_map
                              (fun (running_process, root_already_exited) ->
                                if root_already_exited then None
                                else Some running_process.command_index)
                       in
                       if force_kill_results <> [] then
                         Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                             timed_out_cleanup_signals :=
                               force_kill_results
                               |> List.map (fun (running_process, _) ->
                                      (running_process.command_index, initial_signal))
                               |> List.rev_append !timed_out_cleanup_signals
                               |> List.sort_uniq (fun (left_index, _) (right_index, _) ->
                                      Int.compare left_index right_index);
                             force_killed_command_indexes :=
                               root_force_killed_command_indexes
                               |> List.rev_append !force_killed_command_indexes
                               |> List.sort_uniq Int.compare))
                 with
                | () ->
                    ()
                | exception _ -> ());
                `Stop_daemon)
    in
    let close_event_completes_command close_event =
      Run_policy.close_event_completes_command policy close_event
    in
    let add_close_event ?(collect = true) ?(complete = true) close_event =
      let command_index = Command.index (Close_event.command close_event) in
      if complete && close_event_completes_command close_event then
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
            closed_command_indexes :=
              command_index :: !closed_command_indexes
              |> List.sort_uniq Int.compare;
            retry_pending_command_indexes :=
              List.filter
                (fun retry_command_index ->
                  retry_command_index <> command_index)
                !retry_pending_command_indexes);
      if collect then Eio.Stream.add close_events (Closed close_event)
    in
    let add_command_result = function
      | Closed close_event -> add_close_event close_event
      | Skipped -> Eio.Stream.add close_events Skipped
      | Failed error -> record_failure error
    in
    let parent_signal_skippable_commands () =
      let running_indexes =
        List.map
          (fun running_process -> running_process.command_index)
          !running_processes
      in
      let active_indexes = !active_command_indexes in
      let starting_indexes = !starting_command_indexes in
      let retry_pending_indexes = !retry_pending_command_indexes in
      commands
      |> List.filter (fun command ->
             let command_index = Command.index command in
             (not (List.mem command_index !closed_command_indexes))
             && (not (List.mem command_index running_indexes))
             && (not (List.mem command_index active_indexes))
             && (not (List.mem command_index starting_indexes))
             && not (List.mem command_index retry_pending_indexes))
    in
    let cancel_non_running_commands signal =
      let commands_to_skip, commands_to_cancel =
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
            let running_indexes =
              List.map
                (fun running_process -> running_process.command_index)
                !running_processes
            in
            let active_indexes = !active_command_indexes in
            let starting_indexes = !starting_command_indexes in
            let non_running_commands =
              commands
              |> List.filter (fun command ->
                  let command_index = Command.index command in
                  (not (List.mem command_index !closed_command_indexes))
                  && not (List.mem command_index running_indexes))
            in
            let commands_to_skip, commands_to_cancel =
              List.partition
                (fun command ->
                  let command_index = Command.index command in
                  (not (List.mem command_index active_indexes))
                  && not (List.mem command_index starting_indexes))
                non_running_commands
            in
            let skipped_command_indexes =
              List.map Command.index commands_to_skip
            in
            let cancelled_command_indexes =
              List.map Command.index commands_to_cancel
            in
            killed_command_indexes :=
              cancelled_command_indexes
              |> List.rev_append !killed_command_indexes
              |> List.sort_uniq Int.compare;
            closed_command_indexes :=
              skipped_command_indexes
              |> List.rev_append cancelled_command_indexes
              |> List.rev_append !closed_command_indexes
              |> List.sort_uniq Int.compare;
            (commands_to_skip, commands_to_cancel))
      in
      List.iter
        (fun _command -> Eio.Stream.add close_events Skipped)
        commands_to_skip;
      commands_to_cancel
      |> List.map (fun command ->
          let attempt =
            Eio.Mutex.use_ro state_mutex (fun () ->
                current_attempts.(Command.index command))
          in
          (command, attempt, cancelled_close_event ~now ~attempt ~signal command))
      |> List.iter (fun (command, attempt, result) ->
          add_command_result result;
          match result with
          | Closed close_event ->
              emit_lifecycle_best_effort ~emit_event:emit ~command ~attempt
                (stopped_lifecycle close_event)
          | Skipped -> ()
          | Failed _ -> ())
    in
    let cancel_terminated_commands_once () =
      match !termination_signal with
      | Some signal when not !termination_cancelled ->
          termination_cancelled := true;
          cancel_non_running_commands signal
      | Some _ | None -> ()
    in
    let signal_siblings ~sw close_event =
      let closing_index = Command.index (Close_event.command close_event) in
      let processes_to_signal, commands_to_cancel, skipped_command_count =
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
            let siblings =
              List.filter
                (fun process ->
                  process.command_index <> closing_index
                  && not
                       (List.mem process.command_index !exited_command_indexes))
                !running_processes
            in
            let running_indexes =
              List.map (fun process -> process.command_index) siblings
            in
            let active_indexes = !active_command_indexes in
            let starting_indexes = !starting_command_indexes in
            let retry_pending_indexes = !retry_pending_command_indexes in
            let pending_commands =
              List.filter
                (fun command ->
                  let command_index = Command.index command in
                  command_index <> closing_index
                  && (not (List.mem command_index !closed_command_indexes))
                  && (not (List.mem command_index running_indexes))
                  && (not (List.mem command_index active_indexes))
                  (* npm concurrently does not cancel a command whose failed
                   attempt already committed to a retry backoff when a sibling
                   later satisfies kill-others. The retry lifecycle keeps the
                   command's max-processes slot and is allowed to finish. *)
                  && not (List.mem command_index retry_pending_indexes))
                commands
            in
            let starting_commands =
              List.filter
                (fun command ->
                  let command_index = Command.index command in
                  command_index <> closing_index
                  && (not (List.mem command_index !closed_command_indexes))
                  && List.mem command_index starting_indexes
                  && not (List.mem command_index running_indexes))
                commands
            in
            let pending_command_indexes = List.map Command.index pending_commands in
            let commands_to_cancel = starting_commands in
            let cancelled_command_indexes = List.map Command.index commands_to_cancel in
            let closed_without_close_event_indexes =
              List.rev_append pending_command_indexes cancelled_command_indexes
            in
            killed_command_indexes :=
              cancelled_command_indexes
              |> List.rev_append !killed_command_indexes
              |> List.sort_uniq Int.compare;
            closed_command_indexes :=
              closed_without_close_event_indexes
              |> List.rev_append !closed_command_indexes
              |> List.sort_uniq Int.compare;
            (siblings, commands_to_cancel, List.length pending_commands))
      in
      for _index = 1 to skipped_command_count do
        Eio.Stream.add close_events Skipped
      done;
      if processes_to_signal <> [] || commands_to_cancel <> [] then
        emit_kill_status ~after_command:(Close_event.command close_event);
      if processes_to_signal = [] && commands_to_cancel = [] then Ok []
      else
        match Process_signal.number (Run_policy.kill_signal policy) with
        | Error error -> Error (error :> run_error)
        | Ok signal ->
          let signaled_processes, signal_errors =
            processes_to_signal
            |> List.fold_left
                 (fun (signaled_processes, signal_errors) running_process
                    ->
                   match running_process.process.signal signal with
                   | Ok true ->
                       (running_process :: signaled_processes, signal_errors)
                   | Ok false -> (signaled_processes, signal_errors)
                   | Error message ->
                       if
                         command_running_after_yields
                           running_process.command_index 32
                       then
                         ( signaled_processes,
                           `Unexpected_runner_error message :: signal_errors )
                       else (signaled_processes, signal_errors))
                 ([], [])
          in
          match List.rev signal_errors with
          | error :: _ -> Error error
          | [] ->
              let signaled_processes = List.rev signaled_processes in
              let signaled_command_indexes =
                List.map
                  (fun running_process -> running_process.command_index)
                  signaled_processes
              in
              Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                  killed_command_indexes :=
                    signaled_command_indexes
                    |> List.rev_append !killed_command_indexes
                    |> List.sort_uniq Int.compare);
              force_kill_after_timeout ~sw ~initial_signal:signal
                signaled_processes;
              let cancelled_stop_events =
                commands_to_cancel
                |> List.filter_map (fun command ->
                    let attempt =
                      Eio.Mutex.use_ro state_mutex (fun () ->
                          current_attempts.(Command.index command))
                    in
                    match
                      cancelled_close_event ~now ~attempt ~signal command
                    with
                    | Closed close_event ->
                        add_command_result (Closed close_event);
                        Some (command, attempt, stopped_lifecycle close_event)
                    | Failed error ->
                        add_command_result (Failed error);
                        None
                    | Skipped -> None)
              in
              Ok cancelled_stop_events
    in
    let close_event_can_retry_after_parent_signal close_event =
      (not (Close_event.is_success close_event))
      &&
      match Run_policy.restart_limit policy with
      | Run_policy.Infinite_restarts -> true
      | Run_policy.Finite_restarts restart_tries ->
          Close_event.attempt close_event < restart_tries
    in
    let close_event_was_parent_signaled close_event =
      let command_index = Command.index (Close_event.command close_event) in
      let attempt = Close_event.attempt close_event in
      Eio.Mutex.use_ro state_mutex (fun () ->
          List.mem
            (command_index, attempt)
            !parent_signal_forwarded_command_attempts)
    in
    let should_retry close_event =
      Option.is_none !termination_signal
      &&
      if close_event_was_parent_signaled close_event then
        close_event_can_retry_after_parent_signal close_event
      else Run_policy.should_retry policy close_event
    in
    let close_event_finishes_collection close_event =
      close_event_completes_command close_event && not (should_retry close_event)
    in
    let set_current_attempt command_index attempt =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          current_attempts.(command_index) <- attempt)
    in
    let clear_kill_marks_for_retry command_index =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          killed_command_indexes :=
            List.filter
              (fun killed_command_index ->
                killed_command_index <> command_index)
              !killed_command_indexes;
          force_killed_command_indexes :=
            List.filter
              (fun force_killed_command_index ->
                force_killed_command_index <> command_index)
              !force_killed_command_indexes;
          timed_out_cleanup_signals :=
            List.remove_assoc command_index !timed_out_cleanup_signals)
    in
    let finish_close_event ~sw close_event =
      if should_retry close_event then (
        let next_attempt = Close_event.attempt close_event + 1 in
        let command_index = Command.index (Close_event.command close_event) in
        let delay_ms = Run_policy.restart_delay_ms policy ~next_attempt in
        set_current_attempt command_index next_attempt;
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
            retry_pending_command_indexes :=
              command_index :: !retry_pending_command_indexes
              |> List.sort_uniq Int.compare);
        add_close_event
          ~complete:false
          ~collect:(Run_policy.collect_retry_close_events policy)
          close_event;
        clear_kill_marks_for_retry command_index;
        emit_lifecycle
          ~command:(Close_event.command close_event)
          ~attempt:(Close_event.attempt close_event)
          (Output_event.Restarting
             { next_attempt; delay_ms = Some (max 0 delay_ms) });
        Option.iter (emit_once restart_delay_warning_emitted)
          (Run_policy.restart_delay_warning policy);
        `Retry (next_attempt, delay_ms))
      else (
        add_close_event close_event;
        if Run_policy.should_kill_after_close policy close_event then (
          match signal_siblings ~sw close_event with
          | Ok cancelled_stop_events -> `Done cancelled_stop_events
          | Error error ->
              record_failure error;
              `Done [])
        else `Done [])
    in
    let emit_deferred_stop_events stop_events =
      List.iter
        (fun (command, attempt, lifecycle) ->
          emit_lifecycle_best_effort ~emit_event:emit ~command ~attempt
            lifecycle)
        stop_events
    in
    let run_command_attempt ~sw command attempt =
      let command_index = Command.index command in
      if not (mark_command_starting_attempt command_index attempt) then `Done
      else
        let started_at = now () in
        emit_lifecycle ~command ~attempt Output_event.Started;
        Eio.Switch.run ~name:"Runner.command" (fun command_sw ->
            let spawn_result =
              Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                  if List.mem command_index !closed_command_indexes then (
                    starting_command_indexes :=
                      List.filter
                        (fun starting_command_index ->
                          starting_command_index <> command_index)
                        !starting_command_indexes;
                    `Closed)
                  else
                    match
                      backend.Runner_backend.spawn ~sw:command_sw ~command
                    with
                    | process ->
                        assert (
                          String.trim process.Runner_backend.process_id <> "");
                        let pending_input, close_stdin_after_spawn =
                          Runner_input_queue.drain_for_spawn input_queue
                            ~command_index ~stdin_should_follow_input
                        in
                        running_processes :=
                          { command_index; command; process; kind = Main_command }
                          :: !running_processes;
                        let signal_after_spawn =
                          List.assoc_opt command_index
                            !parent_signal_pending_starting_commands
                        in
                        remove_pending_parent_signal command_index;
                        starting_command_indexes :=
                          List.filter
                            (fun starting_command_index ->
                              starting_command_index <> command_index)
                            !starting_command_indexes;
                        `Process
                          ( process,
                            signal_after_spawn,
                            pending_input,
                            close_stdin_after_spawn )
                    | exception exn -> `Spawn_error exn)
            in
            match spawn_result with
            | `Closed ->
                Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                    remove_pending_parent_signal command_index);
                remove_active command_index;
                `Done
            | `Process
                ( process,
                  signal_after_spawn,
                  pending_input,
                  close_stdin_after_spawn ) -> (
                List.iter
                  (write_process_input command_index process)
                  pending_input;
                if close_stdin_after_spawn then close_process_stdin process;
                (match signal_after_spawn with
                | None -> ()
                | Some signal ->
                    signal_process_after_parent_termination command_index
                      process signal);
                let reader_failure, resolve_reader_failure =
                  Eio.Promise.create ()
                in
                let run_reader ~stream source =
                  let result =
                    match
                      Runner_output_reader.read ~emit_event:emit ~command
                        ~attempt
                        ~process_id:(Some process.Runner_backend.process_id)
                        ~stream source
                    with
                    | Ok () -> Ok ()
                    | Error _ as error -> error
                    | exception exn ->
                        Error
                          (`Unexpected_runner_error (Printexc.to_string exn))
                  in
                  (match result with
                  | Ok () -> ()
                  | Error error ->
                      ignore (process.Runner_backend.signal Sys.sigkill);
                      ignore
                        (Eio.Promise.try_resolve resolve_reader_failure error));
                  result
                in
                let await_reader reader =
                  match Eio.Promise.await_exn reader with
                  | Ok () -> Ok ()
                  | Error _ as error -> error
                  | exception exn ->
                      Error (`Unexpected_runner_error (Printexc.to_string exn))
                in
                let await_process process_status =
                  match Eio.Promise.await_exn process_status with
                  | Ok status -> Ok status
                  | Error _ as error -> error
                  | exception exn ->
                      Error (`Unexpected_runner_error (Printexc.to_string exn))
                in
                let process_status =
                  Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
                      match process.Runner_backend.await () with
                      | status -> Ok status
                      | exception exn ->
                          Error
                            (`Unexpected_runner_error (Printexc.to_string exn)))
                in
                let stdout_reader =
                  Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
                      run_reader ~stream:Output_event.Stdout
                        process.Runner_backend.stdout)
                in
                let stderr_reader =
                  Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
                      run_reader ~stream:Output_event.Stderr
                        process.Runner_backend.stderr)
                in
                let first_completion =
                  Eio.Fiber.first
                    (fun () -> `Process (await_process process_status))
                    (fun () ->
                      `Reader_failure (Eio.Promise.await reader_failure))
                in
                let forced_reader_error, process_result =
                  match first_completion with
                  | `Process (Ok status) -> (None, Ok status)
                  | `Process (Error error) ->
                      ignore (process.Runner_backend.signal Sys.sigkill);
                      (None, Error error)
                  | `Reader_failure error ->
                      ignore (process.Runner_backend.signal Sys.sigkill);
                      (Some error, await_process process_status)
                in
                match process_result with
                | Error error ->
                    record_failure error;
                    emit_lifecycle_with_process_id_best_effort
                      ~process_id:process.Runner_backend.process_id
                      ~emit_event:emit ~command ~attempt Output_event.Stopped;
                    remove_running command_index;
                    remove_active command_index;
                    `Done
                | Ok process_status -> (
                    let process_ended_at = now () in
                    let killed = command_was_killed command_index in
                    mark_exited command_index;
                    let pending_force_kill =
                      if killed then
                        pending_force_kill_for_status ~process_status
                          command_index
                      else None
                    in
                    if Option.is_none pending_force_kill then
                      process.Runner_backend.cleanup_after_exit ();
                    let create_close_action ~ended_at =
                      let status =
                        if killed && command_was_force_killed command_index then
                          signaled_status Sys.sigkill
                        else
                          match
                            ( process_status,
                              command_timed_out_cleanup_signal command_index )
                          with
                          | Close_event.Exited 0, Some signal ->
                              signaled_status signal
                          | _ -> process_status
                      in
                      match
                        create_close_event ~command ~attempt ~killed ~status
                          ~started_at ~ended_at
                      with
                      | Closed close_event ->
                          let next_action =
                            finish_close_event ~sw close_event
                          in
                          `Closed (close_event, next_action)
                      | Skipped -> impossible_command_result "run_process"
                      | Failed error ->
                          record_failure error;
                          `Failed
                    in
                    let close_action =
                      if killed then None
                      else Some (create_close_action ~ended_at:process_ended_at)
                    in
                    let await_readers () =
                      let stdout_result = await_reader stdout_reader in
                      let stderr_result = await_reader stderr_reader in
                      (stdout_result, stderr_result)
                    in
                    let rec await_cleanup_clearance_or_timeout completion =
                      if not (process.Runner_backend.needs_cleanup_after_exit ()) then
                        `Cleared
                      else if Eio.Promise.is_resolved completion then (
                        Eio.Promise.await completion;
                        `Timed_out)
                      else (
                        sleep 0.01;
                        await_cleanup_clearance_or_timeout completion)
                    in
                    let stdout_result, stderr_result =
                      match pending_force_kill with
                      | None -> await_readers ()
                      | Some completion -> (
                          match
                            Eio.Fiber.first
                              (fun () -> `Readers (await_readers ()))
                              (fun () ->
                                Eio.Promise.await completion;
                                `Force_kill_timeout)
                          with
                          | `Readers results -> (
                              match
                                await_cleanup_clearance_or_timeout completion
                              with
                              | `Cleared ->
                                  remove_pending_force_kill command_index;
                                  process.Runner_backend.cleanup_after_exit ();
                                  results
                              | `Timed_out ->
                                  process.Runner_backend.cleanup_after_exit ();
                                  remove_pending_force_kill command_index;
                                  results)
                          | `Force_kill_timeout ->
                              process.Runner_backend.cleanup_after_exit ();
                              remove_pending_force_kill command_index;
                              await_readers ())
                    in
                    let reader_error =
                      match
                        (forced_reader_error, stdout_result, stderr_result)
                      with
                      | Some error, _, _ -> Some error
                      | None, Error error, _ | None, _, Error error ->
                          Some error
                      | None, Ok (), Ok () -> None
                    in
                    match reader_error with
                    | Some error ->
                        record_failure (error :> run_error);
                        emit_lifecycle_with_process_id_best_effort
                          ~process_id:process.Runner_backend.process_id
                          ~emit_event:emit ~command ~attempt
                          Output_event.Stopped;
                        remove_running command_index;
                        remove_active command_index;
                        `Done
                    | None ->
                        let close_action =
                          match close_action with
                          | Some close_action -> close_action
                          | None -> create_close_action ~ended_at:(now ())
                        in
                        let next_action =
                          match close_action with
                          | `Closed (close_event, next_action) -> (
                              emit_lifecycle_with_process_id
                                ~process_id:process.Runner_backend.process_id
                                ~command ~attempt
                                (stopped_lifecycle close_event);
                              match next_action with
                              | `Done stop_events ->
                                  emit_deferred_stop_events stop_events;
                                  `Done
                              | `Retry _ as retry -> retry)
                          | `Failed -> `Done
                        in
                        remove_running command_index;
                        remove_active command_index;
                        next_action))
            | `Spawn_error exn -> (
                Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                    remove_pending_parent_signal command_index);
                remove_starting command_index;
                let ended_at = now () in
                let command_result =
                  create_close_event ~command ~attempt ~killed:false
                    ~status:(Close_event.Spawn_error (Printexc.to_string exn))
                    ~started_at ~ended_at
                in
                match command_result with
                | Closed close_event ->
                    let next_action = finish_close_event ~sw close_event in
                    emit_lifecycle ~command ~attempt
                      (stopped_lifecycle close_event);
                    let next_action =
                      match next_action with
                      | `Done stop_events ->
                          emit_deferred_stop_events stop_events;
                          `Done
                      | `Retry _ as retry -> retry
                    in
                    remove_active command_index;
                    next_action
                | Failed error ->
                    record_failure error;
                    remove_active command_index;
                    `Done
                | Skipped ->
                    remove_active command_index;
                    `Done))
    in
    let sleep_until_retry_or_close command delay_ms =
      let command_index = Command.index command in
      let deadline = now () +. (float_of_int delay_ms /. 1000.0) in
      let rec loop () =
        if Option.is_some !termination_signal then (
          cancel_terminated_commands_once ();
          false)
        else if command_is_closed command_index then false
        else
          let remaining_seconds = deadline -. now () in
          if remaining_seconds <= 0.0 then not (command_is_closed command_index)
          else
            let quantum =
              if remaining_seconds > 5.0 then 1.0
              else if remaining_seconds > 1.0 then 0.25
              else 0.05
            in
            sleep (min remaining_seconds quantum);
            loop ()
      in
      loop ()
    in
    let rec run_command_loop ~sw command attempt =
      let command_index = Command.index command in
      if command_is_closed command_index then (
        if take_parent_signal_skipped_command command_index then
          Eio.Stream.add close_events Skipped)
      else
        match run_command_attempt ~sw command attempt with
        | `Done ->
            if take_parent_signal_skipped_command command_index then
              Eio.Stream.add close_events Skipped
        | `Retry (next_attempt, delay_ms) ->
            if delay_ms <= 0 || sleep_until_retry_or_close command delay_ms then
              run_command_loop ~sw command next_attempt
    in
    let run_command ~sw command =
      (* npm max-processes slots are command-lifecycle slots: queued commands wait
       until retries finish, even while the current command is in backoff. *)
      Eio.Semaphore.acquire process_slots;
      Fun.protect
        ~finally:(fun () ->
          Eio.Semaphore.release process_slots;
          if max_processes < command_count then Eio.Fiber.yield ())
        (fun () -> run_command_loop ~sw command 0)
    in
    let emit_teardown_status message =
      Output_event.status_message ~after_command:None
        ~stream:Output_event.Stdout ~chunk:("--> " ^ message)
      |> emit_best_effort
    in
    let emit_teardown_lifecycle ~command lifecycle =
      create_lifecycle_event ~command ~attempt:0 lifecycle |> emit_best_effort
    in
    let take_teardown_parent_signals command_index =
      let matching_signals, remaining_signals =
        List.partition
          (fun pending_signal ->
            pending_signal.signal_command_index = command_index)
          !pending_teardown_parent_signals
      in
      pending_teardown_parent_signals := remaining_signals;
      List.rev matching_signals
    in
    let take_teardown_signal_errors command_index =
      let matching_errors, remaining_errors =
        List.partition
          (fun error -> error.error_command_index = command_index)
          !pending_teardown_signal_errors
      in
      pending_teardown_signal_errors := remaining_errors;
      List.rev matching_errors
    in
    let emit_teardown_signal_errors errors =
      List.iter
        (fun error ->
          teardown_error_event ~command:error.error_command
            ~message:
              ("teardown command failed to signal: " ^ error.error_message)
          |> emit_best_effort)
        errors
    in
    let flush_teardown_signal_errors command_index =
      take_teardown_signal_errors command_index |> emit_teardown_signal_errors
    in
    let close_teardown_process_stdin ~command process =
      match process.Runner_backend.close_stdin () with
      | () -> ()
      | exception exn ->
          teardown_error_event ~command
            ~message:
              ("teardown command failed to close stdin: "
              ^ Printexc.to_string exn)
          |> emit_best_effort
    in
    let signal_teardown_process_best_effort ~command process signal =
      match process.Runner_backend.signal signal with
      | Ok true | Ok false -> ()
      | Error message ->
          teardown_error_event ~command
            ~message:("teardown command failed to signal: " ^ message)
          |> emit_best_effort
    in
    let signal_teardown_process_silently process signal =
      match process.Runner_backend.signal signal with
      | Ok true | Ok false | Error _ -> ()
    in
    let run_teardown_reader ~command ~process ~stream source =
      let result =
        match
          Runner_output_reader.read ~emit_event:emit ~command ~attempt:0
            ~process_id:(Some process.Runner_backend.process_id) ~stream source
        with
        | Ok () -> Ok ()
        | Error (`Unexpected_runner_error message) -> Error message
        | Error (`Output_event_error (command_index, error)) ->
            Error
              (Printf.sprintf "command %d output event is invalid: %s"
                 command_index
                 (output_event_create_error_message error))
        | exception exn -> Error (Printexc.to_string exn)
      in
      (match result with
      | Ok () -> ()
      | Error _ ->
          signal_teardown_process_best_effort ~command process Sys.sigkill);
      result
    in
    let await_teardown_reader reader =
      match Eio.Promise.await_exn reader with
      | Ok () -> Ok ()
      | Error _ as error -> error
      | exception exn -> Error (Printexc.to_string exn)
    in
    let cleanup_teardown_process ~command process =
      match process.Runner_backend.cleanup_after_exit () with
      | () -> ()
      | exception exn ->
          teardown_error_event ~command
            ~message:("teardown command cleanup failed: " ^ Printexc.to_string exn)
          |> emit_best_effort
    in
    let await_teardown_process_status process =
      match process.Runner_backend.await () with
      | status -> Ok status
      | exception exn -> Error (Printexc.to_string exn)
    in
    let await_teardown_process ~sw ~command_index ~command ~process =
      let process_status =
        Eio.Fiber.fork_promise ~sw (fun () ->
            await_teardown_process_status process)
      in
      let force_kill_deadline = ref None in
      let force_kill_sent = ref false in
      let send_force_kill_now () =
        if not !force_kill_sent then (
          signal_teardown_process_silently process Sys.sigkill;
          force_kill_deadline := None;
          force_kill_sent := true)
      in
      let arm_force_kill_deadline timeout_ms =
        Option.iter (emit_once kill_timeout_warning_emitted)
          (Run_policy.kill_timeout_warning policy);
        force_kill_deadline :=
          Some
            (now ()
            +. (float_of_int (normalized_kill_timeout_ms timeout_ms) /. 1000.0))
      in
      let schedule_force_kill_with_timeout ~when_unset signal =
        if !force_kill_sent then ()
        else if signal = Sys.sigkill then send_force_kill_now ()
        else
          match (Run_policy.kill_timeout_ms policy, !force_kill_deadline) with
          (* Match the main kill-timeout path and the JS scheduler: a missing or
             zero timeout does not arm a delayed SIGKILL after a signal that was
             already delivered successfully. *)
          | Some 0, None | None, None -> when_unset ()
          | Some timeout_ms, None -> arm_force_kill_deadline timeout_ms
          | _, Some _ -> ()
      in
      let schedule_force_kill_after_parent_signal signal =
        schedule_force_kill_with_timeout ~when_unset:(fun () -> ()) signal
      in
      let schedule_force_kill_after_signal_error signal =
        (* If the graceful signal never landed, fall back immediately unless a
           positive timeout explicitly asked us to wait first. *)
        schedule_force_kill_with_timeout ~when_unset:send_force_kill_now signal
      in
      let pause_until_next_poll () =
        match !force_kill_deadline with
        | Some deadline ->
            let remaining = deadline -. now () in
            if remaining <= 0.0 then 0.001 else min 0.01 remaining
        | None -> 0.01
      in
      let should_wait_for_cleanup_after_exit ~cleanup_needed = function
        | Ok _ ->
            (match !force_kill_deadline with
            | Some deadline ->
                (not !force_kill_sent)
                && cleanup_needed
                && now () < deadline
            | None -> false)
        | Error _ -> false
      in
      let rec loop () =
        let delivered_signals = take_teardown_parent_signals command_index in
        List.iter
          (fun pending_signal ->
            schedule_force_kill_after_parent_signal
              pending_signal.delivered_signal)
          delivered_signals;
        let signal_errors = take_teardown_signal_errors command_index in
        if signal_errors <> [] then (
          emit_teardown_signal_errors signal_errors;
          List.iter
            (fun error ->
              schedule_force_kill_after_signal_error error.failed_signal)
            signal_errors);
        (match !force_kill_deadline with
        | Some deadline when not !force_kill_sent && now () >= deadline ->
            send_force_kill_now ()
        | Some _ | None -> ());
        if Eio.Promise.is_resolved process_status then
          let status = Eio.Promise.await_exn process_status in
          let cleanup_needed = process.Runner_backend.needs_cleanup_after_exit () in
          (match !force_kill_deadline with
          | Some deadline
            when cleanup_needed && not !force_kill_sent && now () >= deadline ->
              send_force_kill_now ()
          | Some _ | None -> ());
          if should_wait_for_cleanup_after_exit ~cleanup_needed status then (
            sleep (pause_until_next_poll ());
            loop ())
          else status
        else (
          sleep (pause_until_next_poll ());
          loop ())
      in
      loop ()
    in
    let teardown_reader_errors stdout_reader stderr_reader =
      [ await_teardown_reader stdout_reader; await_teardown_reader stderr_reader ]
      |> List.filter_map (function
           | Ok () -> None
           | Error message -> Some message)
    in
    let emit_teardown_reader_errors ~command errors =
      List.iter
        (fun message ->
          teardown_error_event ~command
            ~message:("teardown command output read failed: " ^ message)
          |> emit_best_effort)
        errors
    in
    let teardown_parent_signal_to_replay command_index
        parent_signal_generation_before_spawn =
      let current_generation = !parent_signal_generation in
      if current_generation <= parent_signal_generation_before_spawn then None
      else
        match
          List.assoc_opt command_index
            !teardown_parent_signal_delivery_generations
        with
        | Some delivered_generation when delivered_generation = current_generation
          ->
            None
        | Some _ | None -> !parent_signal
    in
    let run_teardown_command command =
      let command_index = Command.index command in
      let parent_signal_generation_before_spawn = !parent_signal_generation in
      emit_teardown_status
        (Printf.sprintf "Running teardown command \"%s\"" (Command.text command));
      emit_teardown_lifecycle ~command Output_event.Started;
      Eio.Switch.run ~name:"Runner.teardown" (fun command_sw ->
          let spawn_result =
            Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
                match backend.Runner_backend.spawn ~sw:command_sw ~command with
                | process ->
                    assert (String.trim process.Runner_backend.process_id <> "");
                    running_processes :=
                      {
                        command_index;
                        command;
                        process;
                        kind = Teardown_command;
                      }
                      :: !running_processes;
                    `Process process
                | exception exn -> `Spawn_error exn)
          in
          match spawn_result with
          | `Spawn_error exn ->
              teardown_spawn_error_event ~command
                ~message:(Printexc.to_string exn)
              |> emit_best_effort;
              emit_teardown_lifecycle ~command Output_event.Stopped
          | `Process process ->
              close_teardown_process_stdin ~command process;
              Option.iter
                (fun signal ->
                  match process.Runner_backend.signal signal with
                  | Ok true ->
                      queue_teardown_parent_signal command_index signal
                  | Ok false -> ()
                  | Error error_message ->
                      queue_teardown_signal_error ~command_index ~command
                        ~signal ~error_message)
                (teardown_parent_signal_to_replay command_index
                   parent_signal_generation_before_spawn);
              let stdout_reader =
                Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
                    run_teardown_reader ~command ~process
                      ~stream:Output_event.Stdout process.Runner_backend.stdout)
              in
              let stderr_reader =
                Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
                    run_teardown_reader ~command ~process
                      ~stream:Output_event.Stderr process.Runner_backend.stderr)
              in
              let close_status =
                await_teardown_process ~sw:command_sw ~command_index ~command
                  ~process
              in
              (match close_status with
              | Error message ->
                  signal_teardown_process_best_effort ~command process Sys.sigkill;
                  cleanup_teardown_process ~command process;
                  let reader_errors =
                    teardown_reader_errors stdout_reader stderr_reader
                  in
                  remove_running command_index;
                  flush_teardown_signal_errors command_index;
                  emit_teardown_reader_errors ~command reader_errors;
                  teardown_error_event ~command
                    ~message:("teardown command failed to await: " ^ message)
                  |> emit_best_effort
              | Ok status ->
                  cleanup_teardown_process ~command process;
                  let reader_errors =
                    teardown_reader_errors stdout_reader stderr_reader
                  in
                  remove_running command_index;
                  flush_teardown_signal_errors command_index;
                  match reader_errors with
                  | [] ->
                      emit_teardown_status
                        (Printf.sprintf
                           "Teardown command \"%s\" exited with code %s"
                           (Command.text command)
                           (Process_signal.exit_status_label status))
                  | errors ->
                      List.iter
                        (fun message ->
                          teardown_error_event ~command
                            ~message:
                              ("teardown command output read failed: " ^ message)
                          |> emit_best_effort)
                        errors);
              emit_teardown_lifecycle ~command Output_event.Stopped)
    in
    let run_teardown_commands () =
      Run_policy.teardown policy |> List.iter run_teardown_command
    in
    let collect_close_events () =
      let rec collect remaining collected =
        if remaining = 0 then Ok (List.rev collected)
        else (
          cancel_terminated_commands_once ();
          match Eio.Stream.take close_events with
          | Closed close_event ->
              let remaining =
                if close_event_finishes_collection close_event then remaining - 1
                else remaining
              in
              collect remaining (close_event :: collected)
          | Skipped -> collect (remaining - 1) collected
          | Failed error -> raise (Fatal_runner_error error))
      in
      collect command_count []
    in
    let run_main_commands () =
      Eio.Switch.run ~name:"Runner.run" (fun sw ->
          List.iter
            (fun command ->
              Eio.Fiber.fork ~sw (fun () -> run_command ~sw command))
            commands;
          (match (input, input_source) with
          | Some router, Some source ->
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  run_input_router router source;
                  `Stop_daemon)
          | Some _, None | None, Some _ | None, None -> ());
          collect_close_events ())
    in
    let run_main_then_teardown () =
      let main_result = run_main_commands () in
      run_teardown_commands ();
      main_result
    in
    let create_run_result ?interrupted_signal ~spec ~interrupted close_events =
      match recorded_failure () with
      | Some error -> Error error
      | None -> (
          match
            match interrupted_signal with
            | None ->
                Run_result.create ~spec ~close_events
                  ~output_event_count:!output_event_count ~interrupted
            | Some signal ->
                assert interrupted;
                Run_result.create_interrupted_by_signal ~signal ~spec
                  ~close_events ~output_event_count:!output_event_count
          with
          | Ok result -> Ok result
          | Error error -> Error (`Run_result_error error))
    in
    match
      with_parent_termination_signals
        ~cleanup:(fun signal ->
          parent_signal_generation := !parent_signal_generation + 1;
          parent_signal := Some signal;
          let skipped_command_indexes =
            parent_signal_skippable_commands () |> List.map Command.index
          in
          closed_command_indexes :=
            skipped_command_indexes
            |> List.rev_append !closed_command_indexes
            |> List.sort_uniq Int.compare;
          parent_signal_skipped_command_indexes :=
            skipped_command_indexes
            |> List.rev_append !parent_signal_skipped_command_indexes
            |> List.sort_uniq Int.compare;
          parent_signal_pending_starting_commands :=
            !starting_command_indexes
            |> List.map (fun command_index -> (command_index, signal))
            |> List.rev_append !parent_signal_pending_starting_commands
            |> List.sort_uniq (fun (left_index, _) (right_index, _) ->
                   Int.compare left_index right_index);
          if signal = Sys.sigint && Option.is_none !termination_signal then
            termination_signal := Some signal;
          let signaled_main_command_indexes =
            signal_running_process_groups signal
          in
          if signaled_main_command_indexes <> [] then (
            let running_command_attempts =
              signaled_main_command_indexes
              |> List.map (fun command_index ->
                     (command_index, current_attempts.(command_index)))
            in
            parent_signal_forwarded_command_attempts :=
              running_command_attempts
              |> List.rev_append !parent_signal_forwarded_command_attempts
              |> List.sort_uniq Stdlib.compare;
            killed_command_indexes :=
              signaled_main_command_indexes
              |> List.rev_append !killed_command_indexes
              |> List.sort_uniq Int.compare);
          ())
        run_main_then_teardown
    with
    | `Interrupted (_, Error error) -> Error error
    | `Interrupted (signal, Ok close_events) ->
        create_run_result ~spec ~interrupted:true
          ~interrupted_signal:signal close_events
    | `Completed (Error error) -> Error error
    | `Completed (Ok close_events) ->
        create_run_result ~spec ~interrupted:false close_events
    | exception Fatal_runner_error error -> Error error
    | exception exn -> Error (`Unexpected_runner_error (Printexc.to_string exn))
  in
  run_after_validation ()

let close_event_error_message = function
  | `Empty_signal -> "close event signal must not be empty"
  | `Empty_spawn_error -> "spawn error message must not be empty"
  | `Negative_attempt -> "close event attempt must not be negative"
  | `Negative_exit_code -> "close event exit code must not be negative"
  | `Ended_before_started -> "close event ended before it started"

let output_event_error_message = function
  | `Invalid_next_attempt (attempt, next_attempt) ->
      Printf.sprintf "invalid restart transition from attempt %d to %d" attempt
        next_attempt
  | `Negative_attempt -> "output event attempt must not be negative"
  | `Negative_delay_ms -> "restart delay must not be negative"

let run_result_error_message = function
  | `Attempt_after_success (command_index, attempt) ->
      Printf.sprintf "command %d has attempt %d after success" command_index
        attempt
  | `Attempt_exceeds_restart_tries (command_index, attempt) ->
      Printf.sprintf "command %d attempt %d exceeds restart tries" command_index
        attempt
  | `Duplicate_close_event_attempt (command_index, attempt) ->
      Printf.sprintf "command %d has duplicate close event for attempt %d"
        command_index attempt
  | `Incomplete_restart_attempt (command_index, attempt) ->
      Printf.sprintf "command %d attempt %d needs a restart or final close"
        command_index attempt
  | `Missing_close_event_attempt (command_index, attempt) ->
      Printf.sprintf "command %d is missing close event for attempt %d"
        command_index attempt
  | `Missing_close_events -> "run is missing close events"
  | `Negative_output_event_count -> "output event count must not be negative"
  | `Too_many_close_events -> "run has too many close events"
  | `Unexpected_command command_index ->
      Printf.sprintf "unexpected command at index %d" command_index
  | `Unknown_command_index command_index ->
      Printf.sprintf "unknown command index %d" command_index

let error_message = function
  | `Close_event_error (command_index, error) ->
      Printf.sprintf "command %d close event is invalid: %s" command_index
        (close_event_error_message error)
  | `Output_event_error (command_index, error) ->
      Printf.sprintf "command %d output event is invalid: %s" command_index
        (output_event_error_message error)
  | `Run_result_error error -> run_result_error_message error
  | `Unsupported_kill_signal signal ->
      Process_signal.unknown_signal_error_message signal
  | `Unexpected_runner_error message -> message
