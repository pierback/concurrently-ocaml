module Argument_expander = Concurrentlyocaml.Argument_expander
module Command = Concurrentlyocaml.Command
module Close_event = Concurrentlyocaml.Close_event
module Input_router = Concurrentlyocaml.Input_router
module Output_event = Concurrentlyocaml.Output_event
module Output_formatter = Concurrentlyocaml.Output_formatter
module Run_api = Concurrentlyocaml.Run_api
module Run_policy = Concurrentlyocaml.Run_policy
module Run_spec = Concurrentlyocaml.Run_spec

open Domain_test_support

let test_argument_expander_replaces_passthrough_placeholders () =
  let expand =
    Argument_expander.expand
      ~additional_arguments:[ "--watch"; "client build"; "quote's" ]
  in
  assert (expand "run {1}" = "run --watch");
  assert (expand "run {2}" = "run 'client build'");
  assert (expand "run {9}" = "run ");
  assert (expand "run {@}" = "run --watch 'client build' 'quote'\\''s'");
  assert (expand "run {*}" = "run '--watch client build quote'\\''s'");
  assert (expand "run \\{1}" = "run {1}");
  assert (expand "run {0} {abc}" = "run {0} {abc}")

let test_command_validation () =
  let command =
    ok
      (Command.create ~index:0 ~name:"web" ~cwd:"/tmp"
         ~env:[ ("PORT", "3000") ]
         ~prefix_color:"blue" ~raw:true ~hidden:true ~ipc:true "npm run dev")
  in
  assert (Command.index command = 0);
  assert (Command.text command = "npm run dev");
  assert (Command.display_text command = "npm run dev");
  assert (Command.name command = Some "web");
  assert (Command.cwd command = Some "/tmp");
  assert (Command.env command = [ ("PORT", "3000") ]);
  assert (Command.prefix_color command = Some "blue");
  assert (Command.raw command);
  assert (Command.hidden command);
  assert (Command.ipc command);
  assert (Result.is_ok (Command.create ~index:0 " "));
  expect_error `Empty_command (Command.create ~index:0 "");
  let wrapper =
    ok (Command.create ~index:0 ~display_text:"npm run api" "node wrapper")
  in
  assert (Command.text wrapper = "node wrapper");
  assert (Command.display_text wrapper = "npm run api");
  assert (Result.is_ok (Command.create ~allow_empty:true ~index:0 ""));
  expect_error `Empty_cwd (Command.create ~index:0 ~cwd:" " "echo no");
  expect_error `Negative_index (Command.create ~index:(-1) "echo no")

let test_run_policy_validation () =
  expect_error `Duplicate_kill_condition
    (Run_policy.create
       ~kill_others_on:[ Run_policy.Success; Run_policy.Success ]
       ());
  expect_error `Max_processes_less_than_one
    (Run_policy.create ~max_processes:0 ());
  expect_error `Negative_restart_limit
    (Run_policy.create ~restart_limit:(Run_policy.Finite_restarts (-1)) ());
  let infinite_policy =
    ok (Run_policy.create ~restart_limit:Run_policy.Infinite_restarts ())
  in
  assert (
    Run_policy.restart_limit infinite_policy = Run_policy.Infinite_restarts);
  assert (not (Run_policy.collect_retry_close_events infinite_policy));
  assert (Result.is_ok (Run_policy.create ~kill_timeout_ms:(-1) ()));
  assert (
    Result.is_ok
      (Run_policy.create ~restart_delay:(Run_policy.Fixed_delay_ms (-1)) ()));
  expect_error `Exponential_restart_delay_overflow
    (Run_policy.create ~restart_limit:(Run_policy.Finite_restarts max_int)
       ~restart_delay:Run_policy.Exponential_backoff ());
  expect_error `Empty_signal
    (Run_policy.create ~kill_signal:(Run_policy.Named_signal " ") ());
  expect_error `Negative_success_command_index
    (Run_policy.create ~success_condition:(Run_policy.Commands [ -1 ]) ())

let test_run_policy_decisions () =
  let first_command = command 0 "echo ok" in
  let success = close_event first_command in
  let failure = close_event ~status:(Close_event.Exited 1) first_command in
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ]
         ~success_condition:Run_policy.Last ())
  in
  let retried_success = close_event ~attempt:1 first_command in
  assert (not (Run_policy.should_kill_after_close policy success));
  assert (Run_policy.should_kill_after_close policy failure);
  assert (Run_policy.run_succeeded policy [ failure; success ]);
  assert (not (Run_policy.run_succeeded policy [ success; failure ]));
  let retrying_kill_policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ]
         ~restart_limit:(Run_policy.Finite_restarts 1)
         ())
  in
  let retryable_failure =
    close_event ~attempt:0 ~status:(Close_event.Exited 1) first_command
  in
  let exhausted_failure =
    close_event ~attempt:1 ~status:(Close_event.Exited 1) first_command
  in
  assert (Run_policy.retry_remaining retrying_kill_policy ~attempt:0);
  assert (not (Run_policy.retry_remaining retrying_kill_policy ~attempt:1));
  assert (
    not
      (Run_policy.should_kill_after_close retrying_kill_policy retryable_failure));
  assert (
    Run_policy.should_kill_after_close retrying_kill_policy exhausted_failure);
  let infinite_retry_policy =
    ok (Run_policy.create ~restart_limit:Run_policy.Infinite_restarts ())
  in
  assert (Run_policy.should_retry infinite_retry_policy retryable_failure);
  assert (
    not
      (Run_policy.close_event_completes_command infinite_retry_policy
         retryable_failure));
  assert (Run_policy.close_event_completes_command infinite_retry_policy success);
  assert (not (Run_policy.collect_retry_close_events infinite_retry_policy));
  let cancelled_failure =
    close_event ~attempt:1 ~killed:true ~status:(Close_event.Signaled "15")
      first_command
  in
  assert (
    not
      (Run_policy.should_kill_after_close retrying_kill_policy cancelled_failure));
  assert (
    Run_policy.run_succeeded Run_policy.default [ retried_success; failure ]);
  assert (Run_policy.run_succeeded Run_policy.default [ failure; success ]);
  let first_policy =
    ok (Run_policy.create ~success_condition:Run_policy.First ())
  in
  let last_policy =
    ok (Run_policy.create ~success_condition:Run_policy.Last ())
  in
  let slow_success =
    close_event ~started_at:10.0 ~ended_at:30.0 first_command
  in
  let second_command = command 1 "echo later" in
  let fast_failure =
    close_event ~status:(Close_event.Exited 1) ~started_at:10.0 ~ended_at:20.0
      second_command
  in
  assert (
    not (Run_policy.run_succeeded first_policy [ slow_success; fast_failure ]));
  assert (Run_policy.run_succeeded last_policy [ slow_success; fast_failure ]);
  let first_command_policy =
    ok (Run_policy.create ~success_condition:(Run_policy.Commands [ 0 ]) ())
  in
  let second_command_policy =
    ok (Run_policy.create ~success_condition:(Run_policy.Commands [ 1 ]) ())
  in
  assert (
    Run_policy.run_succeeded first_command_policy [ slow_success; fast_failure ]);
  assert (
    not
      (Run_policy.run_succeeded second_command_policy
         [ slow_success; fast_failure ]));
  let missing_command_policy =
    ok (Run_policy.create ~success_condition:(Run_policy.Commands [ 9 ]) ())
  in
  assert (
    not
      (Run_policy.run_succeeded missing_command_policy
         [ slow_success; fast_failure ]));
  let all_but_second_policy =
    ok (Run_policy.create ~success_condition:(Run_policy.Commands [ 0 ]) ())
  in
  assert (
    Run_policy.run_succeeded all_but_second_policy
      [ slow_success; fast_failure ]);
  let no_commands_policy =
    ok (Run_policy.create ~success_condition:Run_policy.NoCommands ())
  in
  let ignored_failure =
    close_event ~status:(Close_event.Exited 1) ~started_at:10.0 ~ended_at:20.0
      first_command
  in
  assert (Run_policy.run_succeeded no_commands_policy [ ignored_failure ]);
  let filtered_failure_policy =
    ok (Run_policy.create ~drop_failed_close_events_for_success:true ())
  in
  assert (Run_policy.run_succeeded filtered_failure_policy [ ignored_failure ]);
  assert (Run_policy.run_succeeded filtered_failure_policy []);
  let delayed_policy =
    ok
      (Run_policy.create ~restart_limit:(Run_policy.Finite_restarts 3)
         ~restart_delay:Run_policy.Exponential_backoff ())
  in
  assert (Run_policy.restart_delay_ms delayed_policy ~next_attempt:1 = 1000);
  assert (Run_policy.restart_delay_ms delayed_policy ~next_attempt:2 = 2000);
  assert (Run_policy.restart_delay_ms delayed_policy ~next_attempt:3 = 4000)

let test_run_spec_validation () =
  expect_error `Empty_command_list
    (Run_spec.create ~commands:[] ~policy:Run_policy.default);
  expect_error
    (`Command_index_mismatch (1, 2))
    (Run_spec.create
       ~commands:[ command 0 "echo a"; command 2 "echo b" ]
       ~policy:Run_policy.default);
  let overflowing_policy =
    ok
      (Run_policy.create
         ~restart_limit:(Run_policy.Finite_restarts max_int)
         ())
  in
  expect_error `Close_event_capacity_overflow
    (Run_spec.create
       ~commands:[ command 0 "echo a" ]
       ~policy:overflowing_policy);
  let policy =
    ok
      (Run_policy.create
         ~restart_limit:(Run_policy.Finite_restarts 2)
         ())
  in
  let spec =
    ok
      (Run_spec.create
         ~commands:[ command 0 "echo a"; command 1 "echo b" ]
         ~policy)
  in
  assert (Run_spec.command_count spec = 2);
  assert (Run_spec.close_event_capacity spec = 6);
  let infinite_policy =
    ok (Run_policy.create ~restart_limit:Run_policy.Infinite_restarts ())
  in
  let infinite_spec =
    ok
      (Run_spec.create
         ~commands:[ command 0 "echo a"; command 1 "echo b" ]
         ~policy:infinite_policy)
  in
  assert (Run_spec.close_event_capacity infinite_spec = 2)

let test_run_api_structured_command_inputs () =
  let policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ] ~max_processes:1
         ())
  in
  let request =
    ok
      (Run_api.create ~cwd:"/workspace" ~policy ~labels:[ "api"; "worker" ]
         ~prefix:"name" ~prefix_length:24.0 ~pad_prefix:true
         ~timestamp_format:"HH:mm:ss" ~spacious:true ~timings:true ~group:true
         ~raw:false ~color_mode:Output_formatter.Never ~handle_input:true
         ~default_input_target:"worker"
         [
           Run_api.command ~name:"api"
             ~env:[ ("PORT", "3000") ]
             ~prefix_color:"red.bold" ~raw:true ~ipc:true "npm run api";
           Run_api.command ~name:"worker" ~cwd:"/tmp/worker" ~hidden:true
             "npm run worker";
         ])
  in
  let commands = Run_api.commands request in
  let first = List.nth commands 0 in
  let second = List.nth commands 1 in
  let formatter_options = Run_api.formatter_options request in
  assert (Run_api.policy request = policy);
  assert (Option.is_some (Run_api.input request));
  assert (Command.index first = 0);
  assert (Command.name first = Some "api");
  assert (Command.cwd first = Some "/workspace");
  assert (Command.env first = [ ("PORT", "3000") ]);
  assert (Command.prefix_color first = Some "red.bold");
  assert (Command.raw first);
  assert (Command.ipc first);
  assert (Command.index second = 1);
  assert (Command.name second = Some "worker");
  assert (Command.cwd second = Some "/tmp/worker");
  assert (Command.hidden second);
  assert (formatter_options.Output_formatter.labels = Some [ "api"; "worker" ]);
  assert (formatter_options.Output_formatter.prefix = Some "name");
  assert (formatter_options.Output_formatter.prefix_length = 24.0);
  assert formatter_options.Output_formatter.pad_prefix;
  assert (formatter_options.Output_formatter.timestamp_format = "HH:mm:ss");
  assert formatter_options.Output_formatter.spacious;
  assert formatter_options.Output_formatter.timings;
  assert formatter_options.Output_formatter.group;
  assert (not formatter_options.Output_formatter.raw);
  assert (formatter_options.Output_formatter.color_mode = Output_formatter.Never)

let test_run_api_global_raw_can_be_overridden_per_command () =
  let request =
    ok
      (Run_api.create ~raw:true
         [
           Run_api.command "printf inherited";
           Run_api.command ~raw:false "printf formatted";
         ])
  in
  let commands = Run_api.commands request in
  assert (Command.raw (List.nth commands 0));
  assert (not (Command.raw (List.nth commands 1)));
  assert (Run_api.formatter_options request).Output_formatter.raw

let test_run_api_validation () =
  expect_error
    (`Command_error (0, `Empty_command))
    (Run_api.create [ Run_api.command "" ]);
  expect_error (`Run_spec_error `Empty_command_list) (Run_api.create []);
  assert (
    Result.is_ok
      (Run_api.create ~handle_input:true ~default_input_target:"missing"
         [ Run_api.command ~name:"api" "npm run api" ]))

let test_input_router_routes_default_and_prefixed_input () =
  let commands =
    [
      ok (Command.create ~index:0 ~name:"api" "npm run api");
      ok (Command.create ~index:1 ~name:"worker" "npm run worker");
    ]
  in
  let router =
    Input_router.create ~commands ~index_labels:None
      ~default_input_target:"worker"
  in
  assert (
    Input_router.route router "rs\n"
    = {
        Input_router.target_index = 1;
        target_label = "worker";
        payload = "rs\n";
      });
  assert (
    Input_router.route router "0:reload\n"
    = {
        Input_router.target_index = 0;
        target_label = "0";
        payload = "reload\n";
      });
  assert (
    Input_router.route router "api:reload\n"
    = {
        Input_router.target_index = 0;
        target_label = "api";
        payload = "reload\n";
      });
  assert (
    Input_router.route router "missing:reload\n"
    = {
        Input_router.target_index = 1;
        target_label = "worker";
        payload = "missing:reload\n";
      });
  let missing_default_router =
    Input_router.create ~commands ~index_labels:None
      ~default_input_target:"missing"
  in
  assert (
    Input_router.route missing_default_router "reload\n"
    = {
        Input_router.target_index = -1;
        target_label = "missing";
        payload = "reload\n";
      });
  let empty_default_router =
    Input_router.create ~commands ~index_labels:None ~default_input_target:""
  in
  assert (
    Input_router.route empty_default_router "reload\n"
    = {
        Input_router.target_index = 0;
        target_label = "0";
        payload = "reload\n";
      });
  let reordered_commands =
    [
      ok (Command.create ~index:0 "npm run indexed");
      ok (Command.create ~index:1 ~name:"1" "npm run named");
    ]
  in
  let public_index_router =
    Input_router.create ~commands:reordered_commands
      ~index_labels:(Some [ "1"; "0" ]) ~default_input_target:"1"
  in
  assert (
    Input_router.route public_index_router "reload\n"
    = {
        Input_router.target_index = 1;
        target_label = "1";
        payload = "reload\n";
      });
  let unnamed_reordered_router =
    Input_router.create
      ~commands:
        [
          ok (Command.create ~index:0 "npm run public-one");
          ok (Command.create ~index:1 "npm run public-zero");
        ]
      ~index_labels:(Some [ "1"; "0" ]) ~default_input_target:"1"
  in
  assert (
    Input_router.route unnamed_reordered_router "reload\n"
    = {
        Input_router.target_index = 0;
        target_label = "1";
        payload = "reload\n";
      })

let test_output_event_validation () =
  let command = command 0 "echo ok" in
  let event =
    ok
      (Output_event.output_chunk ~command ~attempt:0 ~process_id:None
         ~stream:Output_event.Stdout ~chunk:"ready" ~line_terminated:true)
  in
  assert (Output_event.command event = Some command);
  assert (Output_event.attempt event = 0);
  assert (
    Output_event.payload event
    = Output_event.Output_chunk_payload
        {
          process_id = None;
          stream = Output_event.Stdout;
          chunk = "ready";
          line_terminated = true;
        });
  let pid_event =
    ok
      (Output_event.output_chunk ~command ~attempt:0 ~process_id:(Some "12345")
         ~stream:Output_event.Stdout ~chunk:"ready" ~line_terminated:true)
  in
  assert (Output_event.process_id pid_event = Some "12345");
  let blank_event =
    ok
      (Output_event.output_chunk ~command ~attempt:0 ~process_id:None
         ~stream:Output_event.Stderr ~chunk:"" ~line_terminated:true)
  in
  assert (
    Output_event.payload blank_event
    = Output_event.Output_chunk_payload
        {
          process_id = None;
          stream = Output_event.Stderr;
          chunk = "";
          line_terminated = true;
        });
  let status_event =
    Output_event.status_message ~after_command:None ~stream:Output_event.Stdout
      ~chunk:"--> Sending SIGTERM to other processes.."
  in
  assert (Output_event.command status_event = None);
  assert (
    Output_event.payload status_event
    = Output_event.Status_message_payload
        {
          stream = Output_event.Stdout;
          chunk = "--> Sending SIGTERM to other processes..";
          after_command = None;
        });
  expect_error `Negative_delay_ms
    (Output_event.lifecycle ~command ~attempt:0
       ~lifecycle:
         (Output_event.Restarting { next_attempt = 1; delay_ms = Some (-1) }));
  expect_error
    (`Invalid_next_attempt (0, 0))
    (Output_event.lifecycle ~command ~attempt:0
       ~lifecycle:
         (Output_event.Restarting { next_attempt = 0; delay_ms = None }));
  expect_error
    (`Invalid_next_attempt (0, 2))
    (Output_event.lifecycle ~command ~attempt:0
       ~lifecycle:
         (Output_event.Restarting { next_attempt = 2; delay_ms = None }))

let run () =
  test_argument_expander_replaces_passthrough_placeholders ();
  test_command_validation ();
  test_run_policy_validation ();
  test_run_policy_decisions ();
  test_run_spec_validation ();
  test_run_api_structured_command_inputs ();
  test_run_api_global_raw_can_be_overridden_per_command ();
  test_run_api_validation ();
  test_input_router_routes_default_and_prefixed_input ();
  test_output_event_validation ()
