module Command = Concurrentlyocaml.Command
module Close_event = Concurrentlyocaml.Close_event
module Output_event = Concurrentlyocaml.Output_event
module Run_policy = Concurrentlyocaml.Run_policy
module Run_result = Concurrentlyocaml.Run_result
module Runner_backend = Concurrentlyocaml.Runner_backend
module Runner = Concurrentlyocaml.Runner
module Run_spec = Concurrentlyocaml.Run_spec

open Domain_test_support
open Runner_test_support

let test_runner_reports_signal_failure () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ]
         ~kill_signal:Run_policy.Sigterm ())
  in
  let commands = [ command 0 "failing"; command 1 "stubborn" ] in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.05;
                        Close_event.Exited 1)
                      ()
                | 1 ->
                    backend_process
                      ~signal:(fun _ -> Error "signal failed")
                      ~await:(fun () ->
                        Eio.Time.sleep clock 1.0;
                        Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  assert (elapsed < 0.5);
  match result with
  | Error (`Unexpected_runner_error "signal failed") -> ()
  | Ok _ | Error _ -> assert false

let test_runner_preserves_retry_after_parent_signal_spawn_race () =
  let signaled = ref None in
  let spawn_count = ref 0 in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command:_ ->
                incr spawn_count;
                if !spawn_count = 1 then (
                  Unix.kill (Unix.getpid ()) Sys.sigterm;
                  backend_process
                    ~signal:(fun signal ->
                      signaled := Some signal;
                      Ok true)
                    ~await:(fun () ->
                      let deadline = Eio.Time.now clock +. 0.4 in
                      while
                        Option.is_none !signaled
                        && Eio.Time.now clock < deadline
                      do
                        Eio.Time.sleep clock 0.01
                      done;
                      match !signaled with
                      | Some signal ->
                          Close_event.Signaled
                            (string_of_int (Sys.signal_to_int signal))
                      | None -> Close_event.Exited 99)
                    ())
                else backend_process ~await:(fun () -> Close_event.Exited 0) ());
          }
        in
        let policy = ok (Run_policy.create ~restart_tries:1 ()) in
        let spec =
          ok
            (Run_spec.create
               ~commands:[ command 0 "starting" ]
               ~policy)
        in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  let close_events = Run_result.close_events result in
  assert (!spawn_count = 2);
  assert (!signaled = Some Sys.sigterm);
  assert (
    List.exists
      (fun close_event ->
        Close_event.attempt close_event = 0
        && Close_event.killed close_event
        && Close_event.status close_event
           = Close_event.Signaled
               (string_of_int (Sys.signal_to_int Sys.sigterm)))
      close_events);
  assert (
    List.exists
      (fun close_event ->
        Close_event.attempt close_event = 1
        && (not (Close_event.killed close_event))
        && Close_event.status close_event = Close_event.Exited 0)
      close_events);
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0)

let test_runner_skips_queued_command_at_parent_signal_time () =
  let policy = ok (Run_policy.create ~max_processes:1 ()) in
  let commands = [ command 0 "running"; command 1 "queued" ] in
  let spawn_order = ref [] in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                let command_index = Command.index command in
                spawn_order := command_index :: !spawn_order;
                match command_index with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Unix.kill (Unix.getpid ()) Sys.sigterm;
                        Close_event.Exited 0)
                      ()
                | 1 -> backend_process ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  assert (List.rev !spawn_order = [ 0 ]);
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0)

let test_runner_parent_signal_does_not_mark_unsignaled_exit_as_killed () =
  let signal_attempted = ref false in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command:_ ->
                backend_process
                  ~signal:(fun _signal ->
                    signal_attempted := true;
                    Ok false)
                  ~await:(fun () ->
                    Unix.kill (Unix.getpid ()) Sys.sigterm;
                    Eio.Time.sleep clock 0.05;
                    Close_event.Exited 0)
                  ());
          }
        in
        let spec =
          ok
            (Run_spec.create
               ~commands:[ command 0 "already-exited" ]
               ~policy:Run_policy.default)
        in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  let close_event =
    match Run_result.close_events result with
    | [ close_event ] -> close_event
    | _ -> assert false
  in
  assert !signal_attempted;
  assert (not (Close_event.killed close_event));
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0)

let test_runner_parent_sigint_completes_restartable_running_command () =
  let policy = ok (Run_policy.create ~restart_tries:1 ()) in
  let signaled = ref false in
  let spawn_count = ref 0 in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command:_ ->
                incr spawn_count;
                backend_process
                  ~signal:(fun signal ->
                    assert (signal = Sys.sigint);
                    signaled := true;
                    Ok true)
                  ~await:(fun () ->
                    Unix.kill (Unix.getpid ()) Sys.sigint;
                    let deadline = Eio.Time.now clock +. 0.4 in
                    while (not !signaled) && Eio.Time.now clock < deadline do
                      Eio.Time.sleep clock 0.01
                    done;
                    if !signaled then Close_event.Signaled "2"
                    else Close_event.Exited 99)
                  ());
          }
        in
        let spec =
          ok
            (Run_spec.create
               ~commands:[ command 0 "restartable" ]
               ~policy)
        in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  assert !signaled;
  assert (!spawn_count = 1);
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0)

let test_runner_keeps_draining_process_until_close_recorded () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~success_condition:(Run_policy.Commands [ 0 ]) ())
  in
  let commands = [ command 0 "chatty-success"; command 1 "fast-success" ] in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~stdout:
                        (slow_eof_source ~sleep:(fun () ->
                             Eio.Time.sleep clock 0.25))
                      ~await:(fun () -> Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.05;
                        Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  let first_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 0)
  in
  assert (Run_result.exit_code result = 0);
  assert (not (Close_event.killed first_close_event));
  assert (Close_event.status first_close_event = Close_event.Exited 0)

let test_runner_does_not_mark_unsignaled_sibling_as_killed () =
  let policy =
    ok
      (Run_policy.create
         ~kill_others_on:[ Run_policy.Success; Run_policy.Failure ]
         ~kill_signal:Run_policy.Sigterm ())
  in
  let commands = [ command 0 "successful"; command 1 "already-exiting" ] in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.05;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~signal:(fun _ -> Ok false)
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.10;
                        Close_event.Exited 1)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  let sibling_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 1)
  in
  assert (Run_result.exit_code result = 1);
  assert (not (Close_event.killed sibling_close_event));
  assert (Close_event.status sibling_close_event = Close_event.Exited 1)

let test_runner_kills_siblings_on_failure () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ]
         ~kill_signal:Run_policy.Sigterm ())
  in
  let started_at = Unix.gettimeofday () in
  let result, events =
    run_with_events ~policy [ "sleep 2; printf slow"; "exit 1" ]
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  assert (Run_result.exit_code result = 1);
  assert (elapsed < 3.0);
  assert (
    status_messages events = [ "--> Sending SIGTERM to other processes.." ])

let test_runner_force_kills_siblings_after_kill_timeout () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:50 ())
  in
  let commands = [ command 0 "successful"; command 1 "stubborn" ] in
  let signaled = ref [] in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.02;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~signal:(fun signal ->
                        signaled := signal :: !signaled;
                        Ok true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.5 in
                        while
                          (not (List.mem Sys.sigkill !signaled))
                          && Eio.Time.now clock < deadline
                        do
                          Eio.Time.sleep clock 0.01
                        done;
                        if List.mem Sys.sigkill !signaled then
                          Close_event.Signaled "9"
                        else Close_event.Exited 99)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  let sibling_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 1)
  in
  assert (elapsed < 0.5);
  assert (List.rev !signaled = [ Sys.sigterm; Sys.sigkill ]);
  assert (Close_event.killed sibling_close_event);
  assert (Close_event.status sibling_close_event = Close_event.Signaled "9")

let test_posix_runner_waits_kill_timeout_before_group_cleanup () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:200 ())
  in
  let commands =
    [
      command 0 "sleep 0.05";
      command 1
        "trap - TERM; sh -c 'trap \"\" TERM HUP; while true; do sleep 10; \
         done' & wait";
    ]
  in
  let started_at = Unix.gettimeofday () in
  let result, events = run_commands_with_events ~policy commands in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  assert (elapsed >= 0.15);
  (* Waiting through the timeout is stable; total cleanup latency can still vary
     across shells and loaded runners. *)
  assert (elapsed < 5.0);
  assert (Run_result.exit_code result = 1);
  (* Waiting through the kill timeout is the stable contract here. Whether the
     runner still has backend-owned descendants to SIGKILL depends on shell
     scheduling once the root process exits. *)
  assert (List.mem "--> Sending SIGTERM to other processes.." (status_messages events))

let test_runner_does_not_wait_kill_timeout_after_graceful_signal_exit () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:500 ())
  in
  let commands = [ command 0 "successful"; command 1 "graceful" ] in
  let signaled = ref [] in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.02;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~signal:(fun signal ->
                        signaled := signal :: !signaled;
                        Ok true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.25 in
                        while !signaled = [] && Eio.Time.now clock < deadline do
                          Eio.Time.sleep clock 0.01
                        done;
                        Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  let sibling_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 1)
  in
  assert (elapsed < 0.4);
  assert (List.rev !signaled = [ Sys.sigterm ]);
  assert (Close_event.killed sibling_close_event);
  assert (Close_event.status sibling_close_event = Close_event.Exited 0)

let test_runner_does_not_wait_kill_timeout_after_clean_signal_exit () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:500 ())
  in
  let commands = [ command 0 "successful"; command 1 "signaled" ] in
  let signaled = ref [] in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.02;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~signal:(fun signal ->
                        signaled := signal :: !signaled;
                        Ok true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.25 in
                        while !signaled = [] && Eio.Time.now clock < deadline do
                          Eio.Time.sleep clock 0.01
                        done;
                        Close_event.Signaled
                          (string_of_int (Sys.signal_to_int Sys.sigterm)))
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  let sibling_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 1)
  in
  assert (elapsed < 0.4);
  assert (List.rev !signaled = [ Sys.sigterm ]);
  assert (Close_event.killed sibling_close_event);
  assert (
    Close_event.status sibling_close_event
    = Close_event.Signaled (string_of_int (Sys.signal_to_int Sys.sigterm)))

let test_runner_waits_kill_timeout_before_cleanup_after_graceful_signal_exit ()
    =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:50 ())
  in
  let commands = [ command 0 "successful"; command 1 "graceful" ] in
  let signaled = ref [] in
  let cleanup_called = ref false in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.02;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~stdout:
                        (slow_eof_source ~sleep:(fun () ->
                             while not !cleanup_called do
                               Eio.Time.sleep clock 0.01
                             done))
                      ~signal:(fun signal ->
                        signaled := signal :: !signaled;
                        Ok true)
                      ~needs_cleanup_after_exit:(fun () -> not !cleanup_called)
                      ~cleanup_after_exit:(fun () -> cleanup_called := true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.25 in
                        while !signaled = [] && Eio.Time.now clock < deadline do
                          Eio.Time.sleep clock 0.01
                        done;
                        Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  let sibling_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 1)
  in
  assert (elapsed >= 0.05);
  assert (elapsed < 0.4);
  assert (List.rev !signaled = [ Sys.sigterm; Sys.sigkill ]);
  assert !cleanup_called;
  assert (Run_result.exit_code result = 1);
  assert (Close_event.killed sibling_close_event);
  assert (
    Close_event.status sibling_close_event
    = Close_event.Signaled (string_of_int (Sys.signal_to_int Sys.sigterm)))

let test_runner_waits_kill_timeout_before_cleanup_when_readers_drain_early () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:50 ())
  in
  let commands = [ command 0 "successful"; command 1 "graceful-drained" ] in
  let signaled = ref [] in
  let cleanup_called = ref false in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.02;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~signal:(fun signal ->
                        signaled := signal :: !signaled;
                        Ok true)
                      ~needs_cleanup_after_exit:(fun () -> not !cleanup_called)
                      ~cleanup_after_exit:(fun () -> cleanup_called := true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.25 in
                        while !signaled = [] && Eio.Time.now clock < deadline do
                          Eio.Time.sleep clock 0.01
                        done;
                        Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  let sibling_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 1)
  in
  assert (elapsed >= 0.05);
  assert (elapsed < 0.4);
  assert (List.rev !signaled = [ Sys.sigterm; Sys.sigkill ]);
  assert !cleanup_called;
  assert (Run_result.exit_code result = 1);
  assert (Close_event.killed sibling_close_event);
  assert (
    Close_event.status sibling_close_event
    = Close_event.Signaled (string_of_int (Sys.signal_to_int Sys.sigterm)))

let test_runner_waits_kill_timeout_before_cleanup_after_signal_exit () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:50 ())
  in
  let commands = [ command 0 "successful"; command 1 "signaled" ] in
  let signaled = ref [] in
  let cleanup_called = ref false in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.02;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~stdout:
                        (slow_eof_source ~sleep:(fun () ->
                             while not !cleanup_called do
                               Eio.Time.sleep clock 0.01
                             done))
                      ~signal:(fun signal ->
                        signaled := signal :: !signaled;
                        Ok (signal <> Sys.sigkill))
                      ~needs_cleanup_after_exit:(fun () -> not !cleanup_called)
                      ~cleanup_after_exit:(fun () -> cleanup_called := true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.25 in
                        while !signaled = [] && Eio.Time.now clock < deadline do
                          Eio.Time.sleep clock 0.01
                        done;
                        Close_event.Signaled
                          (string_of_int (Sys.signal_to_int Sys.sigterm)))
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  let sibling_close_event =
    Run_result.close_events result
    |> List.find (fun close_event ->
        Command.index (Close_event.command close_event) = 1)
  in
  assert (elapsed >= 0.05);
  assert (elapsed < 0.4);
  assert (List.rev !signaled = [ Sys.sigterm; Sys.sigkill ]);
  assert !cleanup_called;
  assert (Close_event.killed sibling_close_event);
  assert (
    Close_event.status sibling_close_event
    = Close_event.Signaled (string_of_int (Sys.signal_to_int Sys.sigterm)))

let test_runner_preserves_first_kill_timeout_deadline () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~kill_signal:Run_policy.Sigterm ~kill_timeout_ms:150 ())
  in
  let commands =
    [
      command 0 "successful";
      command 1 "stubborn";
      command 2 "graceful-success";
    ]
  in
  let stubborn_first_sigterm_at = ref None in
  let stubborn_sigkill_at = ref None in
  let graceful_signaled = ref false in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.index command with
                | 0 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.02;
                        Close_event.Exited 0)
                      ()
                | 1 ->
                    backend_process
                      ~signal:(fun signal ->
                        let elapsed = Unix.gettimeofday () -. started_at in
                        if
                          signal = Sys.sigterm
                          && Option.is_none !stubborn_first_sigterm_at
                        then stubborn_first_sigterm_at := Some elapsed;
                        if signal = Sys.sigkill then
                          stubborn_sigkill_at := Some elapsed;
                        Ok true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.6 in
                        while
                          Option.is_none !stubborn_sigkill_at
                          && Eio.Time.now clock < deadline
                        do
                          Eio.Time.sleep clock 0.01
                        done;
                        match !stubborn_sigkill_at with
                        | Some _ -> Close_event.Signaled "9"
                        | None -> Close_event.Exited 99)
                      ()
                | 2 ->
                    backend_process
                      ~signal:(fun signal ->
                        assert (signal = Sys.sigterm);
                        graceful_signaled := true;
                        Ok true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.6 in
                        while
                          (not !graceful_signaled)
                          && Eio.Time.now clock < deadline
                        do
                          Eio.Time.sleep clock 0.01
                        done;
                        Eio.Time.sleep clock 0.10;
                        Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let _result = ok result in
  match (!stubborn_first_sigterm_at, !stubborn_sigkill_at) with
  | Some sigterm_at, Some sigkill_at ->
      let force_kill_delay = sigkill_at -. sigterm_at in
      assert (force_kill_delay >= 0.15);
      assert (force_kill_delay < 0.23)
  | _ -> assert false

let test_runner_does_not_mark_draining_exited_process_as_killed () =
  let marker = Filename.temp_file "concurrently-draining" ".state" in
  Sys.remove marker;
  let policy =
    ok
      (Run_policy.create
         ~kill_others_on:[ Run_policy.Success; Run_policy.Failure ]
         ~kill_signal:Run_policy.Sigterm ())
  in
  let successful_command =
    Printf.sprintf "while [ ! -f %s ]; do sleep 0.01; done; sleep 0.5; exit 0"
      (Filename.quote marker)
  in
  let failed_command =
    Printf.sprintf
      "i=0; while [ \"$i\" -lt 10000 ]; do printf \
       xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; \
       i=$((i + 1)); done; printf ready > %s; exit 1"
      (Filename.quote marker)
  in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists marker then Sys.remove marker)
    (fun () ->
      let result, _events =
        run_with_events ~policy [ successful_command; failed_command ]
      in
      let result = ok result in
      let failed_close_event =
        Run_result.close_events result
        |> List.find (fun close_event ->
            Command.index (Close_event.command close_event) = 1)
      in
      assert (Run_result.exit_code result = 1);
      assert (not (Close_event.killed failed_close_event));
      assert (Close_event.status failed_close_event = Close_event.Exited 1))

let test_runner_skips_queued_commands_after_failure () =
  let policy =
    ok
      (Run_policy.create ~max_processes:1 ~kill_others_on:[ Run_policy.Failure ]
         ~kill_signal:Run_policy.Sigterm ())
  in
  let result, events = run_with_events ~policy [ "exit 1"; "printf queued" ] in
  let result = ok result in
  assert (Run_result.exit_code result = 1);
  assert (
    Run_result.close_events result
    |> List.for_all (fun close_event ->
        Command.index (Close_event.command close_event) <> 1));
  assert (not (List.mem 1 (stopped_command_indexes events)));
  let stop_and_status_order =
    events
    |> List.filter_map (fun event ->
        match Output_event.payload event with
        | Output_event.Lifecycle_payload
            (Output_event.Stopped_with_status _ | Output_event.Stopped) ->
            Option.map
              (fun command -> `Stopped (Command.index command))
              (Output_event.command event)
        | Output_event.Status_message_payload _ -> Some `Status
        | _ -> None)
  in
  assert (stop_and_status_order = [ `Stopped 0 ]);
  assert (status_messages events = []);
  assert (not (List.mem "queued" (output_chunks events)))

let test_runner_skips_queued_commands_after_success () =
  let policy =
    ok
      (Run_policy.create ~max_processes:1
         ~kill_others_on:[ Run_policy.Success; Run_policy.Failure ]
         ~kill_signal:Run_policy.Sigterm ())
  in
  let result, events =
    run_with_events ~policy [ "printf ok"; "printf queued" ]
  in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (
    Run_result.close_events result
    |> List.for_all (fun close_event ->
        Command.index (Close_event.command close_event) <> 1));
  assert (not (List.mem 1 (stopped_command_indexes events)));
  assert (status_messages events = []);
  assert (not (List.mem "queued" (output_chunks events)))

let test_runner_applies_close_policy_before_descendant_pipe_eof () =
  let marker = Filename.temp_file "concurrently-sibling" ".state" in
  Sys.remove marker;
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ]
         ~kill_signal:Run_policy.Sigterm ())
  in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists marker then Sys.remove marker)
    (fun () ->
      let started_at = Unix.gettimeofday () in
      let result, events =
        run_with_events ~policy
          [
            Printf.sprintf
              "while [ ! -f %s ]; do sleep 0.01; done; sleep 5 & exit 1"
              (Filename.quote marker);
            Printf.sprintf
              "printf ready > %s; trap 'printf sibling-killed; exit 0' TERM; \
               while true; do sleep 1; done"
              (Filename.quote marker);
          ]
      in
      let elapsed = Unix.gettimeofday () -. started_at in
      let result = ok result in
      assert (Run_result.exit_code result = 1);
      assert (elapsed < 2.0);
      assert (List.mem "sibling-killed" (output_chunks events)))

let run_parent_signal_contracts () =
  test_runner_reports_signal_failure ();
  test_runner_preserves_retry_after_parent_signal_spawn_race ();
  test_runner_skips_queued_command_at_parent_signal_time ();
  test_runner_parent_signal_does_not_mark_unsignaled_exit_as_killed ();
  test_runner_parent_sigint_completes_restartable_running_command ();
  test_runner_keeps_draining_process_until_close_recorded ();
  test_runner_does_not_mark_unsignaled_sibling_as_killed ()

let run_shutdown_contracts () =
  test_runner_kills_siblings_on_failure ();
  test_runner_force_kills_siblings_after_kill_timeout ();
  test_posix_runner_waits_kill_timeout_before_group_cleanup ();
  test_runner_does_not_wait_kill_timeout_after_graceful_signal_exit ();
  test_runner_does_not_wait_kill_timeout_after_clean_signal_exit ();
  test_runner_waits_kill_timeout_before_cleanup_after_graceful_signal_exit ();
  test_runner_waits_kill_timeout_before_cleanup_when_readers_drain_early ();
  test_runner_waits_kill_timeout_before_cleanup_after_signal_exit ();
  test_runner_preserves_first_kill_timeout_deadline ();
  test_runner_does_not_mark_draining_exited_process_as_killed ();
  test_runner_skips_queued_commands_after_failure ();
  test_runner_skips_queued_commands_after_success ();
  test_runner_applies_close_policy_before_descendant_pipe_eof ()
