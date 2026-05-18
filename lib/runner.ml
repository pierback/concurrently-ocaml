type run_error =
  [ `Close_event_error of int * Close_event.create_error
  | `Output_event_error of int * Output_event.create_error
  | `Run_result_error of Run_result.create_error
  | `Unsupported_kill_signal of string
  | `Unexpected_runner_error of string
  ]

type running_process =
  { command_index : int
  ; process : Runner_backend.process
  }

type command_result =
  | Closed of Close_event.t
  | Failed of run_error

exception Fatal_runner_error of run_error

let max_line_bytes = 1_048_576
let max_pending_input_chunks_per_command = 64
let read_buffer_bytes = 16_384

let signal_number = function
  | Run_policy.Sigterm -> Ok Sys.sigterm
  | Run_policy.Sigkill -> Ok Sys.sigkill
  | Run_policy.Named_signal signal ->
    (match String.uppercase_ascii (String.trim signal) with
     | "HUP" | "SIGHUP" -> Ok Sys.sighup
     | "INT" | "SIGINT" -> Ok Sys.sigint
     | "TERM" | "SIGTERM" -> Ok Sys.sigterm
     | "KILL" | "SIGKILL" -> Ok Sys.sigkill
     | "USR1" | "SIGUSR1" -> Ok Sys.sigusr1
     | "USR2" | "SIGUSR2" -> Ok Sys.sigusr2
     | value -> Error (`Unsupported_kill_signal value))

let validate_kill_signal policy =
  match Run_policy.kill_others_on policy with
  | [] -> Ok ()
  | _ :: _ -> signal_number (Run_policy.kill_signal policy) |> Result.map ignore

let with_forwarded_termination_signals ~cleanup run =
  let previous_handlers = ref [] in
  let received_signal = ref None in
  let restore_handlers () =
    List.iter
      (fun (signal, previous_handler) ->
        Sys.set_signal signal previous_handler)
      !previous_handlers
  in
  let handle signal =
    if Option.is_none !received_signal then received_signal := Some signal;
    cleanup signal
  in
  previous_handlers :=
    List.map
      (fun signal -> signal, Sys.signal signal (Sys.Signal_handle handle))
      [ Sys.sighup; Sys.sigint; Sys.sigterm ];
  let result = Fun.protect ~finally:restore_handlers run in
  match !received_signal with
  | None -> `Completed result
  | Some signal -> `Interrupted (signal, result)

let create_lifecycle_event ~command ~attempt lifecycle =
  match Output_event.lifecycle ~command ~attempt ~lifecycle with
  | Ok event -> event
  | Error _ -> assert false

let emit_lifecycle ~emit_event ~command ~attempt lifecycle =
  create_lifecycle_event ~command ~attempt lifecycle |> emit_event

let emit_output_chunk ~emit_event ~command ~attempt ~process_id ~stream ~chunk =
  match
    Output_event.output_chunk
      ~command
      ~attempt
      ~process_id
      ~stream
      ~chunk
  with
  | Ok event ->
    (match emit_event event with
     | () -> Ok ()
     | exception exn -> Error (`Unexpected_runner_error (Printexc.to_string exn)))
  | Error error -> Error (`Output_event_error (Command.index command, error))

let drop_trailing_cr chunk =
  let length = String.length chunk in
  if length > 0 && chunk.[length - 1] = '\r' then
    String.sub chunk 0 (length - 1)
  else chunk

let read_raw_output ~emit_event ~command ~attempt ~process_id ~stream source =
  let read_buffer = Cstruct.create read_buffer_bytes in
  let rec read_chunks () =
    match Eio.Flow.single_read source read_buffer with
    | bytes_read ->
      let chunk = Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read) in
      (match
         emit_output_chunk
           ~emit_event
           ~command
           ~attempt
           ~process_id
           ~stream
           ~chunk
       with
       | Ok () -> read_chunks ()
       | Error _ as error -> error)
    | exception End_of_file -> Ok ()
    | exception exn -> Error (`Unexpected_runner_error (Printexc.to_string exn))
  in
  read_chunks ()

let read_line_output ~emit_event ~command ~attempt ~process_id ~stream source =
  let read_buffer = Cstruct.create read_buffer_bytes in
  let line_buffer = Buffer.create read_buffer_bytes in
  let line_was_split = ref false in
  let emit_chunk chunk =
    emit_output_chunk ~emit_event ~command ~attempt ~process_id ~stream ~chunk
  in
  let flush_buffer ?(line_end = false) () =
    let chunk = Buffer.contents line_buffer in
    Buffer.clear line_buffer;
    let chunk = if line_end then drop_trailing_cr chunk else chunk in
    emit_chunk chunk
  in
  let flush_oversized_line_part () =
    line_was_split := true;
    flush_buffer ()
  in
  let flush_line () =
    if Buffer.length line_buffer = 0 && !line_was_split then (
      line_was_split := false;
      Ok ())
    else
      match flush_buffer ~line_end:true () with
      | Ok () ->
        line_was_split := false;
        Ok ()
      | Error _ as error -> error
  in
  let flush_final_partial_line () =
    if Buffer.length line_buffer = 0 then Ok () else flush_buffer ()
  in
  let process_byte byte =
    if byte = '\n' then flush_line ()
    else (
      Buffer.add_char line_buffer byte;
      if Buffer.length line_buffer >= max_line_bytes then
        flush_oversized_line_part ()
      else Ok ())
  in
  let process_chunk chunk =
    let length = String.length chunk in
    let rec loop index =
      if index = length then Ok ()
      else
        match process_byte chunk.[index] with
        | Ok () -> loop (index + 1)
        | Error _ as error -> error
    in
    loop 0
  in
  let rec read_chunks () =
    match Eio.Flow.single_read source read_buffer with
    | bytes_read ->
      let chunk = Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read) in
      (match process_chunk chunk with
       | Ok () -> read_chunks ()
       | Error _ as error -> error)
    | exception End_of_file -> flush_final_partial_line ()
    | exception exn -> Error (`Unexpected_runner_error (Printexc.to_string exn))
  in
  read_chunks ()

let read_output ~emit_event ~command ~attempt ~process_id ~stream source =
  if Command.raw command then
    read_raw_output ~emit_event ~command ~attempt ~process_id ~stream source
  else read_line_output ~emit_event ~command ~attempt ~process_id ~stream source

let create_close_event ~command ~attempt ~killed ~status ~started_at ~ended_at =
  match
    Close_event.create
      ~command
      ~attempt
      ~killed
      ~status
      ~started_at
      ~ended_at
  with
  | Ok close_event -> Closed close_event
  | Error error -> Failed (`Close_event_error (Command.index command, error))

let cancelled_close_event ~now ~attempt ~signal command =
  let timestamp = now () in
  create_close_event
    ~command
    ~attempt
    ~killed:true
    ~status:(Close_event.Signaled (string_of_int signal))
    ~started_at:timestamp
    ~ended_at:timestamp

let teardown_spawn_error_event ~command ~message =
  let chunk = "teardown command failed to spawn: " ^ message in
  match
    Output_event.output_chunk
      ~command
      ~attempt:0
      ~process_id:None
      ~stream:Output_event.Stderr
      ~chunk
  with
  | Ok event -> event
  | Error _ -> assert false

let run ~input ~input_source ~backend ~process_mgr:_process_mgr ~now ~sleep
    ~spec ~on_output_event =
  let commands = Run_spec.commands spec in
  let command_count = List.length commands in
  let policy = Run_spec.policy spec in
  let stdin_should_follow_input =
    Option.is_some input && Option.is_some input_source
  in
  let run_after_validation () =
  let max_processes =
    match Run_policy.max_processes policy with
    | None -> command_count
    | Some value -> min value command_count
  in
  let output_event_count = ref 0 in
  let termination_signal = ref None in
  let termination_cancelled = ref false in
  let running_processes = ref [] in
  let pending_input_chunks = Array.make command_count [] in
  let input_source_closed = ref false in
  let active_command_indexes = ref [] in
  let starting_command_indexes = ref [] in
  let exited_command_indexes = ref [] in
  let retry_pending_command_indexes = ref [] in
  let killed_command_indexes = ref [] in
  let closed_command_indexes = ref [] in
  let current_attempts = Array.make command_count 0 in
  let state_mutex = Eio.Mutex.create () in
  let event_mutex = Eio.Mutex.create () in
  let error_mutex = Eio.Mutex.create () in
  let run_errors = ref [] in
  let close_events = Eio.Stream.create (Run_spec.close_event_capacity spec) in
  let process_slots = Eio.Semaphore.make max_processes in
  let emit event =
    Eio.Mutex.use_rw ~protect:true event_mutex (fun () ->
      incr output_event_count;
      on_output_event event)
  in
  let emit_best_effort event =
    match emit event with
    | () -> ()
    | exception _ -> ()
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
    emit_lifecycle
      ~emit_event:emit
      ~command
      ~attempt
      lifecycle
  in
  let remove_running command_index =
    Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
      running_processes :=
        List.filter
          (fun process -> process.command_index <> command_index)
          !running_processes;
      exited_command_indexes :=
        List.filter
          (fun exited_command_index -> exited_command_index <> command_index)
          !exited_command_indexes;
      retry_pending_command_indexes :=
        List.filter
          (fun retry_command_index -> retry_command_index <> command_index)
          !retry_pending_command_indexes)
  in
  let mark_exited command_index =
    Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
      exited_command_indexes :=
        command_index :: !exited_command_indexes |> List.sort_uniq Int.compare)
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
            (fun retry_command_index -> retry_command_index <> command_index)
            !retry_pending_command_indexes;
        active_command_indexes :=
          command_index :: !active_command_indexes |> List.sort_uniq Int.compare;
        starting_command_indexes :=
          command_index :: !starting_command_indexes
          |> List.sort_uniq Int.compare;
        true))
  in
  let remove_active command_index =
    Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
      active_command_indexes :=
        List.filter
          (fun active_command_index -> active_command_index <> command_index)
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
  let close_process_stdin process =
    match process.Runner_backend.close_stdin () with
    | () -> ()
    | exception _ -> ()
  in
  let write_input route =
    match process_for_input route.Input_router.target_index with
    | Some running_process ->
      write_process_input
        route.Input_router.target_index
        running_process.process
        route.Input_router.payload
    | None ->
      let enqueue_result =
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          if
            route.Input_router.target_index < 0
            || route.Input_router.target_index >= command_count
            || List.mem
                 route.Input_router.target_index
                 !closed_command_indexes
          then `Drop
          else
            let pending = pending_input_chunks.(route.Input_router.target_index) in
            if List.length pending >= max_pending_input_chunks_per_command then
              `Overflow
            else (
              pending_input_chunks.(route.Input_router.target_index) <-
                route.Input_router.payload :: pending;
              `Queued))
      in
      (match enqueue_result with
       | `Queued | `Drop -> ()
       | `Overflow ->
         record_failure
           (`Unexpected_runner_error
             "pending input buffer exceeded for command"))
  in
  let close_running_stdins () =
    let processes =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        input_source_closed := true;
        !running_processes)
    in
    List.iter
      (fun running_process -> close_process_stdin running_process.process)
      processes
  in
  let run_input_router router source =
    let read_buffer = Cstruct.create read_buffer_bytes in
    let input_buffer = Buffer.create read_buffer_bytes in
    let flush_buffer ?(line_end = false) () =
      let input = Buffer.contents input_buffer in
      Buffer.clear input_buffer;
      let input = if line_end then input ^ "\n" else input in
      if not (String.equal input "") then
        Input_router.route router input |> write_input
    in
    let flush_final_partial_input () =
      if Buffer.length input_buffer > 0 then flush_buffer ()
    in
    let process_byte byte =
      if byte = '\n' then flush_buffer ~line_end:true ()
      else (
        Buffer.add_char input_buffer byte;
        if Buffer.length input_buffer >= max_line_bytes then flush_buffer ())
    in
    let process_chunk chunk =
      let length = String.length chunk in
      let rec loop index =
        if index = length then ()
        else (
          process_byte chunk.[index];
          loop (index + 1))
      in
      loop 0
    in
    let rec read_chunks () =
      match Eio.Flow.single_read source read_buffer with
      | bytes_read ->
        let chunk = Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read) in
        process_chunk chunk;
        read_chunks ()
      | exception End_of_file ->
        flush_final_partial_input ();
        close_running_stdins ()
      | exception exn ->
        if not (Eio.Fiber.is_cancelled ()) then
          record_failure (`Unexpected_runner_error (Printexc.to_string exn))
    in
    read_chunks ()
  in
  let signal_running_process_groups signal =
    !running_processes
    |> List.iter (fun running_process ->
      ignore (running_process.process.signal signal))
  in
  let signal_process_after_latched_termination command_index process signal =
    match process.Runner_backend.signal signal with
    | Ok true ->
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        killed_command_indexes :=
          command_index :: !killed_command_indexes |> List.sort_uniq Int.compare)
    | Ok false -> ()
    | Error message ->
      if command_running_after_yields command_index 32 then
        record_failure (`Unexpected_runner_error message)
      else ()
  in
  let force_kill_after_timeout ~sw ~initial_signal command_indexes =
    match command_indexes, Run_policy.kill_timeout_ms policy with
    | [], _ | _, None | _, Some 0 -> ()
    | _, Some timeout_ms when initial_signal = Sys.sigkill -> ()
    | _, Some timeout_ms ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
        (match sleep (float_of_int timeout_ms /. 1000.0) with
         | () ->
           let processes_to_kill =
             Eio.Mutex.use_ro state_mutex (fun () ->
               !running_processes
               |> List.filter (fun running_process ->
                 List.mem running_process.command_index command_indexes
                 && not
                      (List.mem
                         running_process.command_index
                         !exited_command_indexes)))
           in
           List.iter
             (fun running_process ->
               match running_process.process.Runner_backend.signal Sys.sigkill with
               | Ok true | Ok false -> ()
               | Error message ->
                 if
                   command_running_after_yields
                     running_process.command_index
                     32
                 then
                   record_failure (`Unexpected_runner_error message)
                 else ())
             processes_to_kill
         | exception _ -> ());
        `Stop_daemon)
  in
  let close_event_completes_command close_event =
    Close_event.killed close_event
    || Close_event.is_success close_event
    || Close_event.attempt close_event >= Run_policy.restart_tries policy
  in
  let add_close_event close_event =
    let command_index = Command.index (Close_event.command close_event) in
    if close_event_completes_command close_event then
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        closed_command_indexes :=
          command_index :: !closed_command_indexes |> List.sort_uniq Int.compare;
        retry_pending_command_indexes :=
          List.filter
            (fun retry_command_index -> retry_command_index <> command_index)
            !retry_pending_command_indexes);
    Eio.Stream.add close_events (Closed close_event)
  in
  let add_command_result = function
    | Closed close_event -> add_close_event close_event
    | Failed error -> record_failure error
  in
  let cancel_non_running_commands signal =
    let commands_to_cancel =
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        let running_indexes =
          List.map
            (fun running_process -> running_process.command_index)
            !running_processes
        in
        let commands_to_cancel =
          commands
          |> List.filter (fun command ->
            let command_index = Command.index command in
            (not (List.mem command_index !closed_command_indexes))
            && not (List.mem command_index running_indexes))
        in
        let cancelled_command_indexes =
          List.map Command.index commands_to_cancel
        in
        killed_command_indexes :=
          cancelled_command_indexes
          |> List.rev_append !killed_command_indexes
          |> List.sort_uniq Int.compare;
        closed_command_indexes :=
          cancelled_command_indexes
          |> List.rev_append !closed_command_indexes
          |> List.sort_uniq Int.compare;
        commands_to_cancel)
    in
    commands_to_cancel
    |> List.map (fun command ->
      let attempt =
        Eio.Mutex.use_ro state_mutex (fun () ->
          current_attempts.(Command.index command))
      in
      cancelled_close_event ~now ~attempt ~signal command)
    |> List.iter add_command_result
  in
  let cancel_terminated_commands_once () =
    match !termination_signal with
    | Some signal when not !termination_cancelled ->
      termination_cancelled := true;
      cancel_non_running_commands signal
    | Some _ | None -> ()
  in
  let signal_siblings ~sw close_event =
    match signal_number (Run_policy.kill_signal policy) with
    | Error error -> Error error
    | Ok signal ->
      let closing_index = Command.index (Close_event.command close_event) in
      let processes_to_signal, commands_to_cancel =
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          let siblings =
            List.filter
              (fun process ->
                process.command_index <> closing_index
                && not (List.mem process.command_index !exited_command_indexes))
              !running_processes
          in
          let running_indexes =
            List.map (fun process -> process.command_index) siblings
          in
          let active_indexes = !active_command_indexes in
          let starting_indexes = !starting_command_indexes in
          let retry_pending_indexes = !retry_pending_command_indexes in
          let active_retry_commands =
            List.filter
              (fun command ->
                let command_index = Command.index command in
                command_index <> closing_index
                && not (List.mem command_index !closed_command_indexes)
                && List.mem command_index active_indexes
                && not (List.mem command_index starting_indexes)
                && not (List.mem command_index running_indexes)
                && List.mem command_index retry_pending_indexes)
              commands
          in
          let pending_commands =
            List.filter
              (fun command ->
                let command_index = Command.index command in
                command_index <> closing_index
                && not (List.mem command_index !closed_command_indexes)
                && not (List.mem command_index running_indexes)
                && not (List.mem command_index active_indexes))
              commands
          in
          let starting_commands =
            List.filter
              (fun command ->
                let command_index = Command.index command in
                command_index <> closing_index
                && not (List.mem command_index !closed_command_indexes)
                && List.mem command_index starting_indexes
                && not (List.mem command_index running_indexes))
              commands
          in
          let commands_to_cancel =
            List.rev_append starting_commands pending_commands
            |> List.rev_append active_retry_commands
          in
          let cancelled_command_indexes = List.map Command.index commands_to_cancel in
          killed_command_indexes :=
            cancelled_command_indexes
            |> List.rev_append !killed_command_indexes
            |> List.sort_uniq Int.compare;
          closed_command_indexes :=
            cancelled_command_indexes
            |> List.rev_append !closed_command_indexes
            |> List.sort_uniq Int.compare;
          siblings, commands_to_cancel)
      in
      let signaled_command_indexes, signal_errors =
        processes_to_signal
        |> List.fold_left
             (fun (signaled_command_indexes, signal_errors) running_process ->
               match running_process.process.signal signal with
               | Ok true ->
                 ( running_process.command_index :: signaled_command_indexes
                 , signal_errors )
               | Ok false -> signaled_command_indexes, signal_errors
               | Error message ->
                 if
                   command_running_after_yields
                     running_process.command_index
                     32
                 then
                   ( signaled_command_indexes
                   , (`Unexpected_runner_error message) :: signal_errors )
                 else signaled_command_indexes, signal_errors)
             ([], [])
      in
      (match List.rev signal_errors with
       | error :: _ -> Error error
       | [] ->
         Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
           killed_command_indexes :=
             signaled_command_indexes
             |> List.rev_append !killed_command_indexes
             |> List.sort_uniq Int.compare);
         force_kill_after_timeout
           ~sw
           ~initial_signal:signal
           signaled_command_indexes;
         commands_to_cancel
         |> List.map (fun command ->
           let attempt =
             Eio.Mutex.use_ro state_mutex (fun () ->
               current_attempts.(Command.index command))
           in
           cancelled_close_event ~now ~attempt ~signal command)
         |> List.iter add_command_result;
         Ok ())
  in
  let should_retry close_event =
    (not (Close_event.killed close_event))
    && (not (Close_event.is_success close_event))
    && Close_event.attempt close_event < Run_policy.restart_tries policy
  in
  let set_current_attempt command_index attempt =
    Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
      current_attempts.(command_index) <- attempt)
  in
  let finish_close_event ~sw close_event =
    if should_retry close_event then (
      let next_attempt = Close_event.attempt close_event + 1 in
      let delay_ms = Run_policy.restart_delay_ms policy ~next_attempt in
      set_current_attempt
        (Command.index (Close_event.command close_event))
        next_attempt;
      Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
        let command_index = Command.index (Close_event.command close_event) in
        retry_pending_command_indexes :=
          command_index :: !retry_pending_command_indexes
          |> List.sort_uniq Int.compare);
      add_close_event close_event;
      emit_lifecycle
        ~command:(Close_event.command close_event)
        ~attempt:(Close_event.attempt close_event)
        (Output_event.Restarting { next_attempt; delay_ms = Some delay_ms });
      `Retry (next_attempt, delay_ms))
    else (
      add_close_event close_event;
      if Run_policy.should_kill_after_close policy close_event then
        match signal_siblings ~sw close_event with
        | Ok () -> ()
        | Error error -> record_failure error
      else ();
      `Done)
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
              assert (String.trim process.Runner_backend.process_id <> "");
              starting_command_indexes :=
                List.filter
                  (fun starting_command_index ->
                    starting_command_index <> command_index)
                  !starting_command_indexes;
              let pending_input =
                List.rev pending_input_chunks.(command_index)
              in
              pending_input_chunks.(command_index) <- [];
              let close_stdin_after_spawn =
                !input_source_closed || not stdin_should_follow_input
              in
              running_processes :=
                { command_index; process } :: !running_processes;
              `Process
                ( process
                , !termination_signal
                , pending_input
                , close_stdin_after_spawn )
            | exception exn -> `Spawn_error exn)
      in
      match spawn_result with
      | `Closed ->
        remove_active command_index;
        `Done
      | `Process
          (process, signal_after_spawn, pending_input, close_stdin_after_spawn)
        ->
        List.iter
          (write_process_input command_index process)
          pending_input;
        if close_stdin_after_spawn then close_process_stdin process;
        (match signal_after_spawn with
         | None -> ()
         | Some signal ->
           signal_process_after_latched_termination command_index process signal);
        let reader_failure, resolve_reader_failure = Eio.Promise.create () in
        let run_reader ~stream source =
          let result =
            match
              read_output
                ~emit_event:emit
                ~command
                ~attempt
                ~process_id:(Some process.Runner_backend.process_id)
                ~stream
                source
            with
            | Ok () -> Ok ()
            | Error _ as error -> error
            | exception exn ->
              Error (`Unexpected_runner_error (Printexc.to_string exn))
          in
          (match result with
           | Ok () -> ()
           | Error error ->
             ignore (process.Runner_backend.signal Sys.sigkill);
             ignore (Eio.Promise.try_resolve resolve_reader_failure error));
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
              Error (`Unexpected_runner_error (Printexc.to_string exn)))
        in
        let stdout_reader =
          Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
            run_reader
              ~stream:Output_event.Stdout
              process.Runner_backend.stdout)
        in
        let stderr_reader =
          Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
            run_reader
              ~stream:Output_event.Stderr
              process.Runner_backend.stderr)
        in
        let first_completion =
          Eio.Fiber.first
            (fun () -> `Process (await_process process_status))
            (fun () -> `Reader_failure (Eio.Promise.await reader_failure))
        in
        let forced_reader_error, process_result =
          match first_completion with
          | `Process (Ok status) -> None, Ok status
          | `Process (Error error) ->
            ignore (process.Runner_backend.signal Sys.sigkill);
            None, Error error
          | `Reader_failure error ->
            ignore (process.Runner_backend.signal Sys.sigkill);
            Some error, await_process process_status
        in
        (match process_result with
         | Error error ->
           record_failure error;
           remove_running command_index;
           remove_active command_index;
           `Done
         | Ok process_status ->
           let ended_at = now () in
           let killed = command_was_killed command_index in
           mark_exited command_index;
           let close_action =
             match
               create_close_event
                 ~command
                 ~attempt
                 ~killed
                 ~status:process_status
                 ~started_at
                 ~ended_at
             with
             | Closed close_event ->
               let next_action = finish_close_event ~sw close_event in
               `Closed next_action
             | Failed error ->
               record_failure error;
               `Failed
           in
           let stdout_result = await_reader stdout_reader in
           let stderr_result = await_reader stderr_reader in
           let reader_error =
             match forced_reader_error, stdout_result, stderr_result with
             | Some error, _, _ -> Some error
             | None, Error error, _ | None, _, Error error -> Some error
             | None, Ok (), Ok () -> None
           in
           (match reader_error with
            | Some error ->
              record_failure error;
              remove_running command_index;
              remove_active command_index;
              `Done
            | None ->
           let next_action =
             match close_action with
             | `Closed next_action ->
               emit_lifecycle ~command ~attempt Output_event.Stopped;
               next_action
             | `Failed -> `Done
           in
           remove_running command_index;
           remove_active command_index;
           next_action))
      | `Spawn_error exn ->
        remove_starting command_index;
        let ended_at = now () in
        let command_result =
          create_close_event
            ~command
            ~attempt
            ~killed:false
            ~status:(Close_event.Spawn_error (Printexc.to_string exn))
            ~started_at
            ~ended_at
        in
        (match command_result with
         | Closed close_event ->
           let next_action = finish_close_event ~sw close_event in
           remove_active command_index;
           next_action
         | Failed error ->
           record_failure error;
           remove_active command_index;
           `Done))
  in
  let run_command_attempt_with_slot ~sw command attempt =
    Eio.Semaphore.acquire process_slots;
    Fun.protect
      ~finally:(fun () -> Eio.Semaphore.release process_slots)
      (fun () -> run_command_attempt ~sw command attempt)
  in
  let retry_sleep_quantum_seconds = 0.05 in
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
        else (
          sleep (min remaining_seconds retry_sleep_quantum_seconds);
          loop ())
    in
    loop ()
  in
  let rec run_command_loop ~sw command attempt =
    if command_is_closed (Command.index command) then ()
    else
      match run_command_attempt_with_slot ~sw command attempt with
      | `Done -> ()
      | `Retry (next_attempt, delay_ms) ->
        if delay_ms <= 0 || sleep_until_retry_or_close command delay_ms then
          run_command_loop ~sw command next_attempt
  in
  let run_command ~sw command = run_command_loop ~sw command 0 in
  let emit_teardown_lifecycle ~command lifecycle =
    create_lifecycle_event ~command ~attempt:0 lifecycle |> emit_best_effort
  in
  let run_teardown_reader ~command ~process ~stream source =
    match
      read_output
        ~emit_event:emit
        ~command
        ~attempt:0
        ~process_id:(Some process.Runner_backend.process_id)
        ~stream
        source
    with
    | Ok () -> ()
    | Error _ ->
      ignore (process.Runner_backend.signal Sys.sigkill)
    | exception _ ->
      ignore (process.Runner_backend.signal Sys.sigkill)
  in
  let run_teardown_command command =
    let command_index = Command.index command in
    emit_teardown_lifecycle ~command Output_event.Started;
    Eio.Switch.run ~name:"Runner.teardown" (fun command_sw ->
      let spawn_result =
        Eio.Mutex.use_rw ~protect:true state_mutex (fun () ->
          match backend.Runner_backend.spawn ~sw:command_sw ~command with
          | process ->
            assert (String.trim process.Runner_backend.process_id <> "");
            running_processes :=
              { command_index; process } :: !running_processes;
            `Process process
          | exception exn -> `Spawn_error exn)
      in
      match spawn_result with
      | `Spawn_error exn ->
        teardown_spawn_error_event ~command ~message:(Printexc.to_string exn)
        |> emit_best_effort;
        emit_teardown_lifecycle ~command Output_event.Stopped
      | `Process process ->
        close_process_stdin process;
        let stdout_reader =
          Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
            run_teardown_reader
              ~command
              ~process
              ~stream:Output_event.Stdout
              process.Runner_backend.stdout)
        in
        let stderr_reader =
          Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
            run_teardown_reader
              ~command
              ~process
              ~stream:Output_event.Stderr
              process.Runner_backend.stderr)
        in
        (match process.Runner_backend.await () with
         | _status -> ()
         | exception _ -> ());
        (match Eio.Promise.await_exn stdout_reader with
         | () -> ()
         | exception _ -> ());
        (match Eio.Promise.await_exn stderr_reader with
         | () -> ()
         | exception _ -> ());
        remove_running command_index;
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
            if close_event_completes_command close_event then remaining - 1
            else remaining
          in
          collect remaining (close_event :: collected)
        | Failed error -> raise (Fatal_runner_error error))
    in
    collect command_count []
  in
  let run_main_commands () =
    Eio.Switch.run ~name:"Runner.run" (fun sw ->
      List.iter
        (fun command -> Eio.Fiber.fork ~sw (fun () -> run_command ~sw command))
        commands;
      (match input, input_source with
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
  match
    with_forwarded_termination_signals
      ~cleanup:
        (fun signal ->
          if Option.is_none !termination_signal then
            termination_signal := Some signal;
          signal_running_process_groups signal)
      run_main_then_teardown
  with
  | `Interrupted (signal, _) ->
    Unix.kill (Unix.getpid ()) signal;
    Error (`Unexpected_runner_error "termination signal was not delivered")
  | `Completed (Error error) -> Error error
  | `Completed (Ok close_events) ->
    (match recorded_failure () with
     | Some error -> Error error
     | None ->
       (match
          Run_result.create
            ~spec
            ~close_events
            ~output_event_count:!output_event_count
            ~interrupted:false
        with
        | Ok result -> Ok result
        | Error error -> Error (`Run_result_error error)))
  | exception Fatal_runner_error error -> Error error
  | exception exn -> Error (`Unexpected_runner_error (Printexc.to_string exn))
  in
  match validate_kill_signal policy with
  | Ok () -> run_after_validation ()
  | Error error -> Error error

let close_event_error_message = function
  | `Empty_signal -> "close event signal must not be empty"
  | `Empty_spawn_error -> "spawn error message must not be empty"
  | `Negative_attempt -> "close event attempt must not be negative"
  | `Negative_exit_code -> "close event exit code must not be negative"
  | `Ended_before_started -> "close event ended before it started"

let output_event_error_message = function
  | `Invalid_next_attempt (attempt, next_attempt) ->
    Printf.sprintf
      "invalid restart transition from attempt %d to %d"
      attempt
      next_attempt
  | `Negative_attempt -> "output event attempt must not be negative"
  | `Negative_delay_ms -> "restart delay must not be negative"

let run_result_error_message = function
  | `Attempt_after_success (command_index, attempt) ->
    Printf.sprintf
      "command %d has attempt %d after success"
      command_index
      attempt
  | `Attempt_exceeds_restart_tries (command_index, attempt) ->
    Printf.sprintf
      "command %d attempt %d exceeds restart tries"
      command_index
      attempt
  | `Duplicate_close_event_attempt (command_index, attempt) ->
    Printf.sprintf
      "command %d has duplicate close event for attempt %d"
      command_index
      attempt
  | `Incomplete_restart_attempt (command_index, attempt) ->
    Printf.sprintf
      "command %d attempt %d needs a restart or final close"
      command_index
      attempt
  | `Missing_close_event_attempt (command_index, attempt) ->
    Printf.sprintf
      "command %d is missing close event for attempt %d"
      command_index
      attempt
  | `Missing_close_events -> "run is missing close events"
  | `Negative_output_event_count -> "output event count must not be negative"
  | `Too_many_close_events -> "run has too many close events"
  | `Unexpected_command command_index ->
    Printf.sprintf "unexpected command at index %d" command_index
  | `Unknown_command_index command_index ->
    Printf.sprintf "unknown command index %d" command_index

let error_message = function
  | `Close_event_error (command_index, error) ->
    Printf.sprintf
      "command %d close event is invalid: %s"
      command_index
      (close_event_error_message error)
  | `Output_event_error (command_index, error) ->
    Printf.sprintf
      "command %d output event is invalid: %s"
      command_index
      (output_event_error_message error)
  | `Run_result_error error -> run_result_error_message error
  | `Unsupported_kill_signal signal ->
    Printf.sprintf "unsupported kill signal for runner: %s" signal
  | `Unexpected_runner_error message -> message
