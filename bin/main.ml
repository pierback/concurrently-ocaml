open Unix

let word_list = ref []
let commands = ref []

let speclist = [
  ("-n", Arg.String (fun s -> word_list := String.split_on_char ',' s), "List of words separated by commas");
]
let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " -n <word_list> <command1> <command2> ..."

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
  if String.length format_out > 0 then
    Printf.printf "[%s]: %s\n" tag format_out 
  else
    Printf.printf "[%s]: %s\n" tag error_out 

let execute_command1 tag cmd =
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

  print_out format_out error_out tag;
  
  let exit_code = Unix.close_process_full (in_channel, out_channel, err_channel) in
  match exit_code with
  | WEXITED code -> exit code
  | _ -> exit 1

let () =
  Arg.parse speclist (fun arg -> commands := !commands @ [arg]) usage_msg;

  let rec process_words_and_commands words cmds =
    match words, cmds with
    | [], [] -> ()
    | _, [] | [], _ ->
      Printf.printf "Error: Number of words and commands must match.\n"
    | word :: rest_words, cmd :: rest_cmds ->
      let pid = Unix.fork () in
      if pid = 0 then (* Child process *)
        (* let cmd_list = split_string_by_space cmd in *)
        let exit_code = execute_command1 word cmd in
        exit exit_code
      else (* Parent process *)
        process_words_and_commands rest_words rest_cmds;
  
      (* Wait for the child process to finish *)
      let (_, status) = Unix.waitpid [] pid in
      match status with
      | WEXITED _ -> ()
        (* Printf.printf "Child process for '%s' exited with code %d\n" word exit_code *)
      | WSIGNALED _ -> ()
        (* Printf.printf "Child process for '%s' was killed by signal %d\n" word signal *)
      | WSTOPPED _ -> ()
        (* Printf.printf "Child process for '%s' was stopped by signal %d\n" word signal *)
  in
  
  
  process_words_and_commands !word_list !commands