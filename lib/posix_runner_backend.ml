[@@@alert "-unstable"]

open Concurrentlyocaml

type native_process = { pid : int; exit_status : Unix.process_status Eio.Promise.t }

module Pipe = struct
  type source = [ Eio.Resource.close_ty | Eio.Flow.source_ty ] Eio.Resource.t
  type sink = [ Eio.Resource.close_ty | Eio.Flow.sink_ty ] Eio.Resource.t

  type pipe =
    { source : source
    ; sink : sink
    ; read_fd : Eio_unix.Fd.t
    ; write_fd : Eio_unix.Fd.t
    }

  let create ~sw =
    let source, sink = Eio_unix.pipe sw in
    { source = (source :> source)
    ; sink = (sink :> sink)
    ; read_fd = Eio_unix.Resource.fd source
    ; write_fd = Eio_unix.Resource.fd sink
    }
end

let shell_args command = [ "/bin/sh"; "-c"; Command.text command ]

let close_status = function
  | Unix.WEXITED code -> Close_event.Exited code
  | Unix.WSIGNALED signal ->
      Close_event.Signaled (string_of_int (Sys.signal_to_int signal))
  | Unix.WSTOPPED signal ->
      Close_event.Signaled ("STOP:" ^ string_of_int (Sys.signal_to_int signal))

let split_env_entry entry =
  match String.index_opt entry '=' with
  | None -> entry, ""
  | Some separator ->
    ( String.sub entry 0 separator
    , String.sub entry (separator + 1) (String.length entry - separator - 1) )

let command_env command =
  let env_by_key = Hashtbl.create 64 in
  Unix.environment ()
  |> Array.iter (fun entry ->
    let key, value = split_env_entry entry in
    Hashtbl.replace env_by_key key value);
  Command.env command
  |> List.iter (fun (key, value) -> Hashtbl.replace env_by_key key value);
  env_by_key
  |> Hashtbl.to_seq
  |> Seq.map (fun (key, value) -> key ^ "=" ^ value)
  |> Array.of_seq

external spawn_process_group :
     string
  -> string array
  -> string option
  -> string array
  -> Unix.file_descr
  -> Unix.file_descr
  -> Unix.file_descr
  -> int
  = "concurrently_posix_spawn_bytecode" "concurrently_posix_spawn"

let rec await_process_status pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> await_process_status pid

let start_reaper ~pid resolve_exit_status =
  ignore
    (Thread.create
       (fun () ->
         let status = await_process_status pid in
         ignore (Eio.Promise.try_resolve resolve_exit_status status))
       ())

let spawn_native ~stdin_read ~stdout_write ~stderr_write command =
  let argv = Array.of_list (shell_args command) in
  Eio_unix.Fd.use_exn "spawn stdin" stdin_read @@ fun stdin_fd ->
  Eio_unix.Fd.use_exn "spawn stdout" stdout_write @@ fun stdout_fd ->
  Eio_unix.Fd.use_exn "spawn stderr" stderr_write @@ fun stderr_fd ->
  spawn_process_group "/bin/sh" argv (Command.cwd command) (command_env command)
    stdin_fd stdout_fd stderr_fd

let spawn ~sw ~command =
  let stdin_pipe = Pipe.create ~sw in
  let stdout_pipe = Pipe.create ~sw in
  let stderr_pipe = Pipe.create ~sw in
  let close_child_sources () = Eio.Flow.close stdin_pipe.source in
  let close_child_sinks () =
    Eio.Flow.close stdout_pipe.sink;
    Eio.Flow.close stderr_pipe.sink
  in
  match
    spawn_native ~stdin_read:stdin_pipe.read_fd
      ~stdout_write:stdout_pipe.write_fd ~stderr_write:stderr_pipe.write_fd
      command
  with
  | pid ->
    close_child_sources ();
    close_child_sinks ();
    let exit_status, resolve_exit_status = Eio.Promise.create () in
    let native_process = { pid; exit_status } in
    start_reaper ~pid resolve_exit_status;
    let _cleanup_hook =
      Eio.Switch.on_release_cancellable sw (fun () ->
        if not (Eio.Promise.is_resolved exit_status) then
          match Posix_process_group.signal_group ~pid Sys.sigkill with
          | Ok _ | Error _ -> ())
    in
    let signal signal =
      if Eio.Promise.is_resolved exit_status && signal <> Sys.sigkill then
        Ok false
      else Posix_process_group.signal_group ~pid signal
    in
    { Runner_backend.process_id = string_of_int pid
    ; write_stdin = (fun input -> Eio.Flow.copy_string input stdin_pipe.sink)
    ; close_stdin = (fun () -> Eio.Flow.close stdin_pipe.sink)
    ; stdout = (stdout_pipe.source :> Runner_backend.source)
    ; stderr = (stderr_pipe.source :> Runner_backend.source)
    ; signal
    ; cleanup_after_exit =
        (fun () ->
          match Posix_process_group.signal_group ~pid Sys.sigkill with
          | Ok _ | Error _ -> ())
    ; await =
        (fun () ->
          let status = Eio.Promise.await native_process.exit_status in
          close_status status)
    }
  | exception exn ->
    close_child_sources ();
    Eio.Flow.close stdin_pipe.sink;
    close_child_sinks ();
    raise exn

let backend = { Runner_backend.spawn }
