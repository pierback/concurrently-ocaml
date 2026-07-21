module Command = Concurrentlyocaml.Command
module Cli_config = Concurrentlyocaml.Cli_config
module Run_policy = Concurrentlyocaml.Run_policy

open Domain_test_support

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
  assert (
    Run_policy.restart_limit policy = Run_policy.Finite_restarts 2);
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
  assert (
    Run_policy.restart_limit fractional_restart_policy
    = Run_policy.Finite_restarts 1);
  assert (
    Run_policy.drop_failed_close_events_for_success fractional_restart_policy);
  let invalid_restart_policy =
    Cli_config.policy (ok (restart_tries_config "bogus"))
  in
  assert (
    Run_policy.restart_limit invalid_restart_policy
    = Run_policy.Finite_restarts 0);
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
  assert (
    Run_policy.restart_limit infinite_restart_policy
    = Run_policy.Infinite_restarts);
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
	    Run_policy.restart_delay invalid_restart_after_policy
	    = Run_policy.Fixed_delay_ms 0);
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
  let negative_restart_policy =
    Cli_config.policy (ok (restart_tries_config "-1"))
  in
  assert (
    Run_policy.restart_limit negative_restart_policy
    = Run_policy.Infinite_restarts);
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
    Run_policy.kill_timeout_ms
      (Cli_config.policy (ok (kill_timeout_config "-1.5")))
    = Some (-1));
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

let run () = test_cli_config_validation ()
