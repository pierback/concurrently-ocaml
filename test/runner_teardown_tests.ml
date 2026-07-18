module Command = Concurrentlyocaml.Command
module Close_event = Concurrentlyocaml.Close_event
module Run_policy = Concurrentlyocaml.Run_policy
module Run_result = Concurrentlyocaml.Run_result
module Runner_backend = Concurrentlyocaml.Runner_backend
module Runner = Concurrentlyocaml.Runner
module Run_spec = Concurrentlyocaml.Run_spec

open Domain_test_support
open Runner_test_support

let test_runner_executes_teardown_without_affecting_exit_code () =
  let main_command = command 0 "main" in
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let spawned_commands = ref [] in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          spawned_commands := Command.text command :: !spawned_commands;
          match Command.text command with
          | "main" ->
              backend_process
                ~stdout:(Eio.Flow.string_source "main-output\n")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | "cleanup" ->
              backend_process
                ~stdout:(Eio.Flow.string_source "cleanup-output")
                ~await:(fun () -> Close_event.Exited 1)
                ()
          | _ -> assert false);
    }
  in
  let result, events =
    run_commands_with_backend_events ~backend ~policy [ main_command ]
  in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (List.rev !spawned_commands = [ "main"; "cleanup" ]);
  assert (List.length (Run_result.close_events result) = 1);
  assert (output_chunks events = [ "main-output"; "cleanup-output" ]);
  assert (
    status_messages events
    = [
        "--> Running teardown command \"cleanup\"";
        "--> Teardown command \"cleanup\" exited with code 1";
      ])

let test_posix_runner_cleans_teardown_descendant_pipes () =
  let teardown_command =
    ok (Command.create ~index:1 ~raw:true "sleep 10 &")
  in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let started_at = Unix.gettimeofday () in
  let result, events = run_with_events ~policy [ "true" ] in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  (* Teardown cleanup should be materially faster than the orphaned sleep's
     natural lifetime even when shell/process-group teardown is slow. *)
  assert (elapsed < 6.0);
  assert (Run_result.exit_code result = 0);
  assert (
    status_messages events
    = [
        "--> Running teardown command \"sleep 10 &\"";
        "--> Teardown command \"sleep 10 &\" exited with code 0";
      ])

let teardown_parent_signal_statuses =
  [
    "--> Running teardown command \"cleanup\"";
    "--> Teardown command \"cleanup\" exited with code 0";
  ]

let teardown_parent_signal_policy ?kill_timeout_warning kill_timeout_ms =
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  ok
    (Run_policy.create ~kill_timeout_ms ?kill_timeout_warning
       ~teardown:[ teardown_command ] ())

let run_teardown_parent_signal_scenario ~policy ~spawn_cleanup =
  Eio_main.run (fun env ->
      let clock = Eio.Stdenv.clock env in
      let events = ref [] in
      let backend =
        {
          Runner_backend.spawn =
            (fun ~sw ~command ->
              match Command.text command with
              | "main" ->
                  backend_process ~await:(fun () -> Close_event.Exited 0) ()
              | "cleanup" -> spawn_cleanup ~clock ~sw
              | _ -> assert false);
        }
      in
      let spec = ok (Run_spec.create ~commands:[ command 0 "main" ] ~policy) in
      let result =
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun event -> events := event :: !events)
      in
      (result, List.rev !events))

let send_parent_signal_after ~clock ~sw delay =
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock delay;
      Unix.kill (Unix.getpid ()) Sys.sigterm)

let wait_until ~clock ~failure_message condition =
  let deadline = Eio.Time.now clock +. 0.4 in
  while (not (condition ())) && Eio.Time.now clock < deadline do
    Eio.Time.sleep clock 0.01
  done;
  if not (condition ()) then failwith failure_message

let require_timestamp = function
  | Some timestamp -> timestamp
  | None -> assert false

let assert_teardown_parent_signal_result ?(expected_output = []) result events =
  let result = ok result in
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0);
  assert (List.length (Run_result.close_events result) = 1);
  assert (output_chunks events = expected_output);
  assert (status_messages events = teardown_parent_signal_statuses)

let test_runner_serializes_replayed_parent_signals_during_teardown () =
  let policy = teardown_parent_signal_policy 0 in
  let teardown_signals = ref [] in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw:_ ->
        Unix.kill (Unix.getpid ()) Sys.sigterm;
        backend_process
          ~signal:(fun signal ->
            if signal = Sys.sigterm then Unix.kill (Unix.getpid ()) Sys.sighup;
            teardown_signals := signal :: !teardown_signals;
            Ok true)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:
                "timed out waiting for reentrant teardown signal"
              (fun () -> List.mem Sys.sighup !teardown_signals);
            Close_event.Exited 0)
          ())
  in
  assert (List.rev !teardown_signals = [ Sys.sigterm; Sys.sighup ]);
  assert_teardown_parent_signal_result result events

let test_runner_does_not_replay_stale_parent_signal_to_teardown () =
  let main_command = command 0 "main" in
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let teardown_signaled = ref None in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.text command with
                | "main" ->
                    backend_process
                      ~await:(fun () ->
                        Unix.kill (Unix.getpid ()) Sys.sigterm;
                        Eio.Time.sleep clock 0.05;
                        Close_event.Exited 0)
                      ()
                | "cleanup" ->
                    backend_process
                      ~signal:(fun signal ->
                        teardown_signaled := Some signal;
                        Ok true)
                      ~await:(fun () -> Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands:[ main_command ] ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  assert (!teardown_signaled = None);
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0)

let test_runner_forwards_parent_signal_during_teardown_spawn_race () =
  let policy = teardown_parent_signal_policy 0 in
  let teardown_signaled = ref None in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw:_ ->
        Unix.kill (Unix.getpid ()) Sys.sigterm;
        backend_process
          ~signal:(fun signal ->
            teardown_signaled := Some signal;
            Ok true)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for replayed teardown signal"
              (fun () -> Option.is_some !teardown_signaled);
            Close_event.Exited 0)
          ())
  in
  assert (!teardown_signaled = Some Sys.sigterm);
  assert_teardown_parent_signal_result result events

let run_teardown_close_stdin_signal_race ~teardown_index ~signal_result =
  let teardown_command =
    ok (Command.create ~index:teardown_index ~raw:true "cleanup")
  in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let teardown_signals = ref [] in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw:_ ->
        backend_process
          ~close_stdin:(fun () -> Unix.kill (Unix.getpid ()) Sys.sigterm)
          ~signal:(fun signal ->
            teardown_signals := signal :: !teardown_signals;
            signal_result signal)
          ~await:(fun () ->
            Eio.Time.sleep clock 0.05;
            Close_event.Exited 0)
          ())
  in
  let result = ok result in
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0);
  (List.rev !teardown_signals, events)

let test_runner_does_not_double_signal_teardown_during_spawn_race () =
  let teardown_signals, _events =
    run_teardown_close_stdin_signal_race ~teardown_index:1
      ~signal_result:(fun _ -> Ok true)
  in
  assert (teardown_signals = [ Sys.sigterm ])

let test_runner_does_not_retry_failed_teardown_signal_during_spawn_race () =
  let teardown_signals, events =
    run_teardown_close_stdin_signal_race ~teardown_index:1
      ~signal_result:(fun signal ->
        if signal = Sys.sigterm then Error "signal failed" else Ok true)
  in
  assert (teardown_signals = [ Sys.sigterm; Sys.sigkill ]);
  assert (
    output_chunks events
    = [ "teardown command failed to signal: signal failed" ])

let test_runner_does_not_retry_ignored_teardown_signal_during_spawn_race () =
  let teardown_signals, events =
    run_teardown_close_stdin_signal_race ~teardown_index:1
      ~signal_result:(fun _ -> Ok false)
  in
  assert (teardown_signals = [ Sys.sigterm ]);
  assert (output_chunks events = [])

let test_runner_replays_latest_parent_signal_to_teardown_spawn_race () =
  let main_command = command 0 "main" in
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let teardown_signaled = ref None in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                match Command.text command with
                | "main" ->
                    backend_process
                      ~await:(fun () ->
                        Unix.kill (Unix.getpid ()) Sys.sigint;
                        Eio.Time.sleep clock 0.05;
                        Close_event.Exited 0)
                      ()
                | "cleanup" ->
                    Unix.kill (Unix.getpid ()) Sys.sigterm;
                    backend_process
                      ~signal:(fun signal ->
                        teardown_signaled := Some signal;
                        Ok true)
                      ~await:(fun () ->
                        let deadline = Eio.Time.now clock +. 0.4 in
                        while
                          Option.is_none !teardown_signaled
                          && Eio.Time.now clock < deadline
                        do
                          Eio.Time.sleep clock 0.01
                        done;
                        Close_event.Exited 0)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands:[ main_command ] ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  assert (!teardown_signaled = Some Sys.sigterm);
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0)

let test_runner_does_not_double_signal_index_zero_teardown_during_spawn_race () =
  let teardown_signals, _events =
    run_teardown_close_stdin_signal_race ~teardown_index:0
      ~signal_result:(fun _ -> Ok true)
  in
  assert (teardown_signals = [ Sys.sigterm ])

let test_runner_executes_teardown_after_empty_expansion () =
  let teardown_command = ok (Command.create ~index:0 ~raw:true "cleanup") in
  let policy =
    ok
      (Run_policy.create ~success_condition:Run_policy.NoCommands
         ~teardown:[ teardown_command ] ())
  in
  let spawned_commands = ref [] in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          spawned_commands := Command.text command :: !spawned_commands;
          backend_process
            ~stdout:(Eio.Flow.string_source "cleanup-output")
            ~await:(fun () -> Close_event.Exited 0)
            ());
    }
  in
  let result, events =
    Eio_main.run (fun env ->
        let spec = ok (Run_spec.create_empty ~policy) in
        let events = ref [] in
        let result =
          Runner.run ~input:None ~input_source:None ~backend
            ~now:(fun () -> Eio.Time.now (Eio.Stdenv.clock env))
            ~sleep:(fun seconds ->
              Eio.Time.sleep (Eio.Stdenv.clock env) seconds)
            ~spec
            ~on_output_event:(fun event -> events := event :: !events)
        in
        (result, List.rev !events))
  in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (List.rev !spawned_commands = [ "cleanup" ]);
  assert (Run_result.close_events result = []);
  assert (output_chunks events = [ "cleanup-output" ]);
  assert (
    status_messages events
    = [
        "--> Running teardown command \"cleanup\"";
        "--> Teardown command \"cleanup\" exited with code 0";
      ])

let test_runner_reports_teardown_spawn_failure_without_affecting_exit_code () =
  let main_command = command 0 "main" in
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          match Command.text command with
          | "main" ->
              backend_process
                ~stdout:(Eio.Flow.string_source "main-output\n")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | "cleanup" -> failwith "cleanup spawn boom"
          | _ -> assert false);
    }
  in
  let result, events =
    run_commands_with_backend_events ~backend ~policy [ main_command ]
  in
  let result = ok result in
  let expected_error =
    "teardown command failed to spawn: "
    ^ Printexc.to_string (Failure "cleanup spawn boom")
  in
  assert (Run_result.exit_code result = 0);
  assert (List.length (Run_result.close_events result) = 1);
  assert (output_chunks events = [ "main-output"; expected_error ]);
  assert (
    status_messages events = [ "--> Running teardown command \"cleanup\"" ])

let test_runner_reports_teardown_close_stdin_failures_without_affecting_exit_code
    () =
  let main_command = command 0 "main" in
  let first_teardown = ok (Command.create ~index:1 ~raw:true "cleanup-1") in
  let second_teardown = ok (Command.create ~index:2 ~raw:true "cleanup-2") in
  let policy =
    ok (Run_policy.create ~teardown:[ first_teardown; second_teardown ] ())
  in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          match Command.text command with
          | "main" ->
              backend_process
                ~stdout:(Eio.Flow.string_source "main-output\n")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | "cleanup-1" ->
              backend_process
                ~close_stdin:(fun () -> failwith "cleanup-1 stdin boom")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | "cleanup-2" ->
              backend_process
                ~close_stdin:(fun () -> failwith "cleanup-2 stdin boom")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | _ -> assert false);
    }
  in
  let result, events =
    run_commands_with_backend_events ~backend ~policy [ main_command ]
  in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (List.length (Run_result.close_events result) = 1);
  assert (
    output_chunks events
    = [
        "main-output";
        "teardown command failed to close stdin: Failure(\"cleanup-1 stdin \
         boom\")";
        "teardown command failed to close stdin: Failure(\"cleanup-2 stdin \
         boom\")";
      ]);
  assert (
    status_messages events
    = [
        "--> Running teardown command \"cleanup-1\"";
        "--> Teardown command \"cleanup-1\" exited with code 0";
        "--> Running teardown command \"cleanup-2\"";
        "--> Teardown command \"cleanup-2\" exited with code 0";
      ])

let test_runner_reports_teardown_output_reader_failure () =
  let main_command = command 0 "main" in
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let signaled = ref None in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          match Command.text command with
          | "main" ->
              backend_process
                ~stdout:(Eio.Flow.string_source "main-output\n")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | "cleanup" ->
              backend_process
                ~stdout:(failing_source ())
                ~signal:(fun signal ->
                  signaled := Some signal;
                  Ok true)
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | _ -> assert false);
    }
  in
  let result, events =
    run_commands_with_backend_events ~backend ~policy [ main_command ]
  in
  let result = ok result in
  let expected_error =
    "teardown command output read failed: Failure(\"reader boom\")"
  in
  assert (!signaled = Some Sys.sigkill);
  assert (Run_result.exit_code result = 0);
  assert (List.length (Run_result.close_events result) = 1);
  assert (output_chunks events = [ "main-output"; expected_error ]);
  assert (
    status_messages events = [ "--> Running teardown command \"cleanup\"" ]);;

let test_runner_reports_teardown_await_failure () =
  let main_command = command 0 "main" in
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let cleanup_called = ref false in
  let signaled = ref None in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          match Command.text command with
          | "main" ->
              backend_process
                ~stdout:(Eio.Flow.string_source "main-output\n")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | "cleanup" ->
              backend_process
                ~signal:(fun signal ->
                  signaled := Some signal;
                  Ok true)
                ~cleanup_after_exit:(fun () -> cleanup_called := true)
                ~await:(fun () -> failwith "cleanup await boom")
                ()
          | _ -> assert false);
    }
  in
  let result, events =
    run_commands_with_backend_events ~backend ~policy [ main_command ]
  in
  let result = ok result in
  let expected_error =
    "teardown command failed to await: Failure(\"cleanup await boom\")"
  in
  assert (!signaled = Some Sys.sigkill);
  assert !cleanup_called;
  assert (Run_result.exit_code result = 0);
  assert (List.length (Run_result.close_events result) = 1);
  assert (output_chunks events = [ "main-output"; expected_error ]);
  assert (
    status_messages events = [ "--> Running teardown command \"cleanup\"" ]);;

let test_runner_reports_teardown_cleanup_failure_without_affecting_exit_code ()
    =
  let main_command = command 0 "main" in
  let teardown_command = ok (Command.create ~index:1 ~raw:true "cleanup") in
  let policy = ok (Run_policy.create ~teardown:[ teardown_command ] ()) in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          match Command.text command with
          | "main" ->
              backend_process
                ~stdout:(Eio.Flow.string_source "main-output\n")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | "cleanup" ->
              backend_process
                ~cleanup_after_exit:(fun () -> failwith "cleanup boom")
                ~await:(fun () -> Close_event.Exited 0)
                ()
          | _ -> assert false);
    }
  in
  let result, events =
    run_commands_with_backend_events ~backend ~policy [ main_command ]
  in
  let result = ok result in
  let expected_error =
    "teardown command cleanup failed: Failure(\"cleanup boom\")"
  in
  assert (Run_result.exit_code result = 0);
  assert (List.length (Run_result.close_events result) = 1);
  assert (output_chunks events = [ "main-output"; expected_error ]);
  assert (
    status_messages events
    = [
        "--> Running teardown command \"cleanup\"";
        "--> Teardown command \"cleanup\" exited with code 0";
      ])

let test_runner_keeps_teardown_registered_while_draining_readers_after_await_failure
    () =
  let policy = teardown_parent_signal_policy 0 in
  let teardown_signals = ref [] in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw ->
        Eio.Fiber.fork ~sw (fun () ->
            Eio.Time.sleep clock 0.05;
            Unix.kill (Unix.getpid ()) Sys.sigterm);
        backend_process
          ~stdout:
            (await_signal_source ~wait_for_signal:(fun () ->
                 wait_until ~clock
                   ~failure_message:
                     "timed out waiting for forwarded teardown signal"
                   (fun () -> List.mem Sys.sigterm !teardown_signals)))
          ~signal:(fun signal ->
            teardown_signals := signal :: !teardown_signals;
            Ok true)
          ~await:(fun () -> failwith "cleanup await boom")
          ())
  in
  let result = ok result in
  let expected_error =
    "teardown command failed to await: Failure(\"cleanup await boom\")"
  in
  assert (List.rev !teardown_signals = [ Sys.sigkill; Sys.sigterm ]);
  assert (Run_result.interrupted result);
  assert (Run_result.exit_code result = 0);
  assert (List.length (Run_result.close_events result) = 1);
  assert (output_chunks events = [ expected_error ]);
  assert (
    status_messages events = [ "--> Running teardown command \"cleanup\"" ]);;

let test_runner_reports_parent_signal_failure_during_teardown_without_affecting_exit_code () =
  let policy = teardown_parent_signal_policy 0 in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw:_ ->
        backend_process
          ~signal:(fun _ -> Error "signal failed")
          ~await:(fun () ->
            Unix.kill (Unix.getpid ()) Sys.sigterm;
            Eio.Time.sleep clock 0.05;
            Close_event.Exited 0)
          ())
  in
  let expected_error = "teardown command failed to signal: signal failed" in
  assert_teardown_parent_signal_result ~expected_output:[ expected_error ]
    result events

let test_runner_preserves_multiple_teardown_parent_signal_failures () =
  let policy = teardown_parent_signal_policy 0 in
  let sent_signals = ref [] in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw ->
        Eio.Fiber.fork ~sw (fun () ->
            Eio.Time.sleep clock 0.02;
            Unix.kill (Unix.getpid ()) Sys.sigterm;
            Unix.kill (Unix.getpid ()) Sys.sighup);
        backend_process
          ~signal:(fun signal ->
            sent_signals := signal :: !sent_signals;
            if signal = Sys.sigkill then Ok true
            else if signal = Sys.sigterm then Error "SIGTERM failed"
            else if signal = Sys.sighup then Error "SIGHUP failed"
            else assert false)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for both parent signals"
              (fun () ->
                List.mem Sys.sigterm !sent_signals
                && List.mem Sys.sighup !sent_signals);
            Close_event.Exited 0)
          ())
  in
  assert (List.mem Sys.sigkill !sent_signals);
  assert_teardown_parent_signal_result
    ~expected_output:
      [
        "teardown command failed to signal: SIGTERM failed";
        "teardown command failed to signal: SIGHUP failed";
      ]
    result events

let test_runner_force_kills_teardown_after_parent_signal_failure_timeout () =
  let policy = teardown_parent_signal_policy 50 in
  let sent_signals = ref [] in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw ->
        let forced_kill_seen = ref false in
        send_parent_signal_after ~clock ~sw 0.05;
        backend_process
          ~signal:(fun signal ->
            sent_signals := signal :: !sent_signals;
            if signal = Sys.sigkill then (
              forced_kill_seen := true;
              Ok true)
            else Error "signal failed")
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for forced teardown kill"
              (fun () -> !forced_kill_seen);
            Close_event.Exited 0)
          ())
  in
  let expected_error = "teardown command failed to signal: signal failed" in
  assert (List.rev !sent_signals = [ Sys.sigterm; Sys.sigkill ]);
  assert_teardown_parent_signal_result ~expected_output:[ expected_error ]
    result events

let test_runner_force_kills_teardown_after_parent_signal_timeout () =
  let policy = teardown_parent_signal_policy 50 in
  let sent_signals = ref [] in
  let sigterm_sent_at = ref None in
  let sigkill_sent_at = ref None in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw ->
        let forced_kill_seen = ref false in
        send_parent_signal_after ~clock ~sw 0.05;
        backend_process
          ~signal:(fun signal ->
            let timestamp = Eio.Time.now clock in
            sent_signals := signal :: !sent_signals;
            if signal = Sys.sigterm then sigterm_sent_at := Some timestamp
            else if signal = Sys.sigkill then (
              sigkill_sent_at := Some timestamp;
              forced_kill_seen := true);
            Ok true)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for forced teardown kill"
              (fun () -> !forced_kill_seen);
            Close_event.Exited 0)
          ())
  in
  let sigterm_sent_at = require_timestamp !sigterm_sent_at in
  let sigkill_sent_at = require_timestamp !sigkill_sent_at in
  assert (List.rev !sent_signals = [ Sys.sigterm; Sys.sigkill ]);
  assert (sigkill_sent_at -. sigterm_sent_at >= 0.04);
  assert_teardown_parent_signal_result result events

let test_runner_does_not_force_kill_teardown_when_parent_signal_timeout_zero ()
    =
  let policy = teardown_parent_signal_policy 0 in
  let sent_signals = ref [] in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw ->
        send_parent_signal_after ~clock ~sw 0.02;
        backend_process
          ~signal:(fun signal ->
            sent_signals := signal :: !sent_signals;
            Ok true)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for forwarded teardown signal"
              (fun () -> List.mem Sys.sigterm !sent_signals);
            Eio.Time.sleep clock 0.08;
            Close_event.Exited 0)
          ())
  in
  assert (List.rev !sent_signals = [ Sys.sigterm ]);
  assert_teardown_parent_signal_result result events

let test_runner_force_kills_replayed_parent_signal_after_teardown_spawn_race_timeout
    () =
  let policy = teardown_parent_signal_policy 50 in
  let sent_signals = ref [] in
  let sigterm_sent_at = ref None in
  let sigkill_sent_at = ref None in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw:_ ->
        let forced_kill_seen = ref false in
        (* Raise the parent signal before [spawn] returns. The runner cannot
           register the teardown process until after this call returns, so
           SIGTERM delivery has to come from the replay path. *)
        Unix.kill (Unix.getpid ()) Sys.sigterm;
        backend_process
          ~signal:(fun signal ->
            let timestamp = Eio.Time.now clock in
            sent_signals := signal :: !sent_signals;
            if signal = Sys.sigterm then sigterm_sent_at := Some timestamp
            else if signal = Sys.sigkill then (
              sigkill_sent_at := Some timestamp;
              forced_kill_seen := true);
            Ok true)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for forced teardown kill"
              (fun () -> !forced_kill_seen);
            Close_event.Exited 0)
          ())
  in
  let sigterm_sent_at = require_timestamp !sigterm_sent_at in
  let sigkill_sent_at = require_timestamp !sigkill_sent_at in
  assert (List.rev !sent_signals = [ Sys.sigterm; Sys.sigkill ]);
  assert (sigkill_sent_at -. sigterm_sent_at >= 0.04);
  assert_teardown_parent_signal_result result events

let test_runner_force_kills_teardown_after_negative_parent_signal_timeout () =
  let warning = Run_policy.Timeout_negative "-1" in
  let policy =
    teardown_parent_signal_policy ~kill_timeout_warning:warning (-1)
  in
  let sent_signals = ref [] in
  let sigterm_sent_at = ref None in
  let sigkill_sent_at = ref None in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw ->
        send_parent_signal_after ~clock ~sw 0.02;
        backend_process
          ~signal:(fun signal ->
            let timestamp = Eio.Time.now clock in
            sent_signals := signal :: !sent_signals;
            if signal = Sys.sigterm then sigterm_sent_at := Some timestamp
            else if signal = Sys.sigkill then sigkill_sent_at := Some timestamp;
            Ok true)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for forced teardown kill"
              (fun () -> List.mem Sys.sigkill !sent_signals);
            Close_event.Exited 0)
          ())
  in
  let sigterm_sent_at = require_timestamp !sigterm_sent_at in
  let sigkill_sent_at = require_timestamp !sigkill_sent_at in
  let expected_warning =
    Printf.sprintf
      "(node:%d) TimeoutNegativeWarning: -1 is a negative number.\n\
       Timeout duration was set to 1.\n\
       (Use `node --trace-warnings ...` to show where the warning was created)\n"
      (Unix.getpid ())
  in
  assert (List.rev !sent_signals = [ Sys.sigterm; Sys.sigkill ]);
  assert (sigkill_sent_at -. sigterm_sent_at >= 0.0005);
  assert (sigkill_sent_at -. sigterm_sent_at < 0.04);
  assert (runtime_warnings events = [ expected_warning ]);
  assert_teardown_parent_signal_result result events

let test_runner_waits_kill_timeout_before_teardown_cleanup_after_parent_signal_exit
    () =
  let policy = teardown_parent_signal_policy 50 in
  let sent_signals = ref [] in
  let sigterm_sent_at = ref None in
  let sigkill_sent_at = ref None in
  let cleanup_called_at = ref None in
  let cleanup_needed = ref true in
  let result, events =
    run_teardown_parent_signal_scenario ~policy
      ~spawn_cleanup:(fun ~clock ~sw ->
        send_parent_signal_after ~clock ~sw 0.02;
        backend_process
          ~signal:(fun signal ->
            let timestamp = Eio.Time.now clock in
            sent_signals := signal :: !sent_signals;
            if signal = Sys.sigterm then sigterm_sent_at := Some timestamp
            else if signal = Sys.sigkill then sigkill_sent_at := Some timestamp;
            Ok true)
          ~needs_cleanup_after_exit:(fun () -> !cleanup_needed)
          ~cleanup_after_exit:(fun () ->
            cleanup_called_at := Some (Eio.Time.now clock);
            cleanup_needed := false)
          ~await:(fun () ->
            wait_until ~clock
              ~failure_message:"timed out waiting for forwarded teardown signal"
              (fun () -> List.mem Sys.sigterm !sent_signals);
            Close_event.Exited 0)
          ())
  in
  let sigterm_sent_at = require_timestamp !sigterm_sent_at in
  let sigkill_sent_at = require_timestamp !sigkill_sent_at in
  let cleanup_called_at = require_timestamp !cleanup_called_at in
  assert (List.rev !sent_signals = [ Sys.sigterm; Sys.sigkill ]);
  assert (sigkill_sent_at -. sigterm_sent_at >= 0.04);
  assert (cleanup_called_at >= sigkill_sent_at);
  assert (cleanup_called_at -. sigterm_sent_at >= 0.04);
  assert_teardown_parent_signal_result result events

let run_lifecycle_and_signal_races () =
  test_runner_executes_teardown_without_affecting_exit_code ();
  test_posix_runner_cleans_teardown_descendant_pipes ();
  test_runner_serializes_replayed_parent_signals_during_teardown ();
  test_runner_does_not_replay_stale_parent_signal_to_teardown ();
  test_runner_forwards_parent_signal_during_teardown_spawn_race ();
  test_runner_does_not_double_signal_teardown_during_spawn_race ();
  test_runner_does_not_retry_failed_teardown_signal_during_spawn_race ();
  test_runner_does_not_retry_ignored_teardown_signal_during_spawn_race ();
  test_runner_replays_latest_parent_signal_to_teardown_spawn_race ();
  test_runner_does_not_double_signal_index_zero_teardown_during_spawn_race ();
  test_runner_executes_teardown_after_empty_expansion ()

let run_failure_paths () =
  test_runner_reports_teardown_spawn_failure_without_affecting_exit_code ();
  test_runner_reports_teardown_close_stdin_failures_without_affecting_exit_code
    ();
  test_runner_reports_teardown_output_reader_failure ();
  test_runner_reports_teardown_await_failure ();
  test_runner_reports_teardown_cleanup_failure_without_affecting_exit_code ();
  test_runner_keeps_teardown_registered_while_draining_readers_after_await_failure
    ();
  test_runner_reports_parent_signal_failure_during_teardown_without_affecting_exit_code
    ();
  test_runner_preserves_multiple_teardown_parent_signal_failures ();
  test_runner_force_kills_teardown_after_parent_signal_failure_timeout ();
  test_runner_force_kills_teardown_after_parent_signal_timeout ();
  test_runner_does_not_force_kill_teardown_when_parent_signal_timeout_zero ();
  test_runner_force_kills_replayed_parent_signal_after_teardown_spawn_race_timeout
    ();
  test_runner_force_kills_teardown_after_negative_parent_signal_timeout ();
  test_runner_waits_kill_timeout_before_teardown_cleanup_after_parent_signal_exit
    ()
