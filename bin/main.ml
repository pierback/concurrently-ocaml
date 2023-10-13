open Unix

let word_list = ref []
let commands = ref []

let speclist = [
  ("-n", Arg.String (fun s -> word_list := String.split_on_char ',' s), "List of words separated by commas");
]
let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " -n <word_list> <command1> <command2> ..."

let split_string_by_space str =
  String.split_on_char ' ' str

let pretty_print input_tag error_message =
  let lines = String.split_on_char '\n' error_message in
  let formatted_lines = List.map (fun line ->
    let prefix = String.make (String.length input_tag + 4) ' ' in
    Printf.sprintf "%s%s" prefix line
  ) lines in
  String.concat "\n" formatted_lines

let execute_command tag cmd =
  
  Eio_main.run @@ fun env ->
    
    try
      let proc_mgr = Eio.Stdenv.process_mgr env in

      let output = Eio.Switch.run @@ fun sw ->
        let r, w = Eio.Process.pipe proc_mgr ~sw in
        try
          let child = Eio.Process.spawn ~sw proc_mgr ~stderr:w cmd
          in
          (* let child = Eio.Process.spawn ~sw cmd ~stdout:w ~stderr:w in *)
          Eio.Flow.close w;
          let output = Eio.Buf_read.parse_exn Eio.Buf_read.take_all r ~max_size:max_int in
          Eio.Flow.close r;
          Eio.Process.await_exn child;
          
          pretty_print tag output
        with Eio.Exn.Io _ as ex ->
          let error_message = (Printexc.to_string ex) in
          pretty_print tag error_message
        in

      (* let output = Eio.Process.parse_out proc_mgr Eio.Buf_read.take_all cmd in *)

        (* 
        | `Exited code when is_success code -> ()
        | status ->
          let exn = Eio.Process.err (Eio.Process.Child_error status) in
          Printf.printf "[%s]: \n%s\n" tag (Printexc.to_string exn);
          exit 0 
        *)
        Printf.printf "suc[%s]: %s\n" tag output;

        exit 0
    with
      | exn ->
        Printf.printf "bad \n";
        let asdf = (Printexc.to_string exn) in
        let output = pretty_print tag asdf in
        Printf.printf "[%s]: %s\n" tag output;
        exit 0


(* let execute_command1 tag cmd =
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
  | _ -> exit 1 Exit with a non-zero code if there's an error *)

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
      | WEXITED _ -> ()
        (* Printf.printf "Child process for '%s' exited with code %d\n" word exit_code *)
      | WSIGNALED _ -> ()
        (* Printf.printf "Child process for '%s' was killed by signal %d\n" word signal *)
      | WSTOPPED _ -> ()
        (* Printf.printf "Child process for '%s' was stopped by signal %d\n" word signal *)
  in
  
  
  process_words_and_commands !word_list !commands