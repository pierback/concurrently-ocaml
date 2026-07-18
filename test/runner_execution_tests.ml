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

let test_runner_executes_commands_concurrently () =
  let policy = Run_policy.default in
  let first_marker = Filename.temp_file "concurrently-first" ".state" in
  let second_marker = Filename.temp_file "concurrently-second" ".state" in
  Sys.remove first_marker;
  Sys.remove second_marker;
  let waits_for marker_to_write marker_to_wait output =
    Printf.sprintf
      "printf ready > %s; i=0; while [ \"$i\" -lt 200 ]; do if [ -f %s ]; then \
       printf %s; exit 0; fi; i=$((i + 1)); sleep 0.01; done; exit 42"
      (Filename.quote marker_to_write)
      (Filename.quote marker_to_wait)
      (Filename.quote output)
  in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists first_marker then Sys.remove first_marker;
      if Sys.file_exists second_marker then Sys.remove second_marker)
    (fun () ->
      let result, events =
        run_with_events ~policy
          [
            waits_for first_marker second_marker "one";
            waits_for second_marker first_marker "two";
          ]
      in
      let result = ok result in
      assert (Run_result.exit_code result = 0);
      let chunks = output_chunks events in
      assert (List.mem "one" chunks);
      assert (List.mem "two" chunks))

let test_runner_preserves_blank_output_lines () =
  let policy = Run_policy.default in
  let result, events = run_with_events ~policy [ "printf 'a\\n\\nb\\n'" ] in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (output_chunks events = [ "a"; ""; "b" ])

let test_runner_preserves_raw_output_bytes () =
  let policy = Run_policy.default in
  let command =
    ok (Command.create ~index:0 ~raw:true "printf 'a'; printf '\\n'; printf 'b'")
  in
  let result, events = run_commands_with_events ~policy [ command ] in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (String.concat "" (output_chunks events) = "a\nb")

let test_runner_applies_command_environment () =
  let policy = Run_policy.default in
  let command =
    ok
      (Command.create ~index:0
         ~env:[ ("CONCURRENTLY_TEST_VALUE", "from-env") ]
         "printf \"$CONCURRENTLY_TEST_VALUE\"")
  in
  let result, events = run_commands_with_events ~policy [ command ] in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (output_chunks events = [ "from-env" ])

let test_runner_applies_command_cwd () =
  let policy = Run_policy.default in
  let directory = Filename.temp_file "concurrently-cwd" ".dir" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let marker = Filename.concat directory "marker" in
  let command =
    ok (Command.create ~index:0 ~cwd:directory "printf from-cwd > marker")
  in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists marker then Sys.remove marker;
      if Sys.file_exists directory then Unix.rmdir directory)
    (fun () ->
      let result, _events = run_commands_with_events ~policy [ command ] in
      let result = ok result in
      assert (Run_result.exit_code result = 0);
      let input = open_in marker in
      Fun.protect
        ~finally:(fun () -> close_in input)
        (fun () -> assert (input_line input = "from-cwd")))

let test_runner_drains_oversized_output_lines () =
  let policy = Run_policy.default in
  let result, events =
    run_with_events ~policy
      [
        "awk 'BEGIN { for (i = 0; i < 2000000; i++) printf \"x\"; printf \
         \"\\n\" }'";
      ]
  in
  let result = ok result in
  let chunks = output_chunks events in
  assert (Run_result.exit_code result = 0);
  assert (List.length chunks > 1);
  assert (
    chunks
    |> List.fold_left (fun total chunk -> total + String.length chunk) 0
    = 2_000_000)

let test_runner_respects_max_processes () =
  let policy = ok (Run_policy.create ~max_processes:1 ()) in
  let started_at = Unix.gettimeofday () in
  let result, _events =
    run_with_events ~policy [ "sleep 0.2; printf one"; "sleep 0.2; printf two" ]
  in
  let elapsed = Unix.gettimeofday () -. started_at in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (elapsed >= 0.35)

let test_runner_retries_failed_commands () =
  let marker = Filename.temp_file "concurrently-retry" ".state" in
  Sys.remove marker;
  let policy = ok (Run_policy.create ~restart_tries:1 ()) in
  let command =
    Printf.sprintf
      "if [ ! -f %s ]; then touch %s; exit 1; else printf retry-ok; fi"
      (Filename.quote marker) (Filename.quote marker)
  in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists marker then Sys.remove marker)
    (fun () ->
      let result, events = run_with_events ~policy [ command ] in
      let result = ok result in
      let close_events = Run_result.close_events result in
      assert (Run_result.exit_code result = 0);
      assert (List.length close_events = 2);
      assert (List.mem "retry-ok" (output_chunks events));
      assert (
        List.exists
          (fun close_event ->
            Close_event.attempt close_event = 0
            && Close_event.status close_event = Close_event.Exited 1)
          close_events);
      assert (
        List.exists
          (fun close_event ->
            Close_event.attempt close_event = 1
            && Close_event.status close_event = Close_event.Exited 0)
          close_events))

let test_runner_infinite_restart_keeps_result_bounded () =
  let marker = Filename.temp_file "concurrently-infinite-retry" ".state" in
  Sys.remove marker;
  let policy = ok (Run_policy.create ~restart_tries:(-1) ()) in
  let command =
    Printf.sprintf
      "if [ ! -f %s ]; then touch %s; exit 1; else printf retry-ok; fi"
      (Filename.quote marker) (Filename.quote marker)
  in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists marker then Sys.remove marker)
    (fun () ->
      let result, events = run_with_events ~policy [ command ] in
      let result = ok result in
      let close_events = Run_result.close_events result in
      assert (Run_result.exit_code result = 0);
      assert (List.length close_events = 1);
      assert (List.mem "retry-ok" (output_chunks events));
      match close_events with
      | [ close_event ] ->
          assert (Close_event.attempt close_event = 1);
          assert (Close_event.status close_event = Close_event.Exited 0)
      | _ -> assert false)

let test_runner_applies_restart_delay () =
  let policy =
    ok
      (Run_policy.create ~restart_tries:2
         ~restart_delay:Run_policy.Exponential_backoff ())
  in
  let command = command 0 "flaky" in
  let spawn_count = ref 0 in
  let slept_seconds = ref [] in
  let now_seconds = ref 0.0 in
  let backend =
    {
      Runner_backend.spawn =
        (fun ~sw:_ ~command:_ ->
          incr spawn_count;
          let status =
            if !spawn_count = 1 then Close_event.Exited 1
            else Close_event.Exited 0
          in
          backend_process ~await:(fun () -> status) ());
    }
  in
  let result, events =
    Eio_main.run (fun env ->
        let spec = ok (Run_spec.create ~commands:[ command ] ~policy) in
        let events = ref [] in
        let result =
          Runner.run ~input:None ~input_source:None ~backend
            ~now:(fun () -> !now_seconds)
            ~sleep:(fun seconds ->
              slept_seconds := seconds :: !slept_seconds;
              now_seconds := !now_seconds +. seconds)
            ~spec
            ~on_output_event:(fun event -> events := event :: !events)
        in
        (result, List.rev !events))
  in
  let result = ok result in
  assert (!spawn_count = 2);
  assert (abs_float (List.fold_left ( +. ) 0.0 !slept_seconds -. 1.0) < 0.0001);
  assert (Run_result.exit_code result = 0);
  assert (
    List.exists
      (fun event ->
        match Output_event.payload event with
        | Output_event.Lifecycle_payload
            (Output_event.Restarting { next_attempt = 1; delay_ms = Some 1000 })
          ->
            true
        | _ -> false)
      events)

let test_runner_holds_process_slot_until_restart_exhaustion () =
  let policy =
    ok
      (Run_policy.create ~max_processes:1 ~restart_tries:1
         ~restart_delay:(Run_policy.Fixed_delay_ms 1000) ())
  in
  let commands = [ command 0 "flaky"; command 1 "queued" ] in
  let spawn_order = ref [] in
  let first_command_spawns = ref 0 in
  let now_seconds = ref 0.0 in
  let result =
    Eio_main.run (fun env ->
        let saw_queued_command = ref false in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                let command_index = Command.index command in
                spawn_order := command_index :: !spawn_order;
                let status =
                  match command_index with
                  | 0 ->
                      incr first_command_spawns;
                      if !first_command_spawns = 1 then Close_event.Exited 1
                      else Close_event.Exited 0
                  | 1 ->
                      saw_queued_command := true;
                      Close_event.Exited 0
                  | _ -> assert false
                in
                backend_process ~await:(fun () -> status) ());
          }
        in
        let sleep seconds =
          assert (seconds > 0.0);
          assert (seconds <= 0.05);
          assert (not !saw_queued_command);
          now_seconds := !now_seconds +. seconds
        in
        let spec = ok (Run_spec.create ~commands ~policy) in
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> !now_seconds)
          ~sleep ~spec
          ~on_output_event:(fun _event -> ()))
  in
  let result = ok result in
  assert (Run_result.exit_code result = 0);
  assert (List.rev !spawn_order = [ 0; 0; 1 ])

let test_runner_keeps_retry_delay_after_sibling_success () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ] ~restart_tries:1
         ~restart_delay:(Run_policy.Fixed_delay_ms 50) ())
  in
  let commands = [ command 0 "retrying"; command 1 "successful" ] in
  let started_at = Unix.gettimeofday () in
  let spawn_order = ref [] in
  let result =
    Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let backend =
          {
            Runner_backend.spawn =
              (fun ~sw:_ ~command ->
                spawn_order := Command.index command :: !spawn_order;
                let status =
                  match Command.index command with
                  | 0 -> Close_event.Exited 1
                  | 1 ->
                      Eio.Time.sleep clock 0.01;
                      Close_event.Exited 0
                  | _ -> assert false
                in
                backend_process ~await:(fun () -> status) ());
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
  assert (elapsed >= 0.04);
  assert (Run_result.exit_code result = 1);
  assert (List.rev !spawn_order = [ 0; 1; 0 ]);
  assert (
    Run_result.close_events result
    |> List.for_all (fun close_event ->
        Command.index (Close_event.command close_event) <> 0
        || not (Close_event.killed close_event)))

let test_runner_uses_npm_shell_invocation_for_dash_prefixed_commands () =
  let result, _events = run_with_events ~policy:Run_policy.default [ "-foo" ] in
  let result = ok result in
  let close_event =
    match Run_result.close_events result with
    | [ close_event ] -> close_event
    | _ -> assert false
  in
  assert (Run_result.exit_code result = 1);
  assert (Close_event.status close_event = Close_event.Exited 2)

let run_execution_and_restart_contracts () =
  test_runner_executes_commands_concurrently ();
  test_runner_preserves_blank_output_lines ();
  test_runner_preserves_raw_output_bytes ();
  test_runner_applies_command_environment ();
  test_runner_applies_command_cwd ();
  test_runner_drains_oversized_output_lines ();
  test_runner_respects_max_processes ();
  test_runner_retries_failed_commands ();
  test_runner_infinite_restart_keeps_result_bounded ();
  test_runner_applies_restart_delay ();
  test_runner_holds_process_slot_until_restart_exhaustion ();
  test_runner_keeps_retry_delay_after_sibling_success ()

let run_shell_contract () =
  test_runner_uses_npm_shell_invocation_for_dash_prefixed_commands ()
