module Cli_config = Concurrentlyocaml.Cli_config
module Output_event = Concurrentlyocaml.Output_event
module Output_formatter = Concurrentlyocaml.Output_formatter
module Posix_runner_backend = Concurrentlyocaml.Posix_runner_backend
module Runner = Concurrentlyocaml.Runner
module Runner_backend = Concurrentlyocaml.Runner_backend

let print_output output =
  let channel =
    match output.Output_formatter.stream with
    | Output_event.Stdout -> stdout
    | Output_event.Stderr -> stderr
  in
  output_string channel output.Output_formatter.text;
  if output.Output_formatter.trailing_newline then output_char channel '\n';
  flush channel

let print_outputs outputs = List.iter print_output outputs

let run_config env config =
  let display = Cli_config.display config in
  let spec = Cli_config.spec config in
  let formatter_options =
    { Output_formatter.labels = display.Cli_config.labels
    ; prefix = display.Cli_config.prefix
    ; prefix_length = display.Cli_config.prefix_length
    ; pad_prefix = display.Cli_config.pad_prefix
    ; timestamp_format = display.Cli_config.timestamp_format
    ; spacious = display.Cli_config.spacious
    ; timings = display.Cli_config.timings
    ; color_mode =
        (if display.Cli_config.no_color then Output_formatter.Never
         else Output_formatter.Always)
    }
  in
  let process_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let now () = Eio.Time.now clock in
  let sleep seconds = Eio.Time.sleep clock seconds in
  let wall_now = Unix.gettimeofday in
  match
    Output_formatter.create
      ~now
      ~wall_now
      ~commands:(Cli_config.commands config)
      formatter_options
  with
  | Error error ->
    Printf.eprintf "Error: %s\n" (Output_formatter.error_message error);
    1
  | Ok formatter ->
    (match
       Runner.run
         ~input:(Cli_config.input config)
         ~input_source:(Some ((Eio.Stdenv.stdin env :> Runner_backend.source)))
         ~backend:Posix_runner_backend.backend
         ~process_mgr
         ~now
         ~sleep
         ~spec
         ~on_output_event:
           (fun event -> Output_formatter.handle_event formatter event |> print_outputs)
     with
     | Ok result -> Concurrentlyocaml.Run_result.exit_code result
     | Error error ->
       Printf.eprintf "Error: %s\n" (Runner.error_message error);
       1)

let run command_texts names_csv name_separator spacious timings raw hide_csv
    no_color handle_input default_input_target success prefix prefix_colors_csv
    prefix_length timestamp_format pad_prefix kill_others kill_others_on_fail
    kill_signal kill_timeout_ms max_processes restart_tries restart_after
    teardown_texts =
  match
    Cli_config.create
      ~teardown_texts
      ~command_texts
      ~names_csv
      ~name_separator
      ~spacious
      ~timings
      ~raw
      ~hide_csv
      ~no_color
      ~prefix
      ~prefix_colors_csv
      ~prefix_length
      ~pad_prefix
      ~timestamp_format
      ~handle_input
      ~default_input_target
      ~success
      ~kill_others
      ~kill_others_on_fail
      ~kill_signal
      ~kill_timeout_ms
      ~max_processes
      ~restart_tries
      ~restart_after
  with
  | Error error ->
    Printf.eprintf "Error: %s\n" (Cli_config.error_message error);
    1
  | Ok config -> Eio_main.run (fun env -> run_config env config)

let names =
  let doc = "Comma-separated command names. Count must match command count." in
  Cmdliner.Arg.(
    value & opt (some string) None & info [ "n"; "names" ] ~docv:"NAMES" ~doc)

let name_separator =
  let doc = "Character or string used to split --names." in
  Cmdliner.Arg.(
    value & opt string "," & info [ "name-separator" ] ~docv:"SEPARATOR" ~doc)

let spacious =
  let doc = "Print each command block with extra spacing." in
  Cmdliner.Arg.(value & flag & info [ "spacious"; "sp" ] ~doc)

let timings =
  let doc = "Show elapsed time for each command." in
  Cmdliner.Arg.(value & flag & info [ "timings" ] ~doc)

let raw =
  let doc = "Output only raw command output, without prefixes or colors." in
  Cmdliner.Arg.(value & flag & info [ "r"; "raw" ] ~doc)

let hide =
  let doc = "Comma-separated command indexes or names whose output is hidden." in
  Cmdliner.Arg.(value & opt (some string) None & info [ "hide" ] ~docv:"COMMANDS" ~doc)

let no_color =
  let doc = "Disable ANSI colors in formatted output." in
  Cmdliner.Arg.(value & flag & info [ "no-color" ] ~doc)

let handle_input =
  let doc = "Forward stdin to running commands." in
  Cmdliner.Arg.(value & flag & info [ "i"; "handle-input" ] ~doc)

let default_input_target =
  let doc = "Command index or name that receives unprefixed stdin." in
  Cmdliner.Arg.(
    value
    & opt string "0"
    & info [ "default-input-target" ] ~docv:"TARGET" ~doc)

let prefix =
  let doc =
    "Prefix mode: index, name, command, none, time, or a template using \
     {index}, {pid}, {name}, {command}, and {time}."
  in
  Cmdliner.Arg.(
    value & opt (some string) None & info [ "p"; "prefix" ] ~docv:"PREFIX" ~doc)

let prefix_colors =
  let doc =
    "Comma-separated prefix colors. Basic chalk-style colors, background \
     colors, modifiers, auto, reset, and #RRGGBB foreground colors are \
     supported; the last color repeats when there are more commands than \
     colors."
  in
  Cmdliner.Arg.(
    value
    & opt (some string) None
    & info [ "c"; "prefix-colors" ] ~docv:"COLORS" ~doc)

let prefix_length =
  let doc = "Maximum displayed command prefix length when --prefix=command." in
  Cmdliner.Arg.(
    value & opt int 10 & info [ "l"; "prefix-length" ] ~docv:"COUNT" ~doc)

let timestamp_format =
  let doc = "Timestamp format for time prefixes." in
  Cmdliner.Arg.(
    value
    & opt string "yyyy-MM-dd HH:mm:ss.SSS"
    & info [ "t"; "timestamp-format" ] ~docv:"FORMAT" ~doc)

let pad_prefix =
  let doc = "Pad short prefixes so all prefixes have the same length." in
  Cmdliner.Arg.(value & flag & info [ "pad-prefix" ] ~doc)

let success =
  let doc =
    "Success condition: all, first, last, command-{index}, command-{name}, or \
     !command-{index/name}."
  in
  Cmdliner.Arg.(
    value & opt string "all" & info [ "s"; "success" ] ~docv:"CONDITION" ~doc)

let kill_others =
  let doc = "Cancel sibling commands when one command completes." in
  Cmdliner.Arg.(value & flag & info [ "k"; "kill-others" ] ~doc)

let kill_others_on_fail =
  let doc = "Cancel sibling commands when one command fails." in
  Cmdliner.Arg.(value & flag & info [ "kill-others-on-fail" ] ~doc)

let kill_signal =
  let doc = "Signal to send when cancelling sibling commands." in
  Cmdliner.Arg.(
    value
    & opt string "SIGTERM"
    & info [ "kill-signal"; "ks" ] ~docv:"SIGNAL" ~doc)

let kill_timeout =
  let doc = "Milliseconds to wait before force-killing cancelled commands." in
  Cmdliner.Arg.(
    value
    & opt (some int) None
    & info [ "kill-timeout" ] ~docv:"MS" ~doc)

let max_processes =
  let doc = "Maximum number of commands to run at once." in
  Cmdliner.Arg.(
    value
    & opt (some int) None
    & info [ "m"; "max-processes" ] ~docv:"COUNT" ~doc)

let restart_tries =
  let doc = "How many times a failed command should restart." in
  Cmdliner.Arg.(
    value & opt int 0 & info [ "restart-tries" ] ~docv:"COUNT" ~doc)

let restart_after =
  let doc =
    "Delay before restarting a failed command, in milliseconds, or exponential."
  in
  Cmdliner.Arg.(
    value & opt string "0" & info [ "restart-after" ] ~docv:"DELAY" ~doc)

let teardown =
  let doc =
    "Cleanup command to execute before exiting. May be specified multiple \
     times. Teardown output is raw and does not affect the exit code."
  in
  Cmdliner.Arg.(
    value & opt_all string [] & info [ "teardown" ] ~docv:"COMMAND" ~doc)

let command_texts =
  let doc = "Command to run. Use -- before commands that start with '-'." in
  Cmdliner.Arg.(value & pos_all string [] & info [] ~docv:"COMMAND" ~doc)

let command =
  let doc = "Run several shell commands and prefix their output." in
  let info = Cmdliner.Cmd.info "concurrentlyocaml" ~doc in
  Cmdliner.Cmd.v
    info
    Cmdliner.Term.(
      const run
      $ command_texts
      $ names
      $ name_separator
      $ spacious
      $ timings
      $ raw
      $ hide
      $ no_color
      $ handle_input
      $ default_input_target
      $ success
      $ prefix
      $ prefix_colors
      $ prefix_length
      $ timestamp_format
      $ pad_prefix
      $ kill_others
      $ kill_others_on_fail
      $ kill_signal
      $ kill_timeout
      $ max_processes
      $ restart_tries
      $ restart_after
      $ teardown)

let normalize_spacious_argv () =
  let after_command_separator = ref false in
  Array.iteri
    (fun index argument ->
      if index > 0 && not !after_command_separator then
        if argument = "--" then after_command_separator := true
        else if argument = "-sp" then Sys.argv.(index) <- "--sp")
    Sys.argv

let () =
  normalize_spacious_argv ();
  exit (Cmdliner.Cmd.eval' command)
