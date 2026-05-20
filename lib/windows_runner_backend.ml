[@@@alert "-unstable"]

open Concurrentlyocaml

type native_process =
  { process_id : int
  ; process_handle : nativeint
  ; job_handle : nativeint
  }

external create_process :
  string ->
  string ->
  string option ->
  string array ->
  Unix.file_descr ->
  Unix.file_descr ->
  Unix.file_descr ->
  int * nativeint * nativeint = "concurrently_windows_create_process_bytecode"
  "concurrently_windows_create_process"

external await_exit_code : nativeint -> int = "concurrently_windows_await"

external terminate_job :
  nativeint -> int -> unit = "concurrently_windows_terminate_job"

external close_handle : nativeint -> unit = "concurrently_windows_close_handle"

let split_env_entry entry =
  let separator_start =
    if String.length entry > 0 && entry.[0] = '=' then 1 else 0
  in
  let separator =
    if separator_start >= String.length entry then None
    else String.index_from_opt entry separator_start '='
  in
  match separator with
  | None -> entry, ""
  | Some separator ->
      ( String.sub entry 0 separator
      , String.sub entry (separator + 1) (String.length entry - separator - 1)
      )

let env_key key = String.uppercase_ascii key

let command_env command =
  let env_by_key = Hashtbl.create 64 in
  let put key value = Hashtbl.replace env_by_key (env_key key) (key, value) in
  Unix.environment ()
  |> Array.iter (fun entry ->
         let key, value = split_env_entry entry in
         put key value);
  Command.env command |> List.iter (fun (key, value) -> put key value);
  env_by_key |> Hashtbl.to_seq_values
  |> List.of_seq
  |> List.sort (fun (left_key, _) (right_key, _) ->
         String.compare (env_key left_key) (env_key right_key))
  |> List.map (fun (key, value) -> key ^ "=" ^ value)
  |> Array.of_list

let env_value name env =
  let name = env_key name in
  env
  |> Array.find_opt (fun entry ->
         let key, _value = split_env_entry entry in
         env_key key = name)
  |> Option.map (fun entry -> snd (split_env_entry entry))

let shell_path env =
  match env_value "ComSpec" env with
  | Some path when String.trim path <> "" -> path
  | Some _ | None -> "cmd.exe"

let close_process_handles native_process =
  close_handle native_process.process_handle;
  close_handle native_process.job_handle

(* Eio_windows exposes Eio_unix.Stdenv.base on Win32 and handles these pipe
   effects in the Windows event loop. Keeping the resources as Eio_unix file
   descriptors lets the Win32 stubs inherit the underlying HANDLE values. *)
let with_file_descriptors stdin_source stdout_sink stderr_sink spawn =
  let stdin_fd = Eio_unix.Resource.fd stdin_source in
  let stdout_fd = Eio_unix.Resource.fd stdout_sink in
  let stderr_fd = Eio_unix.Resource.fd stderr_sink in
  Eio_unix.Fd.use_exn_list "CreateProcessW"
    [ stdin_fd; stdout_fd; stderr_fd ]
    (function
      | [ stdin_fd; stdout_fd; stderr_fd ] ->
          spawn ~stdin_fd ~stdout_fd ~stderr_fd
      | _ -> assert false)

let spawn_native ~stdin_source ~stdout_sink ~stderr_sink command =
  let env = command_env command in
  let shell_path = shell_path env in
  let command_line =
    Windows_command_line.shell_command_line ~shell_path
      ~command_text:(Command.text command)
  in
  with_file_descriptors stdin_source stdout_sink stderr_sink
    (fun ~stdin_fd ~stdout_fd ~stderr_fd ->
      let process_id, process_handle, job_handle =
        create_process shell_path command_line (Command.cwd command) env
          stdin_fd stdout_fd stderr_fd
      in
      { process_id; process_handle; job_handle })

let spawn ~sw ~command =
  let stdin_source, stdin_sink = Eio_unix.pipe sw in
  let stdout_source, stdout_sink = Eio_unix.pipe sw in
  let stderr_source, stderr_sink = Eio_unix.pipe sw in
  let close_child_sources () = Eio.Flow.close stdin_source in
  let close_child_sinks () =
    Eio.Flow.close stdout_sink;
    Eio.Flow.close stderr_sink
  in
  match spawn_native ~stdin_source ~stdout_sink ~stderr_sink command with
  | native_process ->
      let exit_status, resolve_exit_status = Eio.Promise.create () in
      let closed = ref false in
      let close_handles_once () =
        if not !closed then (
          closed := true;
          close_process_handles native_process)
      in
      let terminate_job exit_code = terminate_job native_process.job_handle exit_code in
      let _cleanup_hook =
        Eio.Switch.on_release_cancellable sw (fun () ->
            if not (Eio.Promise.is_resolved exit_status) then
              (try terminate_job 1 with _ -> ());
            close_handles_once ())
      in
      close_child_sources ();
      close_child_sinks ();
      let signal signal =
        if Eio.Promise.is_resolved exit_status then Ok false
        else
          try
            terminate_job (128 + Sys.signal_to_int signal);
            Ok true
          with exn -> Error (Printexc.to_string exn)
      in
      { Runner_backend.process_id = string_of_int native_process.process_id
      ; write_stdin = (fun input -> Eio.Flow.copy_string input stdin_sink)
      ; close_stdin = (fun () -> Eio.Flow.close stdin_sink)
      ; stdout = (stdout_source :> Runner_backend.source)
      ; stderr = (stderr_source :> Runner_backend.source)
      ; signal
      ; await =
          (fun () ->
            let exit_code =
              Eio_unix.run_in_systhread ~label:"windows-await-process"
                (fun () -> await_exit_code native_process.process_handle)
            in
            ignore
              (Eio.Promise.try_resolve resolve_exit_status
                 (Close_event.Exited exit_code));
            close_handles_once ();
            Close_event.Exited exit_code)
      }
  | exception exn ->
      close_child_sources ();
      Eio.Flow.close stdin_sink;
      close_child_sinks ();
      raise exn

let backend = { Runner_backend.spawn }
