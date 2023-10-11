open Unix

let word_list = ref []
let commands = ref []

let speclist = [
  ("-n", Arg.String (fun s -> word_list := String.split_on_char ',' s), "List of words separated by commas");
]
let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " -n <word_list> <command1> <command2> ..."

let split_string_by_space str =
  String.split_on_char ' ' str

let execute_command tag cmd =
  Eio_main.run @@ fun env ->
    try
      let proc_mgr = Eio.Stdenv.process_mgr env in
      let output = Eio.Process.parse_out proc_mgr Eio.Buf_read.line cmd in

      Printf.printf "[%s]: %s\n" tag output;
      exit 0 
    with
      | exn ->
        Printf.printf "[%s]: \n%s\n" tag (Printexc.to_string exn);
        exit 0


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
      let pid = Unix.fork () in
      if pid = 0 then (* Child process *)
        let cmd_list = split_string_by_space cmd in
        let exit_code = execute_command word cmd_list in
        exit exit_code
      else (* Parent process *)
        process_words_and_commands rest_words rest_cmds;
  
      (* Wait for the child process to finish *)
      let (_, status) = Unix.waitpid [] pid in
      match status with
      | WEXITED exit_code -> ()
        (* Printf.printf "Child process for '%s' exited with code %d\n" word exit_code *)
      | WSIGNALED signal -> ()
        (* Printf.printf "Child process for '%s' was killed by signal %d\n" word signal *)
      | WSTOPPED signal -> ()
        (* Printf.printf "Child process for '%s' was stopped by signal %d\n" word signal *)
  in
  
  
  process_words_and_commands !word_list !commands