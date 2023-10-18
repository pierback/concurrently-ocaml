open Unix

let word_list = ref []
let commands = ref []
let spacious_mode = ref false

let benchmark_mode = ref false

let speclist = [
  ("-n", Arg.String (fun s -> word_list := String.split_on_char ',' s), "List of words separated by commas");
  ("--spacious", Arg.Unit (fun () -> spacious_mode := true), "Enable spacious mode (adds new lines)");
  ("-sp", Arg.Unit (fun () -> spacious_mode := true), "Enable spacious mode (adds new lines)");
  ("-b", Arg.Set benchmark_mode, "Enable benchmark mode (tracks execution time)");
  ("--benchmark", Arg.Set benchmark_mode, "Enable benchmark mode (tracks execution time)");
]

let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " -n <word_list> <command1> <command2> ..."

let emojis = [" 🍕"; " 🌞"; " 🚗"; " 🌈"; " 🐱"; " 🌸"; " 🎈"; " 🍦"; " 📚"; " 🎸"; " 🏆"; " 🚀"; " 🍪"; " 🎃"; " 🏖 "; " 🎵 "] 

let split_string_by_space str =
  String.split_on_char ' ' str

let pretty_print input_tag lines =
  match lines with
  | [] -> "" 
  | first_line :: rest_lines ->
    let first_formatted_line = first_line in
    let formatted_lines = List.map (fun line ->
      let prefix = String.make (String.length input_tag + 4) ' ' in
      Printf.sprintf "%s%s" prefix line
    ) rest_lines in
    String.concat "\n" (first_formatted_line :: formatted_lines)

let print_out format_out error_out tag =
  let newline = if !spacious_mode then "\n" else "" in
  if String.length format_out > 0 then
    Printf.printf "%s[%s]: %s\n" newline tag format_out
  else
    Printf.printf "%s[%s]: %s\n" newline tag error_out

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
  
let generate_tag tag elapsed_time =
  if !benchmark_mode then
    let time_str = format_time elapsed_time in
    Printf.sprintf "tag: %s | time: %s" tag time_str
  else
    Printf.sprintf "%s" tag

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

  let format_out = pretty_print tag output_lines in
  let error_out = pretty_print tag error_lines in

  let end_time = Unix.gettimeofday () in
  let elapsed_time = end_time -. start_time in

  let new_tag = generate_tag tag elapsed_time in

  print_out format_out error_out new_tag;

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

let () =
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

  let rec process_words_and_commands words cmds =
    match words, cmds with
    | [], [] -> ()
    | _, [] | [], _ -> ()
    | word :: rest_words, cmd :: rest_cmds ->
      let pid = Unix.fork () in
      if pid = 0 then (* Child process *)
        let exit_code = execute_command word cmd in
        exit exit_code
      else (* Parent process *)
        process_words_and_commands rest_words rest_cmds;
        let (_, status) = Unix.waitpid [] pid in
      match status with
      | WEXITED _ -> ()
      | WSIGNALED _ -> ()
      | WSTOPPED _ -> ()
  in

  process_words_and_commands !word_list !commands