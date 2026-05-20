module Cli_argv = Concurrentlyocaml.Cli_argv
module Cli_config = Concurrentlyocaml.Cli_config
module Output_event = Concurrentlyocaml.Output_event
module Output_formatter = Concurrentlyocaml.Output_formatter
module Runner = Concurrentlyocaml.Runner
module Runner_backend = Concurrentlyocaml.Runner_backend
module Version = Concurrentlyocaml.Version

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

let print_deprecation_warnings deprecated_name_separator_used =
  if deprecated_name_separator_used then
    prerr_endline
      "[concurrently] name-separator is deprecated. Use commas as name \
       separators instead."

let print_runner_error error =
  match error with
  | `Unsupported_kill_signal _ -> prerr_endline (Runner.error_message error)
  | _ -> Printf.eprintf "Error: %s\n" (Runner.error_message error)

let parse_force_color_int value =
  let length = String.length value in
  let rec skip_whitespace index =
    if index >= length then index
    else
      match value.[index] with
      | ' ' | '\t' | '\n' | '\r' -> skip_whitespace (index + 1)
      | _ -> index
  in
  let start = skip_whitespace 0 in
  if start >= length then None
  else
    let sign, digit_start =
      match value.[start] with
      | '-' -> (-1, start + 1)
      | '+' -> (1, start + 1)
      | _ -> (1, start)
    in
    let rec parse_digits index acc saw_digit =
      if index >= length then if saw_digit then Some (sign * acc) else None
      else
        match value.[index] with
        | '0' .. '9' as digit ->
            let digit_value = Char.code digit - Char.code '0' in
            let next_acc = min 4 ((acc * 10) + digit_value) in
            parse_digits (index + 1) next_acc true
        | _ -> if saw_digit then Some (sign * acc) else None
    in
    parse_digits digit_start 0 false

let color_mode_of_force_color = function
  | "false" | "0" -> Output_formatter.Never
  | "true" | "" -> Output_formatter.Ansi16
  | value -> (
      match parse_force_color_int value with
      | Some level when level <= 0 -> Output_formatter.Never
      | Some 1 -> Output_formatter.Ansi16
      | Some 2 -> Output_formatter.Ansi256
      | Some _ -> Output_formatter.Truecolor
      | None -> Output_formatter.Never)

let color_mode ~no_color =
  match Sys.getenv_opt "FORCE_COLOR" with
  | Some value -> color_mode_of_force_color value
  | None -> if no_color then Output_formatter.Never else Output_formatter.Truecolor

let npm_compatible_help =
  {help|concurrently [options] <command ...>

General
  -m, --max-processes          How many processes should run at once.
                               New processes only spawn after all restart tries
                               of a process.
                               Exact number or a percent of CPUs available (for
                               example "50%")                           [string]
  -n, --names                  List of custom names to be used in prefix
                               template.
                               Example names: "main,browser,server"     [string]
      --name-separator         The character to split <names> on. Example usage:
                               -n "styles|scripts|server" --name-separator "|"
                                                                  [default: ","]
  -s, --success                Which command(s) must exit with code 0 in order
                               for concurrently exit with code 0 too. Options
                               are:
                               - "first" for the first command to exit;
                               - "last" for the last command to exit;
                               - "all" for all commands;
                               - "command-{name}"/"command-{index}" for the
                               commands with that name or index;
                               - "!command-{name}"/"!command-{index}" for all
                               commands but the ones with that name or index.
                                                                [default: "all"]
  -r, --raw                    Output only raw output of processes, disables
                               prettifying and concurrently coloring.  [boolean]
      --no-color               Disables colors from logging            [boolean]
      --hide                   Comma-separated list of processes to hide the
                               output.
                               The processes can be identified by their name or
                               index.                     [string] [default: ""]
  -g, --group                  Order the output as if the commands were run
                               sequentially.                           [boolean]
      --timings                Show timing information for all processes.
                                                      [boolean] [default: false]
  -P, --passthrough-arguments  Passthrough additional arguments to commands
                               (accessible via placeholders) instead of treating
                               them as commands.      [boolean] [default: false]
      --teardown               Clean up command(s) to execute before exiting
                               concurrently. Might be specified multiple times.
                               These aren't prefixed and they don't affect
                               concurrently's exit code.                 [array]

Prefix styling
  -p, --prefix            Prefix used in logging for each process.
                          Possible values: index, pid, time, command, name,
                          none, or a template. Example template: "{time}-{pid}"
                         [string] [default: index or name (when --names is set)]
  -c, --prefix-colors     Comma-separated list of chalk colors to use on
                          prefixes. If there are more commands than colors, the
                          last color will be repeated.
                          - Available modifiers: reset, bold, dim, italic,
                          underline, inverse, hidden, strikethrough
                          - Available colors: black, red, green, yellow, blue,
                          magenta, cyan, white, gray,
                          any hex values for colors (e.g. #23de43) or auto for
                          an automatically picked color
                          - Available background colors: bgBlack, bgRed,
                          bgGreen, bgYellow, bgBlue, bgMagenta, bgCyan, bgWhite
                          See https://www.npmjs.com/package/chalk for more
                          information.               [string] [default: "reset"]
  -l, --prefix-length     Limit how many characters of the command is displayed
                          in prefix. The option can be used to shorten the
                          prefix when it is set to "command"
                                                          [number] [default: 10]
  -t, --timestamp-format  Specify the timestamp in Unicode format:
                          https://www.unicode.org/reports/tr35/tr35-dates.html#D
                          ate_Field_Symbol_Table
                                   [string] [default: "yyyy-MM-dd HH:mm:ss.SSS"]
      --pad-prefix        Pads short prefixes with spaces so that the length of
                          all prefixes match                           [boolean]

Input handling
  -i, --handle-input          Whether input should be forwarded to the child
                              processes. See examples for more information.
                                                                       [boolean]
      --default-input-target  Identifier for child process to which input on
                              stdin should be sent if not specified at start of
                              input.
                              Can be either the index or the name of the
                              process.                              [default: 0]

Killing other processes
  -k, --kill-others          Kill other processes once the first exits.[boolean]
      --kill-others-on-fail  Kill other processes if one exits with non zero
                             status code.                              [boolean]
      --kill-signal, --ks    Signal to send to other processes if one exits or
                             dies. (SIGTERM/SIGKILL, defaults to SIGTERM)
                                                                        [string]
      --kill-timeout         How many milliseconds to wait before forcing
                             process terminating.                       [number]

Restarting
      --restart-tries  How many times a process that died should restart.
                       Negative numbers will make the process restart forever.
                                                           [number] [default: 0]
      --restart-after  Delay before restarting the process, in milliseconds, or
                       "exponential".                      [string] [default: 0]

Options:
  -h, --help         Show help                                         [boolean]
  -v, -V, --version  Show version number                               [boolean]

For documentation and more examples, visit:
https://github.com/open-cli-tools/concurrently/tree/v9.2.1/docs
|help}

let run_config env config =
  if Cli_config.is_no_op config then 0
  else
    let display = Cli_config.display config in
    let spec = Cli_config.spec config in
    let formatter_options =
      {
        Output_formatter.labels = display.Cli_config.labels;
        prefix = display.Cli_config.prefix;
        prefix_length = display.Cli_config.prefix_length;
        pad_prefix = display.Cli_config.pad_prefix;
        timestamp_format = display.Cli_config.timestamp_format;
        spacious = display.Cli_config.spacious;
        timings = display.Cli_config.timings;
        group = display.Cli_config.group;
        raw = display.Cli_config.raw;
        color_mode = color_mode ~no_color:display.Cli_config.no_color;
      }
    in
    let clock = Eio.Stdenv.clock env in
    let now () = Eio.Time.now clock in
    let sleep seconds = Eio.Time.sleep clock seconds in
    let wall_now = Unix.gettimeofday in
    match
      Output_formatter.create ~now ~wall_now
        ~commands:(Cli_config.commands config)
        formatter_options
    with
    | Error error ->
        Printf.eprintf "Error: %s\n" (Output_formatter.error_message error);
        1
    | Ok formatter -> (
        match Native_backend.load () with
        | Error message ->
            Printf.eprintf "Error: %s\n" message;
            1
        | Ok backend -> (
            match
              Runner.run ~input:(Cli_config.input config)
                ~input_source:
                  (Some (Eio.Stdenv.stdin env :> Runner_backend.source))
                ~backend ~now ~sleep ~spec ~on_output_event:(fun event ->
                  Output_formatter.handle_event formatter event |> print_outputs)
            with
            | Ok result -> Concurrentlyocaml.Run_result.exit_code result
            | Error error ->
                print_runner_error error;
                1))

let run ~passthrough_argv_arguments ~deprecated_name_separator_used
    command_texts names_csv name_separator timings group raw hide_csv no_color
    passthrough_arguments handle_input default_input_target success prefix
    prefix_colors_csv prefix_length timestamp_format pad_prefix kill_others
    kill_others_on_fail kill_signal kill_timeout_ms max_processes restart_tries
    restart_after teardown_texts =
  let prefix_length =
    match float_of_string_opt (String.trim prefix_length) with
    | Some value
      when classify_float value <> FP_nan && value <> 0.0 ->
        value
    | Some _ | None -> 10.0
  in
  match
    Cli_config.create ~cwd:None
      ~passthrough_arguments:
        (if passthrough_arguments then Some passthrough_argv_arguments else None)
      ~teardown_texts ~command_texts ~names_csv ~name_separator ~spacious:false
      ~timings ~group ~raw ~hide_csv ~no_color ~prefix ~prefix_colors_csv
      ~prefix_length ~pad_prefix ~timestamp_format ~handle_input
      ~default_input_target ~success ~kill_others ~kill_others_on_fail
      ~kill_signal ~kill_timeout_ms ~max_processes ~restart_tries ~restart_after
  with
  | Error error ->
      Printf.eprintf "Error: %s\n" (Cli_config.error_message error);
      1
  | Ok config ->
      print_deprecation_warnings deprecated_name_separator_used;
      Eio_main.run (fun env -> run_config env config)

let names =
  let doc = "Comma-separated command names. Count must match command count." in
  Cmdliner.Arg.(
    value & opt (some string) None & info [ "n"; "names" ] ~docv:"NAMES" ~doc)

let name_separator =
  let doc = "Character or string used to split --names." in
  Cmdliner.Arg.(
    value & opt string "," & info [ "name-separator" ] ~docv:"SEPARATOR" ~doc)

let timings =
  let doc = "Show elapsed time for each command." in
  Cmdliner.Arg.(value & flag & info [ "timings" ] ~doc)

let group =
  let doc = "Order output as if commands were run sequentially." in
  Cmdliner.Arg.(value & flag & info [ "g"; "group" ] ~doc)

let raw =
  let doc = "Output only raw command output, without prefixes or colors." in
  Cmdliner.Arg.(value & flag & info [ "r"; "raw" ] ~doc)

let hide =
  let doc =
    "Comma-separated command indexes or names whose output is hidden."
  in
  Cmdliner.Arg.(
    value & opt (some string) None & info [ "hide" ] ~docv:"COMMANDS" ~doc)

let no_color =
  let doc = "Disable ANSI colors in formatted output." in
  Cmdliner.Arg.(value & flag & info [ "no-color" ] ~doc)

let passthrough_arguments =
  let doc =
    "Pass arguments after -- through to commands by replacing {1}, {@}, and \
     {*} placeholders."
  in
  Cmdliner.Arg.(value & flag & info [ "P"; "passthrough-arguments" ] ~doc)

let handle_input =
  let doc = "Forward stdin to running commands." in
  Cmdliner.Arg.(value & flag & info [ "i"; "handle-input" ] ~doc)

let default_input_target =
  let doc = "Command index or name that receives unprefixed stdin." in
  Cmdliner.Arg.(
    value & opt string "0" & info [ "default-input-target" ] ~docv:"TARGET" ~doc)

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
    value & opt string "10" & info [ "l"; "prefix-length" ] ~docv:"COUNT" ~doc)

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
    value & opt string "SIGTERM"
    & info [ "kill-signal"; "ks" ] ~docv:"SIGNAL" ~doc)

let kill_timeout =
  let doc = "Milliseconds to wait before force-killing cancelled commands." in
  Cmdliner.Arg.(
    value & opt (some string) None & info [ "kill-timeout" ] ~docv:"MS" ~doc)

let max_processes =
  let doc =
    "Maximum number of commands to run at once. Use an integer or a percentage \
     of detected CPUs, for example 50%."
  in
  Cmdliner.Arg.(
    value
    & opt (some string) None
    & info [ "m"; "max-processes" ] ~docv:"COUNT_OR_PERCENT" ~doc)

let restart_tries =
  let doc = "How many times a failed command should restart." in
  Cmdliner.Arg.(
    value & opt string "0" & info [ "restart-tries" ] ~docv:"COUNT" ~doc)

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

let command ~passthrough_argv_arguments ~deprecated_name_separator_used =
  let doc = "Run several shell commands and prefix their output." in
  let info =
    Cmdliner.Cmd.info "concurrentlyocaml" ~doc ~version:Version.current
  in
  Cmdliner.Cmd.v info
    Cmdliner.Term.(
      const (run ~passthrough_argv_arguments ~deprecated_name_separator_used)
      $ command_texts $ names $ name_separator $ timings $ group $ raw $ hide
      $ no_color $ passthrough_arguments $ handle_input $ default_input_target
      $ success $ prefix $ prefix_colors $ prefix_length $ timestamp_format
      $ pad_prefix $ kill_others $ kill_others_on_fail $ kill_signal
      $ kill_timeout $ max_processes $ restart_tries $ restart_after $ teardown)

let () =
  if Cli_argv.requests_help_before_separator Sys.argv then (
    print_string npm_compatible_help;
    exit 0);
  let cli_argv = Cli_argv.normalize Sys.argv in
  if Cli_argv.requests_help_before_separator cli_argv.Cli_argv.argv then (
    print_string npm_compatible_help;
    exit 0);
  if Cli_argv.requests_default_help cli_argv.Cli_argv.argv then (
    prerr_string npm_compatible_help;
    exit 0);
  let cmd =
    command ~passthrough_argv_arguments:cli_argv.Cli_argv.passthrough_arguments
      ~deprecated_name_separator_used:
        cli_argv.Cli_argv.deprecated_name_separator_used
  in
  exit (Cmdliner.Cmd.eval' ~argv:cli_argv.Cli_argv.argv cmd)
