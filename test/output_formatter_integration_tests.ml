module Command = Concurrentlyocaml.Command
module Close_event = Concurrentlyocaml.Close_event
module Output_event = Concurrentlyocaml.Output_event
module Output_formatter = Concurrentlyocaml.Output_formatter

open Domain_test_support

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

let run () =
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
  test_output_formatter_raw_and_hidden_commands ()
