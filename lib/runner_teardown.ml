type signal_outcome = Delivered | Failed of string

type signal_event = {
  signal_number : int;
  signal_outcome : signal_outcome;
}

type force_kill_state = Idle | Armed of float | Sent

type active_process = {
  process : Runner_backend.process;
  last_parent_signal_generation : int ref;
}

type t = {
  backend : Runner_backend.t;
  now : unit -> float;
  sleep : float -> unit;
  policy : Run_policy.t;
  output : Runner_output.t;
  active_process : active_process option ref;
  pending_signals : signal_event list Atomic.t;
}

let create ~backend ~now ~sleep ~policy ~output =
  {
    backend;
    now;
    sleep;
    policy;
    output;
    active_process = ref None;
    pending_signals = Atomic.make [];
  }

let rec atomic_stack_push stack value =
  let pending = Atomic.get stack in
  if not (Atomic.compare_and_set stack pending (value :: pending)) then (
    Domain.cpu_relax ();
    atomic_stack_push stack value)

let emit_error t ~command message =
  Runner_output.output_chunk_best_effort t.output ~command ~attempt:0
    ~process_id:None ~stream:Output_event.Stderr ~chunk:message
    ~line_terminated:true

let emit_status t message =
  Output_event.status_message ~after_command:None ~stream:Output_event.Stdout
    ~chunk:("--> " ^ message)
  |> Runner_output.emit_best_effort t.output

let emit_lifecycle t ~command lifecycle =
  Runner_output.lifecycle_best_effort t.output ~command ~attempt:0 lifecycle

let queue_signal_result t ~signal = function
  | Ok true ->
      atomic_stack_push t.pending_signals
        { signal_number = signal; signal_outcome = Delivered }
  | Ok false -> ()
  | Error message ->
      atomic_stack_push t.pending_signals
        { signal_number = signal; signal_outcome = Failed message }

let signal_process t active signal =
  active.process.Runner_backend.signal signal
  |> queue_signal_result t ~signal

let handle_parent_signal t
    (parent_signal : Runner_parent_signals.signal) =
  match !(t.active_process) with
  | Some active
    when parent_signal.generation > !(active.last_parent_signal_generation) ->
      active.last_parent_signal_generation := parent_signal.generation;
      signal_process t active parent_signal.number
  | Some _ | None -> ()

let take_signal_events t =
  Atomic.exchange t.pending_signals [] |> List.rev

let emit_signal_errors t ~command events =
  List.iter
    (fun event ->
      match event.signal_outcome with
      | Delivered -> ()
      | Failed message ->
          emit_error t ~command
            ("teardown command failed to signal: " ^ message))
    events

let flush_signal_errors t ~command =
  take_signal_events t |> emit_signal_errors t ~command

let close_stdin t ~command process =
  match process.Runner_backend.close_stdin () with
  | () -> ()
  | exception exn ->
      emit_error t ~command
        ("teardown command failed to close stdin: " ^ Printexc.to_string exn)

let signal_best_effort t ~command process signal =
  match process.Runner_backend.signal signal with
  | Ok true | Ok false -> ()
  | Error message ->
      emit_error t ~command ("teardown command failed to signal: " ^ message)

let signal_silently process signal =
  match process.Runner_backend.signal signal with
  | Ok true | Ok false | Error _ -> ()

let run_reader t ~command ~process ~stream source =
  let result =
    match
      Runner_output_reader.read
        ~emit_event:(Runner_output.emit t.output)
        ~command ~attempt:0 ~process_id:(Some process.Runner_backend.process_id)
        ~stream source
    with
    | Ok () -> Ok ()
    | Error (`Unexpected_runner_error message) -> Error message
    | Error (`Output_event_error (command_index, error)) ->
        Error
          (Printf.sprintf "command %d output event is invalid: %s"
             command_index (Runner_output.create_error_message error))
    | exception exn -> Error (Printexc.to_string exn)
  in
  (match result with
  | Ok () -> ()
  | Error _ -> signal_best_effort t ~command process Sys.sigkill);
  result

let await_reader reader =
  match Eio.Promise.await_exn reader with
  | Ok () -> Ok ()
  | Error _ as error -> error
  | exception exn -> Error (Printexc.to_string exn)

let cleanup_process t ~command process =
  match process.Runner_backend.cleanup_after_exit () with
  | () -> ()
  | exception exn ->
      emit_error t ~command
        ("teardown command cleanup failed: " ^ Printexc.to_string exn)

let await_process_status process =
  match process.Runner_backend.await () with
  | status -> Ok status
  | exception exn -> Error (Printexc.to_string exn)

let await_process t ~sw ~command ~process =
  let process_status =
    Eio.Fiber.fork_promise ~sw (fun () -> await_process_status process)
  in
  let force_kill_state = ref Idle in
  let send_force_kill_now () =
    match !force_kill_state with
    | Sent -> ()
    | Idle | Armed _ ->
        signal_silently process Sys.sigkill;
        force_kill_state := Sent
  in
  let arm_force_kill_deadline delay_seconds =
    Option.iter
      (Runner_output.warn_once t.output Runner_output.Kill_timeout)
      (Run_policy.kill_timeout_warning t.policy);
    force_kill_state := Armed (t.now () +. delay_seconds)
  in
  let schedule_force_kill outcome signal =
    match !force_kill_state with
    | Sent -> ()
    | Idle | Armed _ when signal = Sys.sigkill -> (
        match outcome with
        | Runner_kill_timeout.Succeeded -> force_kill_state := Sent
        | Runner_kill_timeout.Failed -> send_force_kill_now ())
    | Armed _ -> ()
    | Idle -> (
        match Runner_kill_timeout.after_signal t.policy outcome ~signal with
        | Runner_kill_timeout.Do_nothing -> ()
        | Runner_kill_timeout.Kill_now -> send_force_kill_now ()
        | Runner_kill_timeout.Kill_after delay_seconds ->
            arm_force_kill_deadline delay_seconds)
  in
  let pause_until_next_poll () =
    match !force_kill_state with
    | Armed deadline ->
        let remaining = deadline -. t.now () in
        if remaining <= 0.0 then 0.001 else min 0.01 remaining
    | Idle | Sent -> 0.01
  in
  let rec loop () =
    let signal_events = take_signal_events t in
    emit_signal_errors t ~command signal_events;
    List.iter
      (fun event ->
        match event.signal_outcome with
        | Delivered ->
            schedule_force_kill Runner_kill_timeout.Succeeded
              event.signal_number
        | Failed _ ->
            (* If the graceful signal never landed, fall back immediately
               unless a timeout explicitly asked us to wait first. *)
            schedule_force_kill Runner_kill_timeout.Failed event.signal_number)
      signal_events;
    if Eio.Promise.is_resolved process_status then
      let status = Eio.Promise.await_exn process_status in
      match (status, !force_kill_state) with
      | Ok _, Armed deadline
        when process.Runner_backend.needs_cleanup_after_exit () ->
          if t.now () >= deadline then (
            send_force_kill_now ();
            status)
          else (
            t.sleep (pause_until_next_poll ());
            loop ())
      | (Ok _ | Error _), (Idle | Armed _ | Sent) -> status
    else (
      (match !force_kill_state with
      | Armed deadline when t.now () >= deadline -> send_force_kill_now ()
      | Idle | Armed _ | Sent -> ());
      t.sleep (pause_until_next_poll ());
      loop ())
  in
  loop ()

let reader_errors stdout_reader stderr_reader =
  [ await_reader stdout_reader; await_reader stderr_reader ]
  |> List.filter_map (function Ok () -> None | Error message -> Some message)

let emit_reader_errors t ~command errors =
  List.iter
    (fun message ->
      emit_error t ~command
        ("teardown command output read failed: " ^ message))
    errors

let clear_active_process t = t.active_process := None

let run_command t ~parent_signals command =
  let parent_signal_generation_before_spawn =
    match Runner_parent_signals.current parent_signals with
    | Some current -> current.generation
    | None -> 0
  in
  emit_status t
    (Printf.sprintf "Running teardown command \"%s\"" (Command.text command));
  emit_lifecycle t ~command Output_event.Started;
  Eio.Switch.run ~name:"Runner.teardown" (fun command_sw ->
      let spawn_result =
        match t.backend.Runner_backend.spawn ~sw:command_sw ~command with
        | process ->
            assert (String.trim process.Runner_backend.process_id <> "");
            let active =
              {
                process;
                last_parent_signal_generation =
                  ref parent_signal_generation_before_spawn;
              }
            in
            t.active_process := Some active;
            `Process active
        | exception exn -> `Spawn_error exn
      in
      match spawn_result with
      | `Spawn_error exn ->
          emit_error t ~command
            ("teardown command failed to spawn: " ^ Printexc.to_string exn);
          emit_lifecycle t ~command Output_event.Stopped
      | `Process active ->
          let process = active.process in
          close_stdin t ~command process;
          Runner_parent_signals.serialize parent_signals (fun () ->
              match Runner_parent_signals.current parent_signals with
              | Some parent_signal -> handle_parent_signal t parent_signal
              | None -> ());
          let stdout_reader =
            Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
                run_reader t ~command ~process ~stream:Output_event.Stdout
                  process.Runner_backend.stdout)
          in
          let stderr_reader =
            Eio.Fiber.fork_promise ~sw:command_sw (fun () ->
                run_reader t ~command ~process ~stream:Output_event.Stderr
                  process.Runner_backend.stderr)
          in
          let close_status = await_process t ~sw:command_sw ~command ~process in
          (match close_status with
          | Error message ->
              signal_best_effort t ~command process Sys.sigkill;
              cleanup_process t ~command process;
              let errors = reader_errors stdout_reader stderr_reader in
              clear_active_process t;
              flush_signal_errors t ~command;
              emit_reader_errors t ~command errors;
              emit_error t ~command
                ("teardown command failed to await: " ^ message)
          | Ok status ->
              cleanup_process t ~command process;
              let errors = reader_errors stdout_reader stderr_reader in
              clear_active_process t;
              flush_signal_errors t ~command;
              (match errors with
              | [] ->
                  emit_status t
                    (Printf.sprintf
                       "Teardown command \"%s\" exited with code %s"
                       (Command.text command)
                       (Process_signal.exit_status_label status))
              | errors -> emit_reader_errors t ~command errors));
          emit_lifecycle t ~command Output_event.Stopped)

let run_all t ~parent_signals =
  Run_policy.teardown t.policy
  |> List.iter (run_command t ~parent_signals)
