open Unix
open ANSITerminal

let word_list = ref []
let commands = ref []
let spacious_mode = ref false
let benchmark_mode = ref false
let kill_others = ref false
let kill_others_on_fail = ref false
let kill_signal = ref "SIGTERM"


let speclist = [
  ("-n", Arg.String (fun s -> word_list := String.split_on_char ',' s), "List of words separated by commas");
  ("--spacious", Arg.Unit (fun () -> spacious_mode := true), "Enable spacious mode (adds new lines)");
  ("-sp", Arg.Unit (fun () -> spacious_mode := true), "Enable spacious mode (adds new lines)");
  ("-b", Arg.Set benchmark_mode, "Enable benchmark mode (tracks execution time)");
  ("--benchmark", Arg.Set benchmark_mode, "Enable benchmark mode (tracks execution time)");
  ("-k", Arg.Set kill_others, "Kill other processes if one exits or dies");
  ("--kill-others-on-fail", Arg.Set kill_others_on_fail, "Kill other processes if one exits with a non-zero status code");
  ("--kill-signal", Arg.String (fun s -> kill_signal := s), "Signal to send to other processes if one exits or dies (default: SIGTERM)");
]

let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " -n <word_list> <command1> <command2> ..."

let emojis = [" 🍕"; " 🌞"; " 🚗"; " 🌈"; " 🐱"; " 🌸"; " 🎈"; " 🍦"; " 📚"; " 🎸"; " 🏆"; " 🚀"; " 🍪"; " 🎃"; " 🏖 "; " 🎵 "] 

let split_string_by_space str =
  String.split_on_char ' ' str

let colorize str color =
  sprintf [ANSITerminal.Foreground color] str


let unified_pretty_print ?(format_out=[]) ?(error_out=[]) ?(tag="") ?(color="default") lines =
  let prefix_char = colorize "| " color in
  let newline = if !spacious_mode || !benchmark_mode || List.length format_out > 0 then "\n" else "" in

  match lines with
  | [] -> ""
  | first_line :: rest_lines ->
    let first_formatted_line =
      if !spacious_mode || !benchmark_mode then
        Printf.sprintf "%s%s" prefix_char first_line
      else
        first_line
    in

    let formatted_lines =
      if !spacious_mode || !benchmark_mode || List.length rest_lines > 0 then
        List.map (fun line -> Printf.sprintf "%s%s" prefix_char line) rest_lines
      else
        List.map (fun line -> line) rest_lines
    in

    let first_line_prefix =
      if !spacious_mode || !benchmark_mode || List.length rest_lines > 0 then "\n" else ""
    in

    let formatted_output = String.concat first_line_prefix (first_formatted_line :: formatted_lines) in

    if List.length format_out > 0 then
      Printf.sprintf "%s%s%s:%s%s\n" newline prefix_char tag newline (String.concat newline format_out)
    else if List.length error_out > 0 then
      Printf.sprintf "%s%s%s:%s%s\n" newline prefix_char tag newline (String.concat newline error_out)
    else
      Printf.sprintf "%s" formatted_output
  
  

let pretty_print _ lines color =
  let prefix_char = colorize "| " color in
  match lines with
  | [] -> ""
  | first_line :: rest_lines ->
    let first_formatted_line = if !spacious_mode || !benchmark_mode  then
      if List.length rest_lines > 0 then 
        Printf.sprintf "%s%s" prefix_char first_line
      else
        Printf.sprintf "%s%s" prefix_char first_line
    else
      first_line
    in
    let formatted_lines =
      if !spacious_mode || !benchmark_mode || List.length rest_lines > 0 then
        List.map (fun line -> Printf.sprintf "%s%s" prefix_char line) rest_lines
      else
        List.map (fun line -> line) rest_lines
    in
    let first_line_prefix = if !spacious_mode || !benchmark_mode || List.length rest_lines > 0 then "\n" else "" in
    String.concat first_line_prefix (first_formatted_line :: formatted_lines)
  
  

let print_out format_out error_out tag color =
  let prefix_char = colorize "| " color in
  let newline = if !spacious_mode || !benchmark_mode || String.length format_out > 0 then "\n" else "" in
  if String.length format_out > 0 then
    Printf.printf "%s%s%s:%s%s\n" newline prefix_char tag newline format_out
  else
    Printf.printf "%s%s%s:%s%s\n" newline prefix_char tag newline error_out

let format_time elapsed_time =
  if elapsed_time >= 1.0 then
    let seconds = int_of_float elapsed_time in
    let milliseconds = int_of_float ((elapsed_time -. float_of_int seconds) *. 1000.0) in
    Printf.sprintf "%d,%d sec" seconds milliseconds
  else
    let milliseconds = int_of_float (elapsed_time *. 1000.0) in
    let nanoseconds = int_of_float ((elapsed_time *. 1000.0 *. 1000.0) -. (float_of_int milliseconds) *. 1000.0) in
    let rounded_nanoseconds = (nanoseconds + 5) / 10 in
    let milliseconds =
      if rounded_nanoseconds >= 100 then
        milliseconds + 1
      else
        milliseconds
    in
    Printf.sprintf "%d,%02d ms" milliseconds rounded_nanoseconds
  

let format_to_grey str =
  sprintf [ANSITerminal.Foreground ANSITerminal.Black] "%s" str

let get_color error_lines =
  let has_error = not (List.length error_lines = 0) in
  if has_error then
    ANSITerminal.Red
  else
    ANSITerminal.Green
    
let generate_tag tag elapsed_time =
  if !benchmark_mode then
    let time_str = format_time elapsed_time in
    Printf.sprintf "[%s] %s" tag (format_to_grey time_str) 
  else
    Printf.sprintf "[%s]" tag

let execute_command tag cmd =
  let start_time = Unix.gettimeofday () in
  let (in_channel, out_channel, err_channel) = Unix.open_process_full cmd (Unix.environment ()) in
  let rec read_lines channel lines =
    try
      let line = input_line channel in
      read_lines channel (line :: lines)
    with
    | End_of_file -> lines
  in

  let output_lines = read_lines in_channel [] in
  let error_lines = read_lines err_channel [] in

  let end_time = Unix.gettimeofday () in
  let elapsed_time = end_time -. start_time in

  let new_tag = generate_tag tag elapsed_time in

  let time_str = format_time elapsed_time in


  let format_out = pretty_print time_str output_lines ANSITerminal.Green in
  let error_out = pretty_print time_str error_lines ANSITerminal.Red in

  let color = get_color error_lines in

  let formatted_output = unified_pretty_print ~format_out:"Additional Info" ~tag:tag lines color in

  (* If you want to print it to the console, you can do so like this: *)
  Printf.printf "%s" formatted_output;

  let exit_code = Unix.close_process_full (in_channel, out_channel, err_channel) in
  match exit_code with
  | WEXITED code -> exit code
  | _ -> exit 1

let select_random_emoji () =
  let index = Random.int (List.length emojis) in
  List.nth emojis index

let generate_word_list count =
  let rec generate_words n acc =
    if n <= 0 then acc
    else
      generate_words (n - 1) (select_random_emoji () :: acc)
  in
  generate_words count []

  let create_child_process word cmd =
    let pid = Unix.fork () in
    if pid = 0 then (* Child process *)
      let exit_code = execute_command word cmd in
      exit exit_code
    else (* Parent process *)
      pid
  
let rec execute_commands_and_track_failures words cmds failures successes =
  match words, cmds with
  | [], [] -> (failures, successes)
  | _, [] | [], _ -> (failures, successes)
  | word :: rest_words, cmd :: rest_cmds ->
    let pid = create_child_process word cmd in
    match Unix.waitpid [] pid with
    | _, WEXITED 1 -> execute_commands_and_track_failures rest_words rest_cmds (failures + 1) successes
    | _, WEXITED _ -> execute_commands_and_track_failures rest_words rest_cmds failures (successes + 1)
    | _, WSIGNALED _ | _, WSTOPPED _ -> execute_commands_and_track_failures rest_words rest_cmds (failures + 1) successes

let handle_kill_signal signal pids =
List.iter (fun pid -> Unix.kill signal pid) pids

let main () =
Arg.parse speclist (fun arg -> commands := !commands @ [arg]) usage_msg;

let word_list_length = List.length !word_list in

if word_list_length > 0 && word_list_length <> List.length !commands then
  begin
    Printf.printf "Error: Number of words and commands must match.\n";
    exit 1
  end;

if word_list_length = 0 then
  begin
    Random.self_init ();  (* Seed the random number generator *)
    word_list := generate_word_list (List.length !commands);
  end;

let child_processes = ref [] in
let (failures, _) = execute_commands_and_track_failures !word_list !commands 0 0 in

(* if failures > 0  then
  Printf.printf "Some commands failed.\n"
else
  Printf.printf "All commands succeeded.\n"; *)

if !kill_others || !kill_others_on_fail then
  begin
    let sig_to_send =
      match !kill_signal with
      | "SIGTERM" -> 15
      | "SIGKILL" -> 9
      | _ -> failwith "Invalid signal"
    in
    handle_kill_signal sig_to_send !child_processes;
  end;

exit (if failures > 0 then 1 else 0)

let () =
  main ()