module Argument_expander = Concurrentlyocaml.Argument_expander
module Command = Concurrentlyocaml.Command
module Close_event = Concurrentlyocaml.Close_event
module Cli_config = Concurrentlyocaml.Cli_config
module Input_router = Concurrentlyocaml.Input_router
module Output_event = Concurrentlyocaml.Output_event
module Output_formatter = Concurrentlyocaml.Output_formatter
module Posix_runner_backend = Concurrentlyocaml_posix.Posix_runner_backend
module Run_api = Concurrentlyocaml.Run_api
module Run_policy = Concurrentlyocaml.Run_policy
module Run_result = Concurrentlyocaml.Run_result
module Runner_backend = Concurrentlyocaml.Runner_backend
module Runner = Concurrentlyocaml.Runner
module Run_spec = Concurrentlyocaml.Run_spec

let ok = function Ok value -> value | Error _ -> assert false

let expect_error expected = function
  | Ok _ -> assert false
  | Error actual -> assert (actual = expected)

let command index text = ok (Command.create ~index text)

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

let close_event ?(attempt = 0) ?(killed = false)
    ?(status = Close_event.Exited 0) ?(started_at = 10.0) ?(ended_at = 12.5)
    command =
  ok
    (Close_event.create ~command ~attempt ~killed ~status ~started_at ~ended_at)

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
  let infinite_policy = ok (Run_policy.create ~restart_tries:(-1) ()) in
  assert (
    Run_policy.restart_limit infinite_policy = Run_policy.Infinite_restarts);
  assert (Run_policy.restart_tries infinite_policy = -1);
  assert (not (Run_policy.collect_retry_close_events infinite_policy));
  assert (Result.is_ok (Run_policy.create ~kill_timeout_ms:(-1) ()));
  assert (
    Result.is_ok
      (Run_policy.create ~restart_delay:(Run_policy.Fixed_delay_ms (-1)) ()));
  expect_error `Exponential_restart_delay_overflow
    (Run_policy.create ~restart_tries:max_int
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
      (Run_policy.create ~kill_others_on:[ Run_policy.Failure ] ~restart_tries:1
         ())
  in
  let retryable_failure =
    close_event ~attempt:0 ~status:(Close_event.Exited 1) first_command
  in
  let exhausted_failure =
    close_event ~attempt:1 ~status:(Close_event.Exited 1) first_command
  in
  assert (
    not
      (Run_policy.should_kill_after_close retrying_kill_policy retryable_failure));
  assert (
    Run_policy.should_kill_after_close retrying_kill_policy exhausted_failure);
  let infinite_retry_policy = ok (Run_policy.create ~restart_tries:(-1) ()) in
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
      (Run_policy.create ~restart_tries:3
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
  let overflowing_policy = ok (Run_policy.create ~restart_tries:max_int ()) in
  expect_error `Close_event_capacity_overflow
    (Run_spec.create
       ~commands:[ command 0 "echo a" ]
       ~policy:overflowing_policy);
  let policy = ok (Run_policy.create ~restart_tries:2 ()) in
  let spec =
    ok
      (Run_spec.create
         ~commands:[ command 0 "echo a"; command 1 "echo b" ]
         ~policy)
  in
  assert (Run_spec.command_count spec = 2);
  assert (Run_spec.close_event_capacity spec = 6);
  let infinite_policy = ok (Run_policy.create ~restart_tries:(-1) ()) in
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
    ok
      (Input_router.create ~commands ~index_labels:None
         ~default_input_target:"worker")
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
    ok
      (Input_router.create ~commands ~index_labels:None
         ~default_input_target:"missing")
  in
  assert (
    Input_router.route missing_default_router "reload\n"
    = {
        Input_router.target_index = -1;
        target_label = "missing";
        payload = "reload\n";
      });
  let empty_default_router =
    ok
      (Input_router.create ~commands ~index_labels:None
         ~default_input_target:"")
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
    ok
      (Input_router.create ~commands:reordered_commands
         ~index_labels:(Some [ "1"; "0" ]) ~default_input_target:"1")
  in
  assert (
    Input_router.route public_index_router "reload\n"
    = {
        Input_router.target_index = 1;
        target_label = "1";
        payload = "reload\n";
      });
  let unnamed_reordered_router =
    ok
      (Input_router.create
         ~commands:
           [
             ok (Command.create ~index:0 "npm run public-one");
             ok (Command.create ~index:1 "npm run public-zero");
           ]
         ~index_labels:(Some [ "1"; "0" ]) ~default_input_target:"1")
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

let formatter_options ?labels ?prefix ?(prefix_length = 10.0)
    ?(pad_prefix = false) ?(timestamp_format = "yyyy-MM-dd HH:mm:ss.SSS")
    ?(spacious = false) ?(timings = false) ?(group = false) ?(raw = false)
    ?(color_mode = Output_formatter.Never) () =
  {
    Output_formatter.labels;
    index_labels = None;
    prefix;
    prefix_length;
    pad_prefix;
    timestamp_format;
    spacious;
    timings;
    group;
    raw;
    color_mode;
  }

let create_formatter ?(now = fun () -> 0.0) ?wall_now ?labels ?prefix
    ?prefix_length ?pad_prefix ?timestamp_format ?spacious ?timings ?group ?raw
    ?color_mode commands =
  let wall_now =
    match wall_now with Some wall_now -> wall_now | None -> now
  in
  Output_formatter.create ~now ~wall_now ~commands
    (formatter_options ?labels ?prefix ?prefix_length ?pad_prefix
       ?timestamp_format ?spacious ?timings ?group ?raw ?color_mode ())

let output_texts outputs =
  List.map (fun output -> output.Output_formatter.text) outputs

let output_streams outputs =
  List.map (fun output -> output.Output_formatter.stream) outputs

let output_event ?process_id ?(line_terminated = true) command stream chunk =
  ok
    (Output_event.output_chunk ~command ~attempt:0 ~process_id ~stream ~chunk
       ~line_terminated)

let lifecycle_event ?process_id ?(attempt = 0) command lifecycle =
  match process_id with
  | None -> ok (Output_event.lifecycle ~command ~attempt ~lifecycle)
  | Some process_id ->
      ok
        (Output_event.lifecycle_with_process_id ~process_id ~command ~attempt
           ~lifecycle)

let stopped_with_status ?process_id ?(status = Close_event.Exited 0)
    ?(killed = false) command =
  lifecycle_event ?process_id command
    (Output_event.Stopped_with_status { status; killed })

let status_message ?after_command stream chunk =
  Output_event.status_message ~after_command ~stream ~chunk

let test_output_formatter_validation () =
  assert (Output_formatter.default_labels 3 = Ok [ "0"; "1"; "2" ]);
  assert (Output_formatter.default_labels 0 = Ok []);
  assert (Result.is_ok (create_formatter []));
  assert (
    Result.is_ok (create_formatter ~prefix_length:(-1.0) [ command 0 "echo api" ]));
  expect_error
    (`Label_count_mismatch (1, 2))
    (create_formatter ~labels:[ "api" ]
       [ command 0 "echo api"; command 1 "echo worker" ]);
  assert (
    Result.is_ok
      (create_formatter
         [ ok (Command.create ~index:0 ~prefix_color:"bogus" "echo api") ]))

let test_output_formatter_streams_unbuffered_output () =
  let command = command 0 "echo ready" in
  let formatter = ok (create_formatter [ command ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "ready")
    |> output_texts = [ "[0] ready" ]);
  let stderr_outputs =
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stderr "failed")
  in
  assert (output_texts stderr_outputs = [ "[0] failed" ]);
  assert (output_streams stderr_outputs = [ Output_event.Stdout ])

let test_output_formatter_preserves_partial_line_state () =
  let command = command 0 "node -e partial" in
  let formatter = ok (create_formatter [ command ]) in
  let stdout_outputs =
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false command Output_event.Stdout "out")
  in
  assert (output_texts stdout_outputs = [ "[0] out" ]);
  assert (
    List.map
      (fun output -> output.Output_formatter.trailing_newline)
      stdout_outputs
    = [ false ]);
  let stderr_outputs =
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false command Output_event.Stderr "err")
  in
  assert (output_texts stderr_outputs = [ "err" ]);
  assert (
    List.map
      (fun output -> output.Output_formatter.trailing_newline)
      stderr_outputs
    = [ false ]);
  assert (
    Output_formatter.handle_event formatter (stopped_with_status command)
    |> output_texts
    = [ "\n[0] node -e partial exited with code 0" ])

let test_output_formatter_separates_global_status_after_partial_line () =
  let command = command 0 "node -e partial" in
  let formatter = ok (create_formatter [ command ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false command Output_event.Stdout
         "partial")
    |> output_texts
    = [ "[0] partial" ]);
  assert (
    Output_formatter.handle_event formatter
      (status_message Output_event.Stdout
         "--> Unable to find command \"missing\", or it has no stdin open\n--> ")
    |> output_texts
    = [
        "\n\
         --> Unable to find command \"missing\", or it has no stdin open\n\
         --> ";
      ]);
  assert (
    Output_formatter.handle_event formatter (stopped_with_status command)
    |> output_texts
    = [ "[0] node -e partial exited with code 0" ])

let test_output_formatter_separates_grouped_partial_close_status () =
  let blocker = command 0 "sleep" in
  let command = command 1 "printf fast" in
  let formatter = ok (create_formatter ~group:true [ blocker; command ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false command Output_event.Stdout "fast")
    = []);
  assert (
    Output_formatter.handle_event formatter (stopped_with_status command) = []);
  assert (
    Output_formatter.handle_event formatter (stopped_with_status blocker)
    |> output_texts
    = [
        "[0] sleep exited with code 0";
        "[1] fast";
        "\n[1] printf fast exited with code 0";
      ])

let test_output_formatter_spacious_preserves_partial_chunks () =
  let command = command 0 "printf partial" in
  let formatter = ok (create_formatter ~spacious:true [ command ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false command Output_event.Stdout "part")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false command Output_event.Stdout "ial")
    = []);
  assert (
    Output_formatter.handle_event formatter (stopped_with_status command)
    |> output_texts |> String.concat "\n"
    = "\n\
       [0]:\n\
       [0] partial\n\
       [0] printf partial exited with code 0")

let test_output_formatter_preserves_crlf_lines () =
  let command = command 0 "printf crlf" in
  let formatter = ok (create_formatter [ command ]) in
  let outputs =
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "a\r")
  in
  assert (output_texts outputs = [ "[0] a\r" ]);
  assert (
    List.map
      (fun output -> output.Output_formatter.trailing_newline)
      outputs
    = [ true ])

let test_output_formatter_prints_close_status () =
  let command = command 0 "printf ok" in
  let formatter = ok (create_formatter [ command ]) in
  assert (
    Output_formatter.handle_event formatter (stopped_with_status command)
    |> output_texts
    = [ "[0] printf ok exited with code 0" ]);
  let pid_formatter = ok (create_formatter ~prefix:"pid" [ command ]) in
  assert (
    Output_formatter.handle_event pid_formatter
      (stopped_with_status ~process_id:"12345" command)
    |> output_texts
    = [ "[12345] printf ok exited with code 0" ]);
  let signaled_formatter = ok (create_formatter [ command ]) in
  assert (
    Output_formatter.handle_event signaled_formatter
      (stopped_with_status ~status:(Close_event.Signaled "15") ~killed:true
         command)
    |> output_texts
    = [ "[0] printf ok exited with code SIGTERM" ]);
  let host_signal_formatter = ok (create_formatter [ command ]) in
  assert (
    Output_formatter.handle_event host_signal_formatter
      (stopped_with_status
         ~status:(Close_event.Signaled (string_of_int Sys.sigterm))
         ~killed:true command)
    |> output_texts
    = [ "[0] printf ok exited with code SIGTERM" ]);
  let raw_command = ok (Command.create ~index:0 ~raw:true "printf raw") in
  let raw_formatter = ok (create_formatter [ raw_command ]) in
  assert (
    Output_formatter.handle_event raw_formatter
      (stopped_with_status raw_command)
    = []);
  let hidden_command =
    ok (Command.create ~index:0 ~hidden:true "printf hidden")
  in
  let hidden_formatter = ok (create_formatter [ hidden_command ]) in
  assert (
    Output_formatter.handle_event hidden_formatter
      (stopped_with_status hidden_command)
    = [])

let test_output_formatter_prints_run_status_messages () =
  let command = command 0 "printf ok" in
  let formatter = ok (create_formatter [ command ]) in
  let outputs =
    Output_formatter.handle_event formatter
      (Output_event.status_message ~after_command:None
         ~stream:Output_event.Stdout
         ~chunk:"--> Sending SIGTERM to other processes..")
  in
  assert (output_texts outputs = [ "--> Sending SIGTERM to other processes.." ]);
  assert (output_streams outputs = [ Output_event.Stdout ]);
  let raw_formatter = ok (create_formatter ~raw:true [ command ]) in
  assert (
    Output_formatter.handle_event raw_formatter
      (Output_event.status_message ~after_command:None
         ~stream:Output_event.Stdout
         ~chunk:"--> Running teardown command \"cleanup\"")
    = []);
  let delayed_formatter = ok (create_formatter [ command ]) in
  assert (
    Output_formatter.handle_event delayed_formatter
      (Output_event.status_message ~after_command:(Some command)
         ~stream:Output_event.Stdout
         ~chunk:"--> Sending SIGTERM to other processes..")
    = []);
  assert (
    Output_formatter.handle_event delayed_formatter
      (stopped_with_status command)
    |> output_texts
    = [
        "[0] printf ok exited with code 0";
        "--> Sending SIGTERM to other processes..";
      ]);
  let spacious_formatter = ok (create_formatter ~spacious:true [ command ]) in
  assert (
    Output_formatter.handle_event spacious_formatter
      (output_event command Output_event.Stdout "ok")
    = []);
  assert (
    Output_formatter.handle_event spacious_formatter
      (Output_event.status_message ~after_command:(Some command)
         ~stream:Output_event.Stdout
         ~chunk:"--> Sending SIGTERM to other processes..")
    = []);
  assert (
    Output_formatter.handle_event spacious_formatter
      (stopped_with_status command)
    |> output_texts |> String.concat "\n"
    = "\n\
       [0]:\n\
       [0] ok\n\
       [0] printf ok exited with code 0\n\
       --> Sending SIGTERM to other processes..")

let test_output_formatter_prints_restart_after_close_status () =
  let command = command 0 "exit 1" in
  let formatter = ok (create_formatter [ command ]) in
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command
         (Output_event.Restarting { next_attempt = 1; delay_ms = Some 1000 }))
    = []);
  assert (
    Output_formatter.handle_event formatter
      (stopped_with_status ~status:(Close_event.Exited 1) command)
    |> output_texts
    = [ "[0] exit 1 exited with code 1"; "[0] exit 1 restarted" ])

let test_output_formatter_prefix_modes () =
  let api = ok (Command.create ~index:0 ~name:"api" "npm run api") in
  let worker = ok (Command.create ~index:1 ~name:"worker" "npm run worker") in
  let commands = [ api; worker ] in
  let output command formatter =
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "ready")
    |> output_texts
  in
  assert (
    output api (ok (create_formatter ~labels:[ "api"; "worker" ] commands))
    = [ "[api] ready" ]);
  assert (output api (ok (create_formatter commands)) = [ "[api] ready" ]);
  let named_shortcut =
    ok (Command.create ~index:0 ~name:"print" "npm run print")
  in
  let unnamed_literal = command 1 "printf normal" in
  let mixed_commands = [ named_shortcut; unnamed_literal ] in
  assert (
    output named_shortcut (ok (create_formatter mixed_commands))
    = [ "[print] ready" ]);
  assert (
    output unnamed_literal (ok (create_formatter mixed_commands))
    = [ "[1] ready" ]);
  assert (
    output unnamed_literal
      (ok
         (create_formatter
            ~labels:[ "print"; "literal-long" ]
            ~pad_prefix:true mixed_commands))
    = [ "[literal-long] ready" ]);
  assert (
    output named_shortcut
      (ok
         (create_formatter
            ~labels:[ "print"; "literal-long" ]
            ~pad_prefix:true mixed_commands))
    = [ "[print       ] ready" ]);
  assert (
    output api (ok (create_formatter ~prefix:"index" commands))
    = [ "[0] ready" ]);
  assert (
    output named_shortcut (ok (create_formatter ~prefix:"index" mixed_commands))
    = [ "[0] ready" ]);
  assert (
    Output_formatter.handle_event
      (ok (create_formatter ~prefix:"pid" commands))
      (output_event ~process_id:"12345" api Output_event.Stdout "ready")
    |> output_texts = [ "[12345] ready" ]);
  assert (
    output api
      (ok (create_formatter ~prefix:"command" ~prefix_length:4.0 commands))
    = [ "[n..i] ready" ]);
  assert (
    output api (ok (create_formatter ~prefix:"none" commands)) = [ "ready" ]);
  assert (
    output api
      (ok (create_formatter ~prefix:"{index}:{pid}:{command}:{name}" commands))
    = [ "0::npm .. api:api ready" ]);
  let wrapped_api =
    ok (Command.create ~index:0 ~display_text:"npm run api" "node wrapper")
  in
  assert (
    output wrapped_api
      (ok (create_formatter ~prefix:"command" ~prefix_length:10.0 [ wrapped_api ]))
    = [ "[npm .. api] ready" ]);
  assert (
    Output_formatter.handle_event (ok (create_formatter [ wrapped_api ]))
      (stopped_with_status wrapped_api)
    |> output_texts
    = [ "[0] npm run api exited with code 0" ]);
  assert (
    Output_formatter.handle_event
      (ok (create_formatter ~prefix:"{index}:{pid}:{name}" commands))
      (output_event ~process_id:"12345" api Output_event.Stdout "ready")
    |> output_texts = [ "0:12345:api ready" ]);
  let upper_api = ok (Command.create ~index:0 ~name:"API" "npm run api") in
  assert (
    output upper_api
      (ok (create_formatter ~prefix:"Service-{name}" [ upper_api ]))
    = [ "Service-API ready" ]);
  let command_with_placeholder = command 0 "printf '{time}'" in
  assert (
    output command_with_placeholder
      (ok (create_formatter ~prefix:"{command}" [ command_with_placeholder ]))
    = [ "prin..me}' ready" ]);
  assert (
    output api
      (ok
         (create_formatter ~prefix:"time" ~timestamp_format:"SSS"
            ~wall_now:(fun () -> 0.123)
            commands))
    = [ "[123] ready" ]);
  assert (
    output api
      (ok
         (create_formatter ~prefix:"time" ~timestamp_format:"SSS"
            ~now:(fun () -> 9000.0)
            ~wall_now:(fun () -> 0.123)
            commands))
    = [ "[123] ready" ]);
  assert (
    output api
      (ok
         (create_formatter ~prefix:"command" ~prefix_length:0.0 ~pad_prefix:true
            commands))
    = [ "[npm .. api] ready" ]);
  assert (
    output worker
      (ok
         (create_formatter ~prefix:"command" ~prefix_length:0.0 ~pad_prefix:true
            commands))
    = [ "[npm ..rker] ready" ]);
  assert (
    output api
      (ok (create_formatter ~prefix:"command" ~prefix_length:(-1.0) commands))
    = [ "[npm run ap..] ready" ])

let test_output_formatter_prefix_colors () =
  let api = ok (Command.create ~index:0 ~prefix_color:"red.bold" "echo api") in
  let worker =
    ok (Command.create ~index:1 ~prefix_color:"#336699" "echo worker")
  in
  let reset = ok (Command.create ~index:2 ~prefix_color:"reset" "echo reset") in
  let invalid =
    ok (Command.create ~index:3 ~prefix_color:"bogus" "echo invalid")
  in
  let short_hex =
    ok (Command.create ~index:4 ~prefix_color:"#f00" "echo short")
  in
  let output command formatter =
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "ready")
    |> output_texts
  in
  let formatter =
    ok
      (create_formatter ~color_mode:Output_formatter.Truecolor
         [ api; worker; reset; invalid; short_hex ])
  in
  assert (output api formatter = [ "\027[31m\027[1m[0]\027[22m\027[39m ready" ]);
  assert (output worker formatter = [ "\027[38;2;51;102;153m[1]\027[39m ready" ]);
  assert (output reset formatter = [ "\027[0m[2]\027[0m ready" ]);
  assert (output invalid formatter = [ "\027[0m[3]\027[0m ready" ]);
  assert (output short_hex formatter = [ "\027[38;2;255;0;0m[4]\027[39m ready" ]);
  assert (
    output api
      (ok
         (create_formatter ~color_mode:Output_formatter.Never
            [ api; worker; reset; invalid; short_hex ]))
    = [ "[0] ready" ])

let test_output_formatter_prints_timing_lifecycle_events () =
  let command = command 0 "echo ready" in
  let now_value = ref 10.0 in
  let formatter =
    ok
      (create_formatter
         ~now:(fun () -> !now_value)
         ~labels:[ "api" ] ~timestamp_format:"SSS" ~timings:true [ command ])
  in
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Started)
    |> output_texts
    = [ "[api] echo ready started at 000" ]);
  now_value := 10.25;
  assert (
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "start")
    |> output_texts = [ "[api] start" ]);
  assert (
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "end")
    |> output_texts = [ "[api] end" ]);
  assert (
    Output_formatter.handle_event formatter (stopped_with_status command)
    |> output_texts
    = [
        "[api] echo ready stopped at 250 after 250ms";
        "[api] echo ready exited with code 0";
        "--> Timings:";
        "--> ┌──────┬──────────┬───────────┬────────┬────────────┐";
        "--> │ name │ duration │ exit code │ killed │ command    │";
        "--> ├──────┼──────────┼───────────┼────────┼────────────┤";
        "--> │      │ 250      │ 0         │ false  │ echo ready │";
        "--> └──────┴──────────┴───────────┴────────┴────────────┘";
      ])

let test_output_formatter_preserves_blank_buffered_lines () =
  let command = command 0 "printf" in
  let formatter =
    ok (create_formatter ~labels:[ "app" ] ~spacious:true [ command ])
  in
  ignore
    (Output_formatter.handle_event formatter
       (output_event command Output_event.Stdout "a"));
  ignore
    (Output_formatter.handle_event formatter
       (output_event command Output_event.Stdout ""));
  ignore
    (Output_formatter.handle_event formatter
       (output_event command Output_event.Stdout "b"));
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Stopped)
    |> output_texts
    = [ "\n[app]:\n[app] a\n[app] \n[app] b" ])

let test_output_formatter_group_streams_active_command () =
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let formatter = ok (create_formatter ~group:true [ api; worker ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event api Output_event.Stdout "api-live")
    |> output_texts = [ "[0] api-live" ]);
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-buffered")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts = [ "[1] worker-buffered" ]);
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-live")
    |> output_texts = [ "[1] worker-live" ])

let test_output_formatter_group_flushes_buffer_when_command_becomes_active () =
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let formatter = ok (create_formatter ~group:true [ api; worker ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-early")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts = [ "[1] worker-early" ]);
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-live")
    |> output_texts = [ "[1] worker-live" ])

let test_output_formatter_groups_command_status_messages () =
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let status_chunk = "--> Sending SIGTERM to other processes.." in
  let formatter = ok (create_formatter ~group:true [ api; worker ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-buffered")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (status_message ~after_command:api Output_event.Stdout status_chunk)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts
    = [ status_chunk; "[1] worker-buffered" ]);
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let formatter = ok (create_formatter ~group:true [ api; worker ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-buffered")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (status_message ~after_command:worker Output_event.Stdout status_chunk)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts
    = [ "[1] worker-buffered"; status_chunk ])

let test_output_formatter_groups_output_in_command_order () =
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let formatter = ok (create_formatter ~group:true [ api; worker ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-one")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker-two")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event api Output_event.Stdout "api")
    |> output_texts = [ "[0] api" ]);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts
    = [ "[1] worker-one"; "[1] worker-two" ])

let test_output_formatter_groups_output_in_stream_order () =
  let blocker = command 0 "printf blocker" in
  let command = command 1 "printf mixed" in
  let formatter = ok (create_formatter ~group:true [ blocker; command ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stderr "stderr-first")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "stdout-second")
    = []);
  let outputs =
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Stopped)
  in
  assert (outputs = []);
  let outputs =
    Output_formatter.handle_event formatter
      (lifecycle_event blocker Output_event.Stopped)
  in
  assert (output_texts outputs = [ "[1] stderr-first"; "[1] stdout-second" ]);
  assert (output_streams outputs = [ Output_event.Stdout; Output_event.Stdout ])

let test_output_formatter_groups_retried_command_output_until_final_stop () =
  let blocker = command 0 "printf blocker" in
  let command = command 1 "flaky" in
  let formatter = ok (create_formatter ~group:true [ blocker; command ]) in
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Started)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event ~process_id:"pid-one" command Output_event.Stdout "failed")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command
         (Output_event.Restarting { next_attempt = 1; delay_ms = None }))
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event ~attempt:1 command Output_event.Started)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event ~process_id:"pid-two" command Output_event.Stdout
         "succeeded")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event ~attempt:1 command Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event blocker Output_event.Stopped)
    |> output_texts
    = [ "[1] failed"; "[1] flaky restarted"; "[1] succeeded" ])

let test_output_formatter_groups_raw_output_in_command_order () =
  let api = ok (Command.create ~index:0 ~raw:true "printf api") in
  let worker = ok (Command.create ~index:1 ~raw:true "printf worker") in
  let formatter = ok (create_formatter ~group:true [ api; worker ]) in
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event api Output_event.Stdout "api")
    |> output_texts = [ "api" ]);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts = [ "worker" ])

let test_output_formatter_group_raw_streams_active_with_timings () =
  let api = ok (Command.create ~index:0 ~raw:true "printf api") in
  let worker = ok (Command.create ~index:1 ~raw:true "printf worker") in
  let formatter =
    ok (create_formatter ~group:true ~timings:true [ api; worker ])
  in
  assert (
    Output_formatter.handle_event formatter
      (output_event api Output_event.Stdout "api")
    |> output_texts = [ "api" ]);
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker")
    = [])

let test_output_formatter_group_raw_flushes_active_buffer_before_streaming () =
  let api = ok (Command.create ~index:0 ~raw:true "printf api") in
  let worker = ok (Command.create ~index:1 ~raw:true "printf worker") in
  let formatter =
    ok (create_formatter ~group:true ~timings:true [ api; worker ])
  in
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "first")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts = [ "first" ]);
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "second")
    |> output_texts = [ "second" ])

let test_output_formatter_group_preserves_buffered_time_prefix () =
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let wall_now = ref 0.0 in
  let formatter =
    ok
      (create_formatter
         ~wall_now:(fun () -> !wall_now)
         ~group:true ~prefix:"time" ~timestamp_format:"SSS" [ api; worker ])
  in
  wall_now := 0.123;
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "one")
    = []);
  wall_now := 0.456;
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "two")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  wall_now := 0.987;
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts
    = [ "[123] one"; "[456] two" ])

let test_output_formatter_group_timings_preserve_buffered_time_prefix () =
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let wall_now = ref 0.0 in
  let formatter =
    ok
      (create_formatter
         ~wall_now:(fun () -> !wall_now)
         ~group:true ~timings:true ~prefix:"time" ~timestamp_format:"SSS"
         [ api; worker ])
  in
  wall_now := 0.123;
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "one")
    = []);
  wall_now := 0.456;
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "two")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  wall_now := 0.987;
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts
    = [ "[123] one"; "[456] two" ])

let test_output_formatter_groups_buffered_retry_pids_per_chunk () =
  let blocker = command 0 "printf blocker" in
  let command = command 1 "flaky" in
  let formatter =
    ok (create_formatter ~group:true ~prefix:"pid" [ blocker; command ])
  in
  assert (
    Output_formatter.handle_event formatter
      (output_event ~process_id:"pid-one" command Output_event.Stdout "failed")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command
         (Output_event.Restarting { next_attempt = 1; delay_ms = None }))
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (output_event ~process_id:"pid-two" command Output_event.Stdout
         "succeeded")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event ~attempt:1 command Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event blocker Output_event.Stopped)
    |> output_texts
    = [ "[pid-one] failed"; "[] flaky restarted"; "[pid-two] succeeded" ])

let test_output_formatter_group_timings_include_retry_span () =
  let blocker = command 0 "printf blocker" in
  let command = command 1 "flaky" in
  let now = ref 0.0 in
  let formatter =
    ok
      (create_formatter
         ~now:(fun () -> !now)
         ~group:true ~timestamp_format:"SSS" ~timings:true [ blocker; command ])
  in
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Started)
    = []);
  now := 0.05;
  assert (
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "failed")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command
         (Output_event.Restarting { next_attempt = 1; delay_ms = Some 100 }))
    = []);
  now := 0.1;
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event command Output_event.Stopped)
    = []);
  now := 0.2;
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event ~attempt:1 command Output_event.Started)
    = []);
  now := 0.3;
  assert (
    Output_formatter.handle_event formatter
      (output_event command Output_event.Stdout "succeeded")
    = []);
  now := 0.4;
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event ~attempt:1 command Output_event.Stopped)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event blocker Output_event.Stopped)
    |> output_texts
    = [
        "[1] flaky started at 000";
        "[1] failed";
        "[1] flaky restarted";
        "[1] flaky started at 200";
        "[1] succeeded";
      ])

let test_output_formatter_group_timings_stream_lifecycle_and_flush_waiting () =
  let api = command 0 "printf api" in
  let worker = command 1 "printf worker" in
  let now = ref 0.0 in
  let formatter =
    ok
      (create_formatter
         ~now:(fun () -> !now)
         ~group:true ~timestamp_format:"SSS" ~timings:true [ api; worker ])
  in
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Started)
    |> output_texts
    = [ "[0] printf api started at 000" ]);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Started)
    = []);
  now := 0.1;
  assert (
    Output_formatter.handle_event formatter
      (output_event worker Output_event.Stdout "worker")
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event worker Output_event.Stopped)
    = []);
  now := 10.0;
  assert (
    Output_formatter.handle_event formatter
      (output_event api Output_event.Stdout "api")
    |> output_texts = [ "[0] api" ]);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event api Output_event.Stopped)
    |> output_texts
    = [ "[1] printf worker started at 000"; "[1] worker" ])

let test_output_formatter_ignores_teardown_lifecycle_outside_main_commands () =
  let main_command = command 0 "printf main" in
  let teardown_command =
    ok (Command.create ~index:1 ~raw:true "printf clean")
  in
  let formatter = ok (create_formatter ~group:true [ main_command ]) in
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event teardown_command Output_event.Started)
    = []);
  assert (
    Output_formatter.handle_event formatter
      (lifecycle_event teardown_command Output_event.Stopped)
    = [])

let test_output_formatter_streams_teardown_output_outside_group () =
  let main_command = command 0 "printf main" in
  let teardown_command =
    ok (Command.create ~index:1 ~raw:true "printf clean")
  in
  let formatter =
    ok (create_formatter ~group:true ~timings:true [ main_command ])
  in
  let outputs =
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false teardown_command Output_event.Stdout
         "clean")
  in
  assert (output_texts outputs = [ "clean" ]);
  assert (
    List.for_all
      (fun output -> not output.Output_formatter.trailing_newline)
      outputs)

let test_output_formatter_raw_and_hidden_commands () =
  let raw_command = ok (Command.create ~index:0 ~raw:true "printf raw") in
  let hidden_command =
    ok (Command.create ~index:1 ~hidden:true "printf hidden")
  in
  let formatter = ok (create_formatter [ raw_command; hidden_command ]) in
  let raw_outputs =
    Output_formatter.handle_event formatter
      (output_event ~line_terminated:false raw_command Output_event.Stderr "raw")
  in
  assert (output_texts raw_outputs = [ "raw" ]);
  assert (output_streams raw_outputs = [ Output_event.Stderr ]);
  assert (
    List.for_all
      (fun output -> not output.Output_formatter.trailing_newline)
      raw_outputs);
  assert (
    Output_formatter.handle_event formatter
      (output_event hidden_command Output_event.Stdout "hidden")
    = [])

let test_run_result_validation () =
  let first_command = command 0 "echo ok" in
  let policy = Run_policy.default in
  let spec = ok (Run_spec.create ~commands:[ first_command ] ~policy) in
  let successful_close_event = close_event first_command in
  let result =
    ok
      (Run_result.create ~spec ~close_events:[ successful_close_event ]
         ~output_event_count:1 ~interrupted:false)
  in
  assert (Run_result.exit_code result = 0);
  let interrupted_sigint_result =
    ok
      (Run_result.create_interrupted_by_signal ~signal:Sys.sigint ~spec
         ~close_events:[] ~output_event_count:0)
  in
  assert (Run_result.interrupted interrupted_sigint_result);
  assert (Run_result.exit_code interrupted_sigint_result = 0);
  let interrupted_sigterm_result =
    ok
      (Run_result.create_interrupted_by_signal ~signal:Sys.sigterm ~spec
         ~close_events:[] ~output_event_count:0)
  in
  assert (Run_result.exit_code interrupted_sigterm_result = 1);
  let interrupted_sigterm_success_result =
    ok
      (Run_result.create_interrupted_by_signal ~signal:Sys.sigterm ~spec
         ~close_events:[ successful_close_event ] ~output_event_count:0)
  in
  assert (Run_result.exit_code interrupted_sigterm_success_result = 0);
  expect_error `Missing_close_events
    (Run_result.create ~spec ~close_events:[] ~output_event_count:0
       ~interrupted:false);
  expect_error `Negative_output_event_count
    (Run_result.create ~spec ~close_events:[ successful_close_event ]
       ~output_event_count:(-1) ~interrupted:false);
  expect_error `Too_many_close_events
    (Run_result.create ~spec
       ~close_events:[ successful_close_event; successful_close_event ]
       ~output_event_count:0 ~interrupted:false);
  let unknown_close_event = close_event (command 1 "echo unknown") in
  expect_error (`Unknown_command_index 1)
    (Run_result.create ~spec ~close_events:[ unknown_close_event ]
       ~output_event_count:0 ~interrupted:false);
  let unexpected_close_event = close_event (command 0 "echo foreign") in
  expect_error (`Unexpected_command 0)
    (Run_result.create ~spec ~close_events:[ unexpected_close_event ]
       ~output_event_count:0 ~interrupted:false);
  let second_command = command 1 "echo second" in
  let two_command_spec =
    ok (Run_spec.create ~commands:[ first_command; second_command ] ~policy)
  in
  let first_retry = close_event ~attempt:1 first_command in
  expect_error `Missing_close_events
    (Run_result.create ~spec:two_command_spec
       ~close_events:[ successful_close_event ] ~output_event_count:0
       ~interrupted:false);
  expect_error
    (`Attempt_exceeds_restart_tries (0, 1))
    (Run_result.create ~spec:two_command_spec
       ~close_events:[ first_retry; close_event second_command ]
       ~output_event_count:0 ~interrupted:false);
  let retry_policy = ok (Run_policy.create ~restart_tries:1 ()) in
  let retry_spec =
    ok (Run_spec.create ~commands:[ first_command ] ~policy:retry_policy)
  in
  let failed_first_attempt =
    close_event ~status:(Close_event.Exited 1) first_command
  in
  expect_error
    (`Incomplete_restart_attempt (0, 0))
    (Run_result.create ~spec:retry_spec ~close_events:[ failed_first_attempt ]
       ~output_event_count:0 ~interrupted:false);
  let successful_retry = close_event ~attempt:1 first_command in
  expect_error
    (`Missing_close_event_attempt (0, 0))
    (Run_result.create ~spec:retry_spec ~close_events:[ successful_retry ]
       ~output_event_count:0 ~interrupted:false);
  let large_retry_policy = ok (Run_policy.create ~restart_tries:1_000_000 ()) in
  let large_retry_spec =
    ok (Run_spec.create ~commands:[ first_command ] ~policy:large_retry_policy)
  in
  expect_error
    (`Missing_close_event_attempt (0, 0))
    (Run_result.create ~spec:large_retry_spec ~close_events:[ successful_retry ]
       ~output_event_count:0 ~interrupted:false);
  let failed_after_success =
    close_event ~attempt:1 ~status:(Close_event.Exited 1) first_command
  in
  expect_error
    (`Attempt_after_success (0, 1))
    (Run_result.create ~spec:retry_spec
       ~close_events:[ failed_after_success; successful_close_event ]
       ~output_event_count:0 ~interrupted:false);
  let retry_result =
    ok
      (Run_result.create ~spec:retry_spec
         ~close_events:[ successful_retry; failed_first_attempt ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.exit_code retry_result = 0);
  let infinite_policy = ok (Run_policy.create ~restart_tries:(-1) ()) in
  let infinite_spec =
    ok (Run_spec.create ~commands:[ first_command ] ~policy:infinite_policy)
  in
  let late_success = close_event ~attempt:5 first_command in
  let infinite_result =
    ok
      (Run_result.create ~spec:infinite_spec ~close_events:[ late_success ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.close_events infinite_result = [ late_success ]);
  assert (Run_result.exit_code infinite_result = 0);
  let late_failure =
    close_event ~attempt:5 ~status:(Close_event.Exited 1) first_command
  in
  expect_error
    (`Incomplete_restart_attempt (0, 5))
    (Run_result.create ~spec:infinite_spec ~close_events:[ late_failure ]
       ~output_event_count:0 ~interrupted:false);
  expect_error
    (`Duplicate_close_event_attempt (0, 0))
    (Run_result.create ~spec:retry_spec
       ~close_events:[ successful_close_event; successful_close_event ]
       ~output_event_count:0 ~interrupted:false);
  let cancel_policy =
    ok (Run_policy.create ~kill_others_on:[ Run_policy.Success ] ())
  in
  let cancel_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:cancel_policy)
  in
  let cancelled_result =
    ok
      (Run_result.create ~spec:cancel_spec
         ~close_events:[ successful_close_event ] ~output_event_count:0
         ~interrupted:false)
  in
  assert (Run_result.exit_code cancelled_result = 0);
  let retry_cancel_policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ] ~restart_tries:1
         ())
  in
  let retry_cancel_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:retry_cancel_policy)
  in
  let retryable_second_failure =
    close_event ~status:(Close_event.Exited 1) second_command
  in
  let retryable_sibling_cancelled_result =
    ok
      (Run_result.create ~spec:retry_cancel_spec
         ~close_events:[ retryable_second_failure; successful_close_event ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.exit_code retryable_sibling_cancelled_result = 0);
  let completed_second_failure =
    close_event ~attempt:1 ~status:(Close_event.Exited 1) second_command
  in
  let completed_failure_before_cancel_result =
    ok
      (Run_result.create ~spec:retry_cancel_spec
         ~close_events:
           [
             retryable_second_failure;
             completed_second_failure;
             successful_close_event;
           ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.exit_code completed_failure_before_cancel_result = 1);
  let killed_second_command =
    close_event ~killed:true ~status:(Close_event.Signaled "SIGTERM")
      second_command
  in
  let cleanly_cancelled_second_command =
    close_event ~killed:true ~status:(Close_event.Exited 0) second_command
  in
  let killed_sibling_result =
    ok
      (Run_result.create ~spec:cancel_spec
         ~close_events:[ successful_close_event; killed_second_command ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.exit_code killed_sibling_result = 1);
  let cleanly_cancelled_sibling_result =
    ok
      (Run_result.create ~spec:cancel_spec
         ~close_events:[ successful_close_event; cleanly_cancelled_second_command ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.exit_code cleanly_cancelled_sibling_result = 0);
  let require_second_after_first_cancels_policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~success_condition:(Run_policy.Commands [ 1 ]) ())
  in
  let require_second_after_first_cancels_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:require_second_after_first_cancels_policy)
  in
  let required_sibling_killed_result =
    ok
      (Run_result.create ~spec:require_second_after_first_cancels_spec
         ~close_events:[ successful_close_event; killed_second_command ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.exit_code required_sibling_killed_result = 1);
  let kill_on_failure_policy =
    ok (Run_policy.create ~kill_others_on:[ Run_policy.Failure ] ())
  in
  let kill_on_failure_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:kill_on_failure_policy)
  in
  expect_error `Missing_close_events
    (Run_result.create ~spec:kill_on_failure_spec
       ~close_events:[ successful_close_event ] ~output_event_count:0
       ~interrupted:false);
  let failed_close_event =
    close_event ~status:(Close_event.Exited 1) first_command
  in
  let failed_cancelled_result =
    ok
      (Run_result.create ~spec:kill_on_failure_spec
         ~close_events:[ failed_close_event ] ~output_event_count:0
         ~interrupted:false)
  in
  assert (Run_result.exit_code failed_cancelled_result = 1);
  let killed_after_failure_result =
    ok
      (Run_result.create ~spec:kill_on_failure_spec
         ~close_events:[ failed_close_event; killed_second_command ]
         ~output_event_count:0 ~interrupted:false)
  in
  assert (Run_result.exit_code killed_after_failure_result = 1)

let test_close_event_validation () =
  let command = command 0 "echo ok" in
  expect_error `Negative_exit_code
    (Close_event.create ~command ~attempt:0 ~killed:false
       ~status:(Close_event.Exited (-1)) ~started_at:0.0 ~ended_at:1.0);
  expect_error `Empty_signal
    (Close_event.create ~command ~attempt:0 ~killed:false
       ~status:(Close_event.Signaled " ") ~started_at:0.0 ~ended_at:1.0)

let test_cli_config_validation () =
  let config =
    ok
      (Cli_config.create ~passthrough_arguments:None
         ~cwd:(Some "/tmp/concurrently-ocaml")
         ~command_texts:[ "echo api"; "echo worker" ]
         ~names_csv:(Some "api,worker") ~name_separator:"," ~spacious:true
         ~timings:true ~group:true ~raw:true
         ~hide_csv:(Some "worker,99,missing") ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:true
         ~prefix:(Some "command") ~prefix_colors_csv:(Some "red,blue")
         ~prefix_length:8.0 ~pad_prefix:true ~timestamp_format:"HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"command-worker"
         ~kill_others_on_success:false ~kill_others:true ~kill_others_on_fail:true ~kill_signal:"SIGKILL"
         ~kill_timeout_ms:(Some "250") ~max_processes:(Some "2")
         ~restart_tries:"2" ~restart_after:"exponential"
         ~teardown_texts:[ "printf clean" ])
  in
  let commands = Cli_config.commands config in
  let policy = Cli_config.policy config in
  let display = Cli_config.display config in
  let teardown = Run_policy.teardown policy in
  assert (List.length commands = 2);
  assert (List.length teardown = 1);
  assert (Command.name (List.nth commands 0) = Some "api");
  assert (Command.name (List.nth commands 1) = Some "worker");
  assert (Command.cwd (List.nth commands 0) = Some "/tmp/concurrently-ocaml");
  assert (Command.cwd (List.nth commands 1) = Some "/tmp/concurrently-ocaml");
  assert (Command.index (List.nth teardown 0) = 2);
  assert (Command.text (List.nth teardown 0) = "printf clean");
  assert (Command.cwd (List.nth teardown 0) = Some "/tmp/concurrently-ocaml");
  assert (Command.raw (List.nth teardown 0));
  assert (Command.prefix_color (List.nth commands 0) = Some "red");
  assert (Command.prefix_color (List.nth commands 1) = Some "blue");
  assert (display.labels = Some [ "api"; "worker" ]);
  assert display.spacious;
  assert display.timings;
  assert display.group;
  assert display.raw;
  assert display.no_color;
  assert (display.prefix = Some "command");
  assert (display.prefix_length = 8.0);
  assert display.pad_prefix;
  assert (display.timestamp_format = "HH:mm:ss.SSS");
  assert (Command.raw (List.nth commands 0));
  assert (Command.raw (List.nth commands 1));
  assert (not (Command.hidden (List.nth commands 0)));
  assert (Command.hidden (List.nth commands 1));
  assert (
    Run_policy.kill_others_on policy
    = [ Run_policy.Success; Run_policy.Failure ]);
  assert (Run_policy.kill_signal policy = Run_policy.Sigkill);
  assert (Run_policy.kill_timeout_ms policy = Some 250);
  assert (Run_policy.success_condition policy = Run_policy.Commands [ 1 ]);
  assert (Run_policy.max_processes policy = Some 2);
  assert (Run_policy.restart_tries policy = 2);
  assert (not (Run_policy.drop_failed_close_events_for_success policy));
  assert (Run_policy.restart_delay policy = Run_policy.Exponential_backoff);
  assert (Cli_config.input config = None);
  let empty_teardown_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "printf ok" ] ~names_csv:None ~name_separator:","
         ~spacious:false ~timings:false ~group:false ~raw:false ~hide_csv:None
         ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"all"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0" ~teardown_texts:[ "" ])
  in
  let empty_teardown =
    Run_policy.teardown (Cli_config.policy empty_teardown_config)
  in
  assert (List.length empty_teardown = 1);
  assert (Command.text (List.hd empty_teardown) = "");
  let restart_tries_config restart_tries =
    Cli_config.create ~passthrough_arguments:None ~cwd:None
      ~command_texts:[ "exit 1" ] ~names_csv:None ~name_separator:","
      ~spacious:false ~timings:false ~group:false ~raw:false ~hide_csv:None
      ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
      ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
      ~handle_input:false ~default_input_target:"0" ~success:"all"
      ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
      ~kill_timeout_ms:None ~max_processes:None ~restart_tries
      ~restart_after:"0" ~teardown_texts:[]
  in
  let fractional_restart_policy =
    Cli_config.policy (ok (restart_tries_config "1.5"))
  in
  assert (Run_policy.restart_tries fractional_restart_policy = 1);
  assert (
    Run_policy.drop_failed_close_events_for_success fractional_restart_policy);
  let invalid_restart_policy =
    Cli_config.policy (ok (restart_tries_config "bogus"))
  in
  assert (Run_policy.restart_tries invalid_restart_policy = 0);
  assert (Run_policy.drop_failed_close_events_for_success invalid_restart_policy);
  let kill_signal_policy kill_signal =
    Cli_config.policy
      (ok
         (Cli_config.create ~passthrough_arguments:None ~cwd:None
            ~command_texts:[ "printf ok" ] ~names_csv:None ~name_separator:","
            ~spacious:false ~timings:false ~group:false ~raw:false
            ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None
            ~prefix_length:10.0 ~pad_prefix:false
            ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
            ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
            ~kill_others_on_fail:false ~kill_signal ~kill_timeout_ms:None
            ~max_processes:None ~restart_tries:"0" ~restart_after:"0"
            ~teardown_texts:[]))
  in
  let empty_kill_signal_policy = kill_signal_policy "" in
  assert (Run_policy.kill_signal empty_kill_signal_policy = Run_policy.Sigterm);
  let bare_term_kill_signal_policy = kill_signal_policy "TERM" in
  assert (
    Run_policy.kill_signal bare_term_kill_signal_policy
    = Run_policy.Named_signal "TERM");
  let lowercase_term_kill_signal_policy = kill_signal_policy "term" in
  assert (
    Run_policy.kill_signal lowercase_term_kill_signal_policy
    = Run_policy.Named_signal "term");
  let infinite_restart_policy =
    Cli_config.policy (ok (restart_tries_config "Infinity"))
  in
  assert (Run_policy.restart_tries infinite_restart_policy = -1);
  assert (
    not
      (Run_policy.drop_failed_close_events_for_success infinite_restart_policy));
  let invalid_restart_after_policy =
    Cli_config.policy
      (ok
         (Cli_config.create ~passthrough_arguments:None ~cwd:None
            ~command_texts:[ "exit 1" ] ~names_csv:None ~name_separator:","
            ~spacious:false ~timings:false ~group:false ~raw:false
            ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None
            ~prefix_length:10.0 ~pad_prefix:false
            ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
            ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
            ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
            ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"1"
            ~restart_after:"bogus" ~teardown_texts:[]))
  in
	  assert (
	    Run_policy.restart_delay_warning invalid_restart_after_policy
	    = Some Run_policy.Timeout_nan);
	  let blank_restart_after_policy =
	    Cli_config.policy
	      (ok
	         (Cli_config.create ~passthrough_arguments:None ~cwd:None
	            ~command_texts:[ "exit 1" ] ~names_csv:None ~name_separator:","
	            ~spacious:false ~timings:false ~group:false ~raw:false
	            ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None
	            ~prefix_length:10.0 ~pad_prefix:false
	            ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
	            ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
	            ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
	            ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"1"
	            ~restart_after:"" ~teardown_texts:[]))
	  in
	  assert (
	    Run_policy.restart_delay blank_restart_after_policy
	    = Run_policy.Fixed_delay_ms 0);
	  assert (Run_policy.restart_delay_warning blank_restart_after_policy = None);
  let negative_restart_policy =
    Cli_config.policy (ok (restart_tries_config "-1"))
  in
  assert (Run_policy.restart_tries negative_restart_policy = -1);
  assert (
    not
      (Run_policy.drop_failed_close_events_for_success negative_restart_policy));
  let kill_timeout_config kill_timeout_ms =
    Cli_config.create ~passthrough_arguments:None ~cwd:None
      ~command_texts:[ "sleep 1"; "printf ok" ] ~names_csv:None
      ~name_separator:"," ~spacious:false ~timings:false ~group:false ~raw:false
      ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None
      ~prefix_length:10.0 ~pad_prefix:false
      ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
      ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:true
      ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
      ~kill_timeout_ms:(Some kill_timeout_ms) ~max_processes:None
      ~restart_tries:"0" ~restart_after:"0" ~teardown_texts:[]
  in
  assert (
    Run_policy.kill_timeout_ms
      (Cli_config.policy (ok (kill_timeout_config "1.5")))
    = Some 1);
  assert (
    Run_policy.kill_timeout_ms
      (Cli_config.policy (ok (kill_timeout_config "0.5")))
    = Some 1);
  assert (
    Run_policy.kill_timeout_ms
      (Cli_config.policy (ok (kill_timeout_config "-1")))
    = Some (-1));
  assert (
    Run_policy.kill_timeout_warning
      (Cli_config.policy (ok (kill_timeout_config "-1.5")))
    = Some (Run_policy.Timeout_negative "-1.5"));
  assert (
    Run_policy.kill_timeout_ms
      (Cli_config.policy (ok (kill_timeout_config "bogus")))
    = Some 0);
  let cpu_count = Domain.recommended_domain_count () in
  assert (cpu_count >= 1);
  let max_processes_config max_processes =
    Cli_config.create ~passthrough_arguments:None ~cwd:None
      ~command_texts:[ "echo api"; "echo worker"; "echo extra" ]
      ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
      ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
      ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
      ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
      ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
      ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
      ~max_processes:(Some max_processes) ~restart_tries:"0" ~restart_after:"0"
      ~teardown_texts:[]
  in
  let max_processes_policy max_processes =
    Cli_config.policy (ok (max_processes_config max_processes))
  in
  assert (Run_policy.max_processes (max_processes_policy "2") = Some 2);
  assert (Run_policy.max_processes (max_processes_policy "0") = Some 3);
  assert (Run_policy.max_processes (max_processes_policy "0%") = Some 3);
  assert (Run_policy.max_processes (max_processes_policy "nope") = Some 3);
  assert (Run_policy.max_processes (max_processes_policy "1.5") = Some 2);
  assert (Run_policy.max_processes (max_processes_policy "-1") = Some 1);
  assert (Run_policy.max_processes (max_processes_policy "-50%") = Some 1);
  let expected_half_cpu_count =
    max 1 (int_of_float (floor ((float_of_int cpu_count *. 0.5) +. 0.5)))
  in
  let percent_max_processes_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "echo api"; "echo worker" ]
         ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
         ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:(Some "50%") ~restart_tries:"0" ~restart_after:"0"
         ~teardown_texts:[])
  in
  assert (
    Run_policy.max_processes (Cli_config.policy percent_max_processes_config)
    = Some expected_half_cpu_count);
  let tiny_percent_max_processes_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "echo api"; "echo worker" ]
         ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
         ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:(Some "1%") ~restart_tries:"0" ~restart_after:"0"
         ~teardown_texts:[])
  in
  assert (
    Run_policy.max_processes
      (Cli_config.policy tiny_percent_max_processes_config)
    = Some 1);
  let passthrough_config =
    ok
      (Cli_config.create
         ~passthrough_arguments:(Some [ "--watch"; "client build" ])
         ~cwd:None
         ~command_texts:[ "printf %s {1}"; "printf %s {@}"; "printf %s {*}" ]
         ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
         ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0"
         ~teardown_texts:[])
  in
  assert (
    List.map Command.text (Cli_config.commands passthrough_config)
    = [
        "printf %s --watch";
        "printf %s --watch 'client build'";
        "printf %s '--watch client build'";
      ]);
  let literal_placeholder_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "printf %s {1}" ] ~names_csv:None ~name_separator:","
         ~spacious:false ~timings:false ~group:false ~raw:false ~hide_csv:None
         ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"all"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0" ~teardown_texts:[])
  in
  assert (
    List.map Command.text (Cli_config.commands literal_placeholder_config)
    = [ "printf %s {1}" ]);
  let shortcut_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "npm:print -- --flag"; "printf normal" ]
         ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
         ~group:false ~raw:false ~hide_csv:(Some "print") ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false
         ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"command-print"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0" ~teardown_texts:[])
  in
  assert (
    List.map Command.text (Cli_config.commands shortcut_config)
    = [ "npm run print -- --flag"; "printf normal" ]);
  assert (
    List.map Command.name (Cli_config.commands shortcut_config)
    = [ Some "print"; None ]);
  assert (Command.hidden (List.nth (Cli_config.commands shortcut_config) 0));
  assert (
    not (Command.hidden (List.nth (Cli_config.commands shortcut_config) 1)));
  let api_raw_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "printf formatted"; "printf raw" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None
         ~api_raw_indexes_csv:(Some "1") ~api_formatted_indexes_csv:None
         ~api_index_labels_csv:None
         ~no_color:false ~prefix:None ~prefix_colors_csv:None
         ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false
         ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0" ~teardown_texts:[])
  in
  assert (
    List.map Command.raw (Cli_config.commands api_raw_config)
    = [ false; true ]);
  let api_formatted_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "printf formatted"; "printf raw" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:true ~hide_csv:None ~api_hide_indexes_csv:None
         ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:(Some "0")
         ~api_index_labels_csv:None
         ~no_color:false ~prefix:None ~prefix_colors_csv:None
         ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false
         ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0" ~teardown_texts:[])
  in
  assert (
    List.map Command.raw (Cli_config.commands api_formatted_config)
    = [ false; true ]);
  assert ((Cli_config.display shortcut_config).labels = Some [ "print"; "" ]);
  assert (
    Run_policy.success_condition (Cli_config.policy shortcut_config)
    = Run_policy.Commands [ 0 ]);
  let passthrough_shortcut_config =
    ok
      (Cli_config.create ~passthrough_arguments:(Some [ "client build" ])
         ~cwd:None ~command_texts:[ "npm:{1}" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0"
         ~teardown_texts:[])
  in
  assert (
    List.map Command.text (Cli_config.commands passthrough_shortcut_config)
    = [ "npm run 'client build'" ]);
  assert (
    List.map Command.name (Cli_config.commands passthrough_shortcut_config)
    = [ Some "{1}" ]);
  let explicit_shortcut_name_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "npm:print" ] ~names_csv:(Some "custom")
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0"
         ~teardown_texts:[])
  in
  assert (
    List.map Command.text (Cli_config.commands explicit_shortcut_name_config)
    = [ "npm run print" ]);
  assert (
    List.map Command.name (Cli_config.commands explicit_shortcut_name_config)
    = [ Some "custom" ]);
  let quoted_shortcut_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "npm:build;echo-injected" ]
         ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
         ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0"
         ~teardown_texts:[])
  in
  assert (
    List.map Command.text (Cli_config.commands quoted_shortcut_config)
    = [ "npm run build;echo-injected" ]);
  let with_script_fixture run =
    let directory = Filename.temp_file "concurrently-scripts" "" in
    Sys.remove directory;
    Unix.mkdir directory 0o700;
    let previous_directory = Sys.getcwd () in
    let remove_if_exists path = if Sys.file_exists path then Sys.remove path in
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir previous_directory;
        remove_if_exists (Filename.concat directory "package.json");
        remove_if_exists (Filename.concat directory "deno.jsonc");
        Unix.rmdir directory)
      (fun () ->
        Out_channel.with_open_text (Filename.concat directory "package.json")
          (fun channel ->
            output_string channel
              "{\"config\":{\"scripts\":{\"wrong\":\"printf \
               wrong\"}},\"scripts\":{\"build-css\":\"printf \
               css\",\"build-js\":\"printf \
               js\",\"build;echo-injected\":\"printf \
               safe\",\"watch-\":\"printf empty\",\"dev-web\":\"printf \
               web\",\"omit-css\":\"printf css\",\"omit-sass\":\"printf \
               sass\",\"omit-js\":\"printf js\"}}\n");
        Out_channel.with_open_text (Filename.concat directory "deno.jsonc")
          (fun channel ->
            output_string channel
              "{// comment\n\
               \"tasks\":{\"dev-api\":\"deno run api.ts\",\"dev-ui\":\"deno \
               run ui.ts\"}}\n");
        let child_directory = Filename.concat directory "child" in
        Unix.mkdir child_directory 0o700;
        Out_channel.with_open_text
          (Filename.concat child_directory "package.json") (fun channel ->
            output_string channel
              "{\"scripts\":{\"child-css\":\"printf child-css\"}}\n");
        Sys.chdir directory;
        Fun.protect
          ~finally:(fun () ->
            remove_if_exists (Filename.concat child_directory "package.json");
            Unix.rmdir child_directory)
          (fun () -> run ~child_directory))
  in
  with_script_fixture (fun ~child_directory ->
      let wildcard_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:build-*"; "printf normal" ]
             ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
             ~group:false ~raw:false ~hide_csv:(Some "css") ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false
             ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
             ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
             ~handle_input:false ~default_input_target:"0" ~success:"command-js"
             ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false
             ~kill_signal:"SIGTERM" ~kill_timeout_ms:None ~max_processes:None
             ~restart_tries:"0" ~restart_after:"0" ~teardown_texts:[])
      in
      let commands = Cli_config.commands wildcard_config in
      let command_texts = List.map Command.text commands in
      assert (List.mem "npm run build-css" command_texts);
      assert (List.mem "npm run build-js" command_texts);
      assert (List.mem "printf normal" command_texts);
      assert (not (List.mem "npm run wrong" command_texts));
      let command_names = List.map Command.name commands in
      assert (List.mem (Some "css") command_names);
      assert (List.mem (Some "js") command_names);
      assert (List.mem None command_names);
      assert (Command.hidden (List.nth commands 0));
      assert (not (Command.hidden (List.nth commands 1)));
      assert (
        (Cli_config.display wildcard_config).labels = Some [ "css"; "js"; "" ]);
      assert (
        Run_policy.success_condition (Cli_config.policy wildcard_config)
        = Run_policy.Commands [ 1 ]);
      let suffix_wildcard_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:build-* -- --url='a&b' && echo done" ]
             ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
             ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[])
      in
      assert (
        List.map Command.text (Cli_config.commands suffix_wildcard_config)
        = [
            "npm run build-css -- --url='a";
            "npm run build-js -- --url='a";
          ]);
      let cwd_wildcard_config =
        ok
          (Cli_config.create ~passthrough_arguments:None
             ~cwd:(Some child_directory) ~command_texts:[ "npm:child-*" ]
             ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
             ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[])
      in
      assert (
        List.map Command.text (Cli_config.commands cwd_wildcard_config)
        = [ "npm run child-css" ]);
      assert (
        List.map Command.cwd (Cli_config.commands cwd_wildcard_config)
        = [ Some child_directory ]);
      let quoted_wildcard_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:build;*" ] ~names_csv:None
             ~name_separator:"," ~spacious:false ~timings:false ~group:false
             ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[])
      in
      assert (
        List.map Command.text (Cli_config.commands quoted_wildcard_config)
        = [ "npm run build;echo-injected" ]);
      let omitted_match_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:omit-*(!css)" ] ~names_csv:None
             ~name_separator:"," ~spacious:false ~timings:false ~group:false
             ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[])
      in
      assert (
        List.map Command.text (Cli_config.commands omitted_match_config)
        = [ "npm run omit-sass"; "npm run omit-js" ]);
      let no_match_wildcard_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:no-match-*" ] ~names_csv:None
             ~name_separator:"," ~spacious:false ~timings:false ~group:false
             ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[])
      in
      assert (Cli_config.is_no_op no_match_wildcard_config);
      assert (Cli_config.commands no_match_wildcard_config = []);
      let no_match_teardown_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:no-match-*" ] ~names_csv:None
             ~name_separator:"," ~spacious:false ~timings:false ~group:false
             ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[ "printf clean" ])
      in
      assert (not (Cli_config.is_no_op no_match_teardown_config));
      assert (Cli_config.commands no_match_teardown_config = []);
      assert (
        List.map Command.text
          (Run_policy.teardown (Cli_config.policy no_match_teardown_config))
        = [ "printf clean" ]);
      let invalid_restart_after_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:no-match-*" ] ~names_csv:None
             ~name_separator:"," ~spacious:false ~timings:false ~group:false
             ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"later" ~teardown_texts:[])
      in
      assert (
        Run_policy.restart_delay
          (Cli_config.policy invalid_restart_after_config)
        = Run_policy.Fixed_delay_ms 0);
      let prefixed_wildcard_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "npm:build-*" ] ~names_csv:(Some "pre")
             ~name_separator:"," ~spacious:false ~timings:false ~group:false
             ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
             ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[])
      in
      assert (
        List.map Command.name (Cli_config.commands prefixed_wildcard_config)
        = [ Some "precss"; Some "prejs" ]);
      let deno_wildcard_config =
        ok
          (Cli_config.create ~passthrough_arguments:None ~cwd:None
             ~command_texts:[ "deno:dev-*" ] ~names_csv:None ~name_separator:","
             ~spacious:false ~timings:false ~group:false ~raw:false
             ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None
             ~prefix_length:10.0 ~pad_prefix:false
             ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
             ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
             ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
             ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
             ~restart_after:"0" ~teardown_texts:[])
      in
      assert (
        List.map Command.text (Cli_config.commands deno_wildcard_config)
        = [ "deno task dev-api"; "deno task dev-ui"; "deno task dev-web" ]);
      assert (
        List.map Command.name (Cli_config.commands deno_wildcard_config)
        = [ Some "api"; Some "ui"; Some "web" ]));
  let input_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "echo api"; "echo worker" ]
         ~names_csv:(Some "api,worker") ~name_separator:"," ~spacious:false
         ~timings:false ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false
         ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:true ~default_input_target:"worker" ~success:"all"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0" ~teardown_texts:[])
  in
  assert (Option.is_some (Cli_config.input input_config));
  let fail_only_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"!command-0" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:true ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0")
  in
  assert (
    Run_policy.kill_others_on (Cli_config.policy fail_only_config)
    = [ Run_policy.Failure ]);
  assert (
    Run_policy.success_condition (Cli_config.policy fail_only_config)
    = Run_policy.NoCommands);
  assert ((Cli_config.display fail_only_config).labels = None);
  let first_success_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"first" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0")
  in
  assert (
    Run_policy.success_condition (Cli_config.policy first_success_config)
    = Run_policy.First);
  let repeated_prefix_color_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[]
         ~command_texts:[ "echo api"; "echo worker"; "echo docs" ]
         ~names_csv:None ~name_separator:"," ~spacious:false ~timings:false
         ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:(Some "red,blue") ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"all"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0")
  in
  assert (
    List.map Command.prefix_color
      (Cli_config.commands repeated_prefix_color_config)
    = [ Some "red"; Some "blue"; Some "blue" ]);
  let spaced_name_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[]
         ~command_texts:[ "echo api"; "echo worker" ]
         ~names_csv:(Some "api, worker") ~name_separator:"," ~spacious:false
         ~timings:false ~group:false ~raw:false ~hide_csv:(Some "worker")
         ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"command-worker"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0")
  in
  assert (
    List.map Command.name (Cli_config.commands spaced_name_config)
    = [ Some "api"; Some " worker" ]);
  assert (
    List.for_all
      (fun command -> not (Command.hidden command))
      (Cli_config.commands spaced_name_config));
  assert (
    Run_policy.success_condition (Cli_config.policy spaced_name_config)
    = Run_policy.Commands []);
  let custom_name_separator_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[]
         ~command_texts:[ "echo api"; "echo worker"; "echo docs" ]
         ~names_csv:(Some "api| worker|docs") ~name_separator:"|"
         ~spacious:false ~timings:false ~group:false ~raw:false
         ~hide_csv:(Some "docs") ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"command- worker" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0")
  in
  assert (
    List.map Command.name (Cli_config.commands custom_name_separator_config)
    = [ Some "api"; Some " worker"; Some "docs" ]);
  assert (
    Command.hidden
      (List.nth (Cli_config.commands custom_name_separator_config) 2));
	  assert (
	    Run_policy.success_condition
	      (Cli_config.policy custom_name_separator_config)
	    = Run_policy.Commands [ 1 ]);
	  let unicode_empty_separator_config =
	    ok
	      (Cli_config.create ~passthrough_arguments:None ~cwd:None
	         ~teardown_texts:[] ~command_texts:[ "echo face"; "echo x" ]
	         ~names_csv:(Some "😀x") ~name_separator:"" ~spacious:false
	         ~timings:false ~group:false ~raw:false ~hide_csv:None
	         ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None ~prefix_colors_csv:None
	         ~prefix_length:10.0 ~pad_prefix:false
	         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
	         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
	         ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
	         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
	         ~restart_after:"0")
	  in
	  assert (
	    List.map Command.name
	      (Cli_config.commands unicode_empty_separator_config)
	    = [ Some "😀"; Some "x" ]);
	  let unmatched_negated_success_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"!command-missing"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0")
  in
  assert (
    Run_policy.success_condition
      (Cli_config.policy unmatched_negated_success_config)
    = Run_policy.Commands [ 0 ]);
  assert (
    Result.is_ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:true
         ~default_input_target:"missing" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0"));
  let unmatched_success_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"command-" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0")
  in
  assert (
    Run_policy.success_condition (Cli_config.policy unmatched_success_config)
    = Run_policy.All);
  let invalid_restart_after_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"later")
  in
  assert (
    Run_policy.restart_delay (Cli_config.policy invalid_restart_after_config)
    = Run_policy.Fixed_delay_ms 0);
  let fractional_restart_after_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"1.5")
  in
  assert (
    Run_policy.restart_delay (Cli_config.policy fractional_restart_after_config)
    = Run_policy.Fixed_delay_ms 1);
  let negative_restart_after_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"-1")
  in
  assert (
    Run_policy.restart_delay (Cli_config.policy negative_restart_after_config)
    = Run_policy.Fixed_delay_ms 0);
  let short_name_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[]
         ~command_texts:[ "echo api"; "echo worker" ]
         ~names_csv:(Some "api") ~name_separator:"," ~spacious:false
         ~timings:false ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false
         ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"all"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0")
  in
  assert (
    List.map Command.name (Cli_config.commands short_name_config)
    = [ Some "api"; None ]);
  assert ((Cli_config.display short_name_config).labels = Some [ "api"; "" ]);
  let blank_name_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[]
         ~command_texts:[ "echo api"; "echo worker" ]
         ~names_csv:(Some "api, ") ~name_separator:"," ~spacious:false
         ~timings:false ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false
         ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0
         ~pad_prefix:false ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS"
         ~handle_input:false ~default_input_target:"0" ~success:"all"
         ~kill_others_on_success:false ~kill_others:false ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0")
  in
  assert (
    List.map Command.name (Cli_config.commands blank_name_config)
    = [ Some "api"; Some " " ]);
  assert ((Cli_config.display blank_name_config).labels = Some [ "api"; " " ]);
  let empty_separator_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~teardown_texts:[]
         ~command_texts:[ "echo api"; "echo worker" ] ~names_csv:(Some "a,b")
         ~name_separator:"" ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
         ~max_processes:None ~restart_tries:"0" ~restart_after:"0")
  in
  assert (
    List.map Command.name (Cli_config.commands empty_separator_config)
    = [ Some "a"; Some "," ]);
  assert (
    (Cli_config.display empty_separator_config).labels = Some [ "a"; "," ]);
  expect_error (`Run_spec_error `Empty_command_list)
    (Cli_config.create ~passthrough_arguments:None ~cwd:None ~teardown_texts:[]
       ~command_texts:[] ~names_csv:None ~name_separator:"," ~spacious:false
       ~timings:false ~group:false ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false
       ~prefix:None ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
       ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
       ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
       ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
       ~max_processes:None ~restart_tries:"0" ~restart_after:"0");
  expect_error
    (`Command_error (0, `Empty_cwd))
    (Cli_config.create ~passthrough_arguments:None ~cwd:(Some " ")
       ~teardown_texts:[] ~command_texts:[ "echo api" ] ~names_csv:None
       ~name_separator:"," ~spacious:false ~timings:false ~group:false
       ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
       ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
       ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
       ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
       ~kill_others_on_fail:false ~kill_signal:"SIGTERM" ~kill_timeout_ms:None
       ~max_processes:None ~restart_tries:"0" ~restart_after:"0");
  let blank_teardown_config =
    ok
      (Cli_config.create ~passthrough_arguments:None ~cwd:None
         ~command_texts:[ "echo api" ] ~teardown_texts:[ " " ] ~names_csv:None
         ~name_separator:"," ~spacious:false ~timings:false ~group:false
         ~raw:false ~hide_csv:None ~api_hide_indexes_csv:None ~api_raw_indexes_csv:None ~api_formatted_indexes_csv:None ~api_index_labels_csv:None ~no_color:false ~prefix:None
         ~prefix_colors_csv:None ~prefix_length:10.0 ~pad_prefix:false
         ~timestamp_format:"yyyy-MM-dd HH:mm:ss.SSS" ~handle_input:false
         ~default_input_target:"0" ~success:"all" ~kill_others_on_success:false ~kill_others:false
         ~kill_others_on_fail:false ~kill_signal:"SIGTERM"
         ~kill_timeout_ms:None ~max_processes:None ~restart_tries:"0"
         ~restart_after:"0")
  in
  let blank_teardown =
    Run_policy.teardown (Cli_config.policy blank_teardown_config)
  in
  assert (Command.text (List.hd blank_teardown) = " ")

let output_chunks events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Output_chunk_payload { chunk; _ } -> Some chunk
      | Output_event.Lifecycle_payload _ | Output_event.Status_message_payload _
      | Output_event.Runtime_warning_payload _
        ->
          None)

let status_messages events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Status_message_payload { chunk; _ } -> Some chunk
      | Output_event.Output_chunk_payload _ | Output_event.Lifecycle_payload _
      | Output_event.Runtime_warning_payload _
        ->
          None)

let stopped_command_indexes events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Lifecycle_payload Output_event.Stopped
      | Output_event.Lifecycle_payload (Output_event.Stopped_with_status _) -> (
          match Output_event.command event with
          | Some command -> Some (Command.index command)
          | None -> None)
      | Output_event.Output_chunk_payload _ | Output_event.Lifecycle_payload _
      | Output_event.Status_message_payload _
      | Output_event.Runtime_warning_payload _ ->
          None)

let rec run_with_events ~policy command_texts =
  let commands =
    command_texts
    |> List.mapi (fun index text -> ok (Command.create ~index text))
  in
  run_commands_with_events ~policy commands

and run_commands_with_events ~policy commands =
  run_commands_with_backend_events ~backend:Posix_runner_backend.backend ~policy
    commands

and run_commands_with_backend_events ~backend ~policy commands =
  Eio_main.run (fun env ->
      let spec = ok (Run_spec.create ~commands ~policy) in
      let events = ref [] in
      let result =
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now (Eio.Stdenv.clock env))
          ~sleep:(fun seconds -> Eio.Time.sleep (Eio.Stdenv.clock env) seconds)
          ~spec
          ~on_output_event:(fun event -> events := event :: !events)
      in
      (result, List.rev !events))

module Slow_eof_source = struct
  type t = { mutable first_read : bool; sleep : unit -> unit }

  let read_methods = []

  let single_read t _buffer =
    if t.first_read then (
      t.first_read <- false;
      t.sleep ());
    raise End_of_file
end

let slow_eof_source ~sleep =
  Eio.Resource.T
    ( { Slow_eof_source.first_read = true; sleep },
      Eio.Flow.Pi.source (module Slow_eof_source) )

module Failing_source = struct
  type t = unit

  let read_methods = []
  let single_read () _buffer = failwith "reader boom"
end

let failing_source () =
  Eio.Resource.T ((), Eio.Flow.Pi.source (module Failing_source))

let backend_process ?(process_id = "test") ?(write_stdin = fun _ -> ())
    ?(close_stdin = fun () -> ()) ?stdout ?stderr ?(signal = fun _ -> Ok true)
    ?(cleanup_after_exit = fun () -> ())
    ?(await = fun () -> Close_event.Exited 0) () =
  let stdout =
    match stdout with
    | Some stdout -> stdout
    | None -> Eio.Flow.string_source ""
  in
  let stderr =
    match stderr with
    | Some stderr -> stderr
    | None -> Eio.Flow.string_source ""
  in
  {
    Runner_backend.process_id;
    write_stdin;
    close_stdin;
    stdout :> Runner_backend.source;
    stderr :> Runner_backend.source;
    signal;
    cleanup_after_exit;
    await;
  }

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
  assert (elapsed < 1.0);
  assert (Run_result.exit_code result = 0);
  assert (
    status_messages events
    = [
        "--> Running teardown command \"sleep 10 &\"";
        "--> Teardown command \"sleep 10 &\" exited with code 0";
      ])

let test_runner_forwards_parent_signal_during_teardown () =
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
                | "main" -> backend_process ()
                | "cleanup" ->
                    backend_process
                      ~signal:(fun signal ->
                        teardown_signaled := Some signal;
                        Ok true)
                      ~await:(fun () ->
                        Unix.kill (Unix.getpid ()) Sys.sigterm;
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
  assert (elapsed < 1.0);
  assert (
    status_messages events = [ "--> Sending SIGTERM to other processes.." ]);
  assert (not (List.mem "slow" (output_chunks events)))

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
  assert (elapsed >= 0.18);
  assert (elapsed < 1.0);
  assert (Run_result.exit_code result = 1);
  assert (
    List.mem "--> Sending SIGKILL to 1 processes.." (status_messages events))

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

let () =
  test_argument_expander_replaces_passthrough_placeholders ();
  test_command_validation ();
  test_run_policy_validation ();
  test_run_policy_decisions ();
  test_run_spec_validation ();
  test_run_api_structured_command_inputs ();
  test_run_api_global_raw_can_be_overridden_per_command ();
  test_run_api_validation ();
  test_input_router_routes_default_and_prefixed_input ();
  test_output_event_validation ();
  test_output_formatter_validation ();
  test_output_formatter_streams_unbuffered_output ();
  test_output_formatter_preserves_partial_line_state ();
  test_output_formatter_separates_global_status_after_partial_line ();
  test_output_formatter_separates_grouped_partial_close_status ();
  test_output_formatter_spacious_preserves_partial_chunks ();
  test_output_formatter_preserves_crlf_lines ();
  test_output_formatter_prints_close_status ();
  test_output_formatter_prints_run_status_messages ();
  test_output_formatter_prints_restart_after_close_status ();
  test_output_formatter_prefix_modes ();
  test_output_formatter_prefix_colors ();
  test_output_formatter_prints_timing_lifecycle_events ();
  test_output_formatter_preserves_blank_buffered_lines ();
  test_output_formatter_group_streams_active_command ();
  test_output_formatter_group_flushes_buffer_when_command_becomes_active ();
  test_output_formatter_groups_command_status_messages ();
  test_output_formatter_groups_output_in_command_order ();
  test_output_formatter_groups_output_in_stream_order ();
  test_output_formatter_groups_retried_command_output_until_final_stop ();
  test_output_formatter_groups_raw_output_in_command_order ();
  test_output_formatter_group_raw_streams_active_with_timings ();
  test_output_formatter_group_raw_flushes_active_buffer_before_streaming ();
  test_output_formatter_group_preserves_buffered_time_prefix ();
  test_output_formatter_group_timings_preserve_buffered_time_prefix ();
  test_output_formatter_groups_buffered_retry_pids_per_chunk ();
  test_output_formatter_group_timings_include_retry_span ();
  test_output_formatter_group_timings_stream_lifecycle_and_flush_waiting ();
  test_output_formatter_ignores_teardown_lifecycle_outside_main_commands ();
  test_output_formatter_streams_teardown_output_outside_group ();
  test_output_formatter_raw_and_hidden_commands ();
  test_run_result_validation ();
  test_close_event_validation ();
  test_cli_config_validation ();
  test_runner_uses_backend_boundary ();
  test_runner_executes_teardown_without_affecting_exit_code ();
  test_posix_runner_cleans_teardown_descendant_pipes ();
  test_runner_forwards_parent_signal_during_teardown ();
  test_runner_executes_teardown_after_empty_expansion ();
  test_runner_records_spawn_failure_as_close_event ();
  test_runner_retries_spawn_failure ();
  test_runner_reports_teardown_spawn_failure_without_affecting_exit_code ();
  test_runner_reports_output_reader_failure ();
  test_runner_signals_process_when_output_emit_fails ();
  test_runner_keeps_retry_during_output_drain ();
  test_runner_reports_signal_failure ();
  test_runner_preserves_retry_after_parent_signal_spawn_race ();
  test_runner_skips_queued_command_at_parent_signal_time ();
  test_runner_parent_signal_does_not_mark_unsignaled_exit_as_killed ();
  test_runner_parent_sigint_completes_restartable_running_command ();
  test_runner_keeps_draining_process_until_close_recorded ();
  test_runner_does_not_mark_unsignaled_sibling_as_killed ();
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
  test_runner_keeps_retry_delay_after_sibling_success ();
  test_runner_kills_siblings_on_failure ();
  test_runner_force_kills_siblings_after_kill_timeout ();
  test_posix_runner_waits_kill_timeout_before_group_cleanup ();
  test_runner_does_not_wait_kill_timeout_after_graceful_signal_exit ();
  test_runner_does_not_wait_kill_timeout_after_clean_signal_exit ();
  test_runner_waits_kill_timeout_before_cleanup_after_signal_exit ();
  test_runner_preserves_first_kill_timeout_deadline ();
  test_runner_does_not_mark_draining_exited_process_as_killed ();
  test_runner_skips_queued_commands_after_failure ();
  test_runner_skips_queued_commands_after_success ();
  test_runner_applies_close_policy_before_descendant_pipe_eof ();
  test_runner_uses_npm_shell_invocation_for_dash_prefixed_commands ();
  print_endline "domain tests ok"
