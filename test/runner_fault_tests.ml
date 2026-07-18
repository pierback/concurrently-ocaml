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

let test_runner_uses_backend_boundary () =
  let spawned_commands = ref [] in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command ->
          spawned_commands := Command.text command :: !spawned_commands;
          backend_process
            ~stdout:
              (Eio.Flow.string_source
                 (Printf.sprintf "backend:%s\n" (Command.text command)))
            ());
    }
  in
  let commands = [ command 0 "first"; command 1 "second" ] in
  let result, events =
    run_commands_with_backend_events ~backend ~policy:Run_policy.default
      commands
  in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (List.sort String.compare !spawned_commands = [ "first"; "second" ]);
  assert (
    List.sort String.compare (output_chunks events)
    = [ "backend:first"; "backend:second" ]);
  assert (
    List.for_all
      (fun event ->
        match Output_event.payload event with
        | Output_event.Output_chunk_payload { process_id; _ } ->
            process_id = Some "test"
        | Output_event.Lifecycle_payload _
        | Output_event.Status_message_payload _
        | Output_event.Runtime_warning_payload _ ->
            true)
      events)

let test_runner_records_spawn_failure_as_close_event () =
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command:_ -> failwith "spawn boom");
    }
  in
  let result, _events =
    run_commands_with_backend_events ~backend ~policy:Run_policy.default
      [ command 0 "boom" ]
  in
  let result = ok result in
  let expected_message = Printexc.to_string (Failure "spawn boom") in
  assert (Run_result.exit_code result = 1);
  match Run_result.close_events result with
  | [ close_event ] ->
      assert (Close_event.attempt close_event = 0);
      assert (not (Close_event.killed close_event));
      assert (
        Close_event.status close_event
        = Close_event.Spawn_error expected_message)
  | _ -> assert false

let test_runner_retries_spawn_failure () =
  let spawn_count = ref 0 in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command:_ ->
          let attempt = !spawn_count in
          incr spawn_count;
          if attempt = 0 then failwith "spawn once"
          else
            backend_process
              ~stdout:(Eio.Flow.string_source "retry-output\n")
              ~await:(fun () -> Close_event.Exited 0)
              ());
    }
  in
  let policy = ok (Run_policy.create ~restart_tries:1 ()) in
  let result, events =
    run_commands_with_backend_events ~backend ~policy [ command 0 "retry" ]
  in
  let result = ok result in
  let expected_message = Printexc.to_string (Failure "spawn once") in
  let close_events = Run_result.close_events result in
  assert (!spawn_count = 2);
  assert (Run_result.exit_code result = 0);
  assert (List.length close_events = 2);
  assert (List.mem "retry-output" (output_chunks events));
  assert (
    List.exists
      (fun close_event ->
        Close_event.attempt close_event = 0
        && Close_event.status close_event
           = Close_event.Spawn_error expected_message)
      close_events);
  assert (
    List.exists
      (fun close_event ->
        Close_event.attempt close_event = 1
        && Close_event.status close_event = Close_event.Exited 0)
      close_events)

let test_runner_reports_output_reader_failure () =
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command:_ -> backend_process ~stdout:(failing_source ()) ());
    }
  in
  let result, _events =
    run_commands_with_backend_events ~backend ~policy:Run_policy.default
      [ command 0 "boom" ]
  in
  match result with
  | Error (`Unexpected_runner_error message) ->
      assert (message = "Failure(\"reader boom\")")
  | Ok _ | Error _ -> assert false

let test_runner_signals_process_when_output_emit_fails () =
  let signaled = ref false in
  let started_at = Unix.gettimeofday () in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command:_ ->
                backend_process ~stdout:(failing_source ())
                  ~signal:(fun signal ->
                    assert (signal = Sys.sigkill);
                    signaled := true;
                    Ok true)
                  ~await:(fun () ->
                    let deadline = Eio.Time.now clock +. 0.4 in
                    while (not !signaled) && Eio.Time.now clock < deadline do
                      Eio.Time.sleep clock 0.01
                    done;
                    if !signaled then Close_event.Signaled "9"
                    else Close_event.Exited 99)
                  ());
          }
        in
        let spec =
          ok
            (Run_spec.create
               ~commands:[ command 0 "chatty" ]
               ~policy:Run_policy.default)
        in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now clock)
          ~sleep:(fun seconds -> Eio.Time.sleep clock seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  assert !signaled;
  assert (elapsed < 0.2);
  match result with
  | Error (`Unexpected_runner_error message) ->
      assert (message = "Failure(\"reader boom\")")
  | Ok _ | Error _ -> assert false

let test_runner_keeps_retry_during_output_drain () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ] ~restart_tries:1
         ())
  in
  let commands = [ command 0 "retrying"; command 1 "failing" ] in
  let spawn_counts = Array.make 2 0 in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                let command_index = Command.index command in
                spawn_counts.(command_index) <- spawn_counts.(command_index) + 1;
                match command_index with
                | 0 ->
                    backend_process
                      ~stdout:
                        (slow_eof_source ~sleep:(fun () ->
                             Eio.Time.sleep clock 0.25))
                      ~await:(fun () -> Close_event.Exited 1)
                      ()
                | 1 ->
                    backend_process
                      ~await:(fun () ->
                        Eio.Time.sleep clock 0.05;
                        Close_event.Exited 1)
                      ()
                | _ -> assert false);
          }
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now (Eio.Stdenv.clock env))
          ~sleep:(fun seconds -> Eio.Time.sleep (Eio.Stdenv.clock env) seconds)
          ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  assert (spawn_counts.(0) = 2);
  assert (Run_result.exit_code result = 1);
  assert (
    Run_result.close_events result
    |> List.for_all (fun close_event ->
        Command.index (Close_event.command close_event) <> 0
        || not (Close_event.killed close_event)))

let run_backend_boundary () =
  test_runner_uses_backend_boundary ()

let run_spawn_failures () =
  test_runner_records_spawn_failure_as_close_event ();
  test_runner_retries_spawn_failure ()

let run_output_failures () =
  test_runner_reports_output_reader_failure ();
  test_runner_signals_process_when_output_emit_fails ();
  test_runner_keeps_retry_during_output_drain ()
