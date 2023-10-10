open Unix

let word_list = ref []
let commands = ref []

let speclist = [
  ("-n", Arg.String (fun s -> word_list := String.split_on_char ',' s), "List of words separated by commas");
]

let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " -n <word_list> <command1> <command2> ..."

let split_string_by_space str =
  String.split_on_char ' ' str


  (* Define a custom sink for capturing output *)
module OutputSink = struct
  type t = Buffer.t

  let write t bufs =
    List.iter (fun buf -> Buffer.add_bytes t (Cstruct.to_bytes buf)) bufs
end

(* Create a custom resource handler for the output sink *)
let output_sink_handler = Pi.sink (module OutputSink)

let execute_command tag cmd =
  Eio_main.run @@ fun env ->
    try
      let proc_mgr = Eio.Stdenv.process_mgr env in

      (* Create a buffer to capture the output *)
      let output_buffer = Buffer.create 1024 in

      (* Create a sink using the custom output_sink_handler *)
      let output_sink = Eio.Flow.sink output_sink_handler output_buffer in

      (* Spawn the process and redirect its output to the custom sink *)
      Eio.Process.spawn proc_mgr ~stdout:output_sink cmd;

      (* Wait for the process to finish *)
      let exit_code = Eio.Process.wait proc_mgr in

      (* Print the captured output (stdout and stderr) *)
      Printf.printf "[%s] Process exited with code: %d\n" tag exit_code;
      Printf.printf "[%s] Output:\n%s\n" tag (Buffer.contents output_buffer);

      exit exit_code
    with
      | exn ->
        Printf.printf "[%s]: \n%s\n" tag (Printexc.to_string exn);
        exit 0

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