open Unix

let word_list = ref []
let commands = ref []



let speclist = [
  ("-n", Arg.String (fun s -> word_list := String.split_on_char ',' s), "List of words separated by commas");
]

let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " -n <word_list> <command1> <command2> ..."

let execute_command tag cmd =
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
  let () =
    List.iter (fun line -> Printf.printf "[%s] %s\n" tag line) output_lines;
    List.iter (fun line -> Printf.eprintf "[%s] Error: %s\n" tag line) error_lines;
  in
  let exit_code = Unix.close_process_full (in_channel, out_channel, err_channel) in
  match exit_code with
  | WEXITED code -> exit code
  | _ -> exit 1 (* Exit with a non-zero code if there's an error *)

let () =
  Arg.parse speclist (fun arg -> commands := !commands @ [arg]) usage_msg;
  
  let rec process_words_and_commands words cmds =
    match words, cmds with
    | [], [] -> ()
    | _, [] | [], _ ->
      Printf.printf "Error: Number of words and commands must match.\n"
    | word :: rest_words, cmd :: rest_cmds ->
      (* Printf.printf "Word: %s, Command: %s\n" word cmd; *)
      let pid = Unix.fork () in
      if pid = 0 then (* Child process *)
        let exit_code = execute_command word cmd in
        exit exit_code
      else (* Parent process *)
        process_words_and_commands rest_words rest_cmds
  in
  
  process_words_and_commands !word_list !commands
