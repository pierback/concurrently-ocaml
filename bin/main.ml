module Cli_config = Concurrentlyocaml.Cli_config
module Output_event = Concurrentlyocaml.Output_event
module Output_formatter = Concurrentlyocaml.Output_formatter
module Posix_runner_backend = Concurrentlyocaml.Posix_runner_backend
module Runner = Concurrentlyocaml.Runner
module Runner_backend = Concurrentlyocaml.Runner_backend
module Native_api_json = Concurrentlyocaml.Native_api_json
module Version = Concurrentlyocaml.Version

let passthrough_argv_arguments = ref []
let deprecated_name_separator_used = ref false
let api_close_events_file_argument = ref None
let api_output_events_fd_argument = ref None
let api_command_name_arguments = ref []
let api_command_cwd_arguments = ref []
let api_command_env_arguments = ref []
let api_command_raw_arguments = ref []
let api_argument_error = ref None

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

let write_api_close_events close_events_file result =
  try
    let channel = open_out close_events_file in
    Fun.protect
      ~finally:(fun () -> close_out channel)
      (fun () ->
        output_string
          channel
          (Native_api_json.close_events_json
             (Concurrentlyocaml.Run_result.close_events result));
        flush channel);
    Ok ()
  with
  | exn -> Error (Printexc.to_string exn)

let write_empty_api_close_events close_events_file =
  try
    let channel = open_out close_events_file in
    Fun.protect
      ~finally:(fun () -> close_out channel)
      (fun () ->
        output_string channel "[]\n";
        flush channel);
    Ok ()
  with
  | exn -> Error (Printexc.to_string exn)

let print_deprecation_warnings () =
  if !deprecated_name_separator_used then
    prerr_endline
      "[concurrently] name-separator is deprecated. Use commas as name \
       separators instead."

let open_api_output_events_channel = function
  | None -> None
  | Some fd ->
    assert (fd >= 3);
    open_out (Printf.sprintf "/dev/fd/%d" fd) |> Option.some

let write_api_output_event channel event =
  match Native_api_json.output_event_json ~observed_at:(Unix.gettimeofday ()) event with
  | None -> ()
  | Some json ->
    output_string channel json;
    output_char channel '\n';
    flush channel

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

let run_config env api_close_events_file api_output_events_fd config =
  if Cli_config.is_no_op config then
    match api_close_events_file with
    | None -> 0
    | Some close_events_file ->
      (match write_empty_api_close_events close_events_file with
       | Ok () -> 0
       | Error error ->
         Printf.eprintf "Error: failed to write API close events: %s\n" error;
         1)
  else
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
    ; group = display.Cli_config.group
    ; raw = display.Cli_config.raw
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
  let api_output_events_channel =
    open_api_output_events_channel api_output_events_fd
  in
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
           (fun event ->
             (match api_output_events_channel with
              | None -> ()
              | Some channel -> write_api_output_event channel event);
             Output_formatter.handle_event formatter event |> print_outputs)
     with
     | Ok result ->
       let exit_code = Concurrentlyocaml.Run_result.exit_code result in
       (match api_close_events_file with
        | None -> exit_code
        | Some close_events_file ->
          (match write_api_close_events close_events_file result with
           | Ok () -> exit_code
           | Error error ->
             Printf.eprintf "Error: failed to write API close events: %s\n" error;
             1))
     | Error error ->
       Printf.eprintf "Error: %s\n" (Runner.error_message error);
       1)

let run command_texts names_csv name_separator spacious timings group raw hide_csv
    no_color cwd passthrough_arguments handle_input default_input_target success
    prefix prefix_colors_csv prefix_length timestamp_format pad_prefix
    kill_others kill_others_on_fail kill_signal kill_timeout_ms max_processes
    restart_tries restart_after teardown_texts =
  match !api_argument_error with
  | Some error ->
    Printf.eprintf "Error: %s\n" error;
    1
  | None ->
    (match
       Cli_config.create
         ~api_command_names:(List.rev !api_command_name_arguments)
         ~api_command_cwds:(List.rev !api_command_cwd_arguments)
         ~api_command_envs:(List.rev !api_command_env_arguments)
         ~api_command_raws:(List.rev !api_command_raw_arguments)
         ~cwd
         ~passthrough_arguments:
           (if passthrough_arguments then Some !passthrough_argv_arguments else None)
         ~teardown_texts
         ~command_texts
         ~names_csv
         ~name_separator
         ~spacious
         ~timings
         ~group
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
     | Ok config ->
       print_deprecation_warnings ();
       Eio_main.run (fun env ->
         run_config
           env
           !api_close_events_file_argument
           !api_output_events_fd_argument
           config))

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

let group =
  let doc = "Order output as if commands were run sequentially." in
  Cmdliner.Arg.(value & flag & info [ "g"; "group" ] ~doc)

let raw =
  let doc = "Output only raw command output, without prefixes or colors." in
  Cmdliner.Arg.(value & flag & info [ "r"; "raw" ] ~doc)

let hide =
  let doc = "Comma-separated command indexes or names whose output is hidden." in
  Cmdliner.Arg.(value & opt (some string) None & info [ "hide" ] ~docv:"COMMANDS" ~doc)

let no_color =
  let doc = "Disable ANSI colors in formatted output." in
  Cmdliner.Arg.(value & flag & info [ "no-color" ] ~doc)

let cwd =
  let doc = "Working directory for all commands and teardown commands." in
  Cmdliner.Arg.(
    value & opt (some string) None & info [ "cwd" ] ~docv:"DIR" ~doc)

let passthrough_arguments =
  let doc =
    "Pass arguments after -- through to commands by replacing {1}, {@}, and \
     {*} placeholders."
  in
  Cmdliner.Arg.(
    value & flag & info [ "P"; "passthrough-arguments" ] ~doc)

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
  let info = Cmdliner.Cmd.info "concurrentlyocaml" ~doc ~version:Version.current in
  Cmdliner.Cmd.v
    info
    Cmdliner.Term.(
      const run
      $ command_texts
      $ names
      $ name_separator
      $ spacious
      $ timings
      $ group
      $ raw
      $ hide
      $ no_color
      $ cwd
      $ passthrough_arguments
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

let is_passthrough_flag argument =
  argument = "-P" || argument = "--passthrough-arguments"

let option_consumes_value = function
  | "-n" | "--names" | "--name-separator" | "--hide" | "--cwd"
  | "--default-input-target" | "-s" | "--success" | "-p" | "--prefix"
  | "-c" | "--prefix-colors" | "-l" | "--prefix-length" | "-t"
  | "--timestamp-format" | "--kill-signal" | "--ks" | "--kill-timeout"
  | "-m" | "--max-processes" | "--restart-tries" | "--restart-after"
  | "--teardown" ->
    true
  | _ -> false

let argument_has_prefix ~prefix argument =
  let prefix_length = String.length prefix in
  String.length argument >= prefix_length
  && String.sub argument 0 prefix_length = prefix

let option_has_inline_value argument =
  String.length argument > 2
  && argument.[0] = '-'
  && argument.[1] = '-'
  && String.contains argument '='

let normalize_spacious_argv argv =
  let argv = Array.copy argv in
  let after_command_separator = ref false in
  Array.iteri
    (fun index argument ->
      if index > 0 && not !after_command_separator then
        if argument = "--" then after_command_separator := true
        else if argument = "-sp" then argv.(index) <- "--sp")
    argv;
  argv

let normalize_builtin_aliases_argv argv =
  let argv = Array.copy argv in
  let after_command_separator = ref false in
  Array.iteri
    (fun index argument ->
      if index > 0 && not !after_command_separator then
        if argument = "--" then after_command_separator := true
        (* yargs handles these built-in aliases before this package binds
           separate option values, so `--prefix -v` prints the version while
           `--prefix=-v` remains the way to pass a dash-prefixed value. *)
        else if argument = "-h" then argv.(index) <- "--help"
        else if argument = "-v" || argument = "-V" then argv.(index) <- "--version")
    argv;
  argv

let argv_requests_help_before_separator argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then false
    else
      let argument = argv.(index) in
      if
        argument = "-h"
        || argument = "--help"
        || argument_has_prefix ~prefix:"--help=" argument
      then true
      else if option_consumes_value argument then loop (index + 2)
      else loop (index + 1)
  in
  loop 1

let api_option_value ~name argv index =
  let prefix = name ^ "=" in
  let argument = argv.(index) in
  if argument = name then
    if index + 1 >= Array.length argv then `Missing
    else `Separate (argv.(index + 1))
  else if
    String.length argument >= String.length prefix
    && String.sub argument 0 (String.length prefix) = prefix
  then
    `Inline (String.sub argument (String.length prefix) (String.length argument - String.length prefix))
  else `No_match

let set_api_output_events_fd value =
  match int_of_string_opt value with
  | Some fd when fd >= 3 -> api_output_events_fd_argument := Some fd
  | Some _ | None ->
    api_argument_error :=
      Some "invalid value for --api-output-events-fd; expected fd >= 3"

let extract_internal_api_arguments argv =
  let rec loop index normalized =
    if index >= Array.length argv then Array.of_list (List.rev normalized)
    else if argv.(index) = "--" then
      let tail_count = Array.length argv - index in
      let tail = List.init tail_count (fun offset -> argv.(index + offset)) in
      Array.of_list (List.rev_append normalized tail)
    else
      match api_option_value ~name:"--api-close-events-file" argv index with
      | `Inline value ->
        api_close_events_file_argument := Some value;
        loop (index + 1) normalized
      | `Separate value ->
        api_close_events_file_argument := Some value;
        loop (index + 2) normalized
      | `Missing ->
        api_argument_error := Some "missing value for --api-close-events-file";
        loop (index + 1) normalized
      | `No_match ->
        (match api_option_value ~name:"--api-output-events-fd" argv index with
         | `Inline value ->
           set_api_output_events_fd value;
           loop (index + 1) normalized
         | `Separate value ->
           set_api_output_events_fd value;
           loop (index + 2) normalized
         | `Missing ->
           api_argument_error := Some "missing value for --api-output-events-fd";
           loop (index + 1) normalized
         | `No_match ->
        (match api_option_value ~name:"--api-command-name" argv index with
         | `Inline value ->
           api_command_name_arguments := value :: !api_command_name_arguments;
           loop (index + 1) normalized
         | `Separate value ->
           api_command_name_arguments := value :: !api_command_name_arguments;
           loop (index + 2) normalized
         | `Missing ->
           api_argument_error := Some "missing value for --api-command-name";
           loop (index + 1) normalized
         | `No_match ->
        (match api_option_value ~name:"--api-command-cwd" argv index with
         | `Inline value ->
           api_command_cwd_arguments := value :: !api_command_cwd_arguments;
           loop (index + 1) normalized
         | `Separate value ->
           api_command_cwd_arguments := value :: !api_command_cwd_arguments;
           loop (index + 2) normalized
         | `Missing ->
           api_argument_error := Some "missing value for --api-command-cwd";
           loop (index + 1) normalized
         | `No_match ->
           (match api_option_value ~name:"--api-command-env" argv index with
            | `Inline value ->
              api_command_env_arguments := value :: !api_command_env_arguments;
              loop (index + 1) normalized
            | `Separate value ->
              api_command_env_arguments := value :: !api_command_env_arguments;
              loop (index + 2) normalized
            | `Missing ->
              api_argument_error := Some "missing value for --api-command-env";
              loop (index + 1) normalized
            | `No_match ->
              (match api_option_value ~name:"--api-command-raw" argv index with
               | `Inline value ->
                 api_command_raw_arguments := value :: !api_command_raw_arguments;
                 loop (index + 1) normalized
               | `Separate value ->
                 api_command_raw_arguments := value :: !api_command_raw_arguments;
                 loop (index + 2) normalized
               | `Missing ->
                 api_argument_error := Some "missing value for --api-command-raw";
                 loop (index + 1) normalized
               | `No_match -> loop (index + 1) (argv.(index) :: normalized))))))
  in
  loop 0 []

let argv_contains_passthrough_flag_before_separator argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then false
    else
      let argument = argv.(index) in
      if option_consumes_value argument then
        is_passthrough_flag argument || loop (index + 2)
      else if option_has_inline_value argument then loop (index + 1)
      else is_passthrough_flag argument || loop (index + 1)
  in
  loop 1

let has_command_argument_before_separator argv separator_index =
  let rec loop index =
    if index >= separator_index then false
    else
      let argument = argv.(index) in
      if option_consumes_value argument then loop (index + 2)
      else if
        is_passthrough_flag argument
        || option_has_inline_value argument
        || (String.length argument > 0 && argument.[0] = '-')
      then loop (index + 1)
      else true
  in
  loop 1

let extract_passthrough_arguments argv =
  if not (argv_contains_passthrough_flag_before_separator argv) then argv
  else
    let rec find_separator index =
      if index = Array.length argv then None
      else if argv.(index) = "--" then Some index
      else find_separator (index + 1)
    in
    let separator_index =
      match find_separator 1 with
      | Some first_separator
        when not (has_command_argument_before_separator argv first_separator) ->
        find_separator (first_separator + 1)
      | first_separator -> first_separator
    in
    match separator_index with
    | None -> argv
    | Some separator_index ->
      let additional_count = Array.length argv - separator_index - 1 in
      passthrough_argv_arguments :=
        List.init additional_count (fun offset ->
          argv.(separator_index + offset + 1));
      Array.sub argv 0 separator_index

let is_name_separator_argument argument =
  argument = "--name-separator"
  || argument_has_prefix ~prefix:"--name-separator=" argument

let record_deprecated_name_separator argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then ()
    else (
      if is_name_separator_argument argv.(index) then
        deprecated_name_separator_used := true;
      loop (index + 1))
  in
  loop 1;
  argv

let is_negative_int_argument argument =
  String.length argument > 1
  && argument.[0] = '-'
  &&
  match int_of_string_opt argument with
  | Some value -> value < 0
  | None -> false

let normalize_restart_tries_argv argv =
  let rec loop index normalized =
    if index >= Array.length argv then Array.of_list (List.rev normalized)
    else if argv.(index) = "--" then
      let tail_count = Array.length argv - index in
      let tail = List.init tail_count (fun offset -> argv.(index + offset)) in
      Array.of_list (List.rev_append normalized tail)
    else if
      argv.(index) = "--restart-tries"
      && index + 1 < Array.length argv
      && is_negative_int_argument argv.(index + 1)
    then
      loop
        (index + 2)
        (("--restart-tries=" ^ argv.(index + 1)) :: normalized)
    else loop (index + 1) (argv.(index) :: normalized)
  in
  loop 0 []

let () =
  if argv_requests_help_before_separator Sys.argv then (
    print_string npm_compatible_help;
    exit 0);
  let argv =
    normalize_spacious_argv Sys.argv
    |> normalize_builtin_aliases_argv
    |> record_deprecated_name_separator
    |> extract_internal_api_arguments
    |> extract_passthrough_arguments
    |> normalize_restart_tries_argv
  in
  exit (Cmdliner.Cmd.eval' ~argv command)
