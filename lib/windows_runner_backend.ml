[@@@alert "-unstable"]

open Concurrentlyocaml

type native_process = {
  process_id : int;
  process_handle : nativeint;
  job_handle : nativeint;
}

module Blocking_pipe = struct
  type endpoint = { fd : Unix.file_descr; closed : bool Atomic.t }
  type source = [ Eio.Resource.close_ty | Eio.Flow.source_ty ] Eio.Resource.t
  type sink = [ Eio.Resource.close_ty | Eio.Flow.sink_ty ] Eio.Resource.t

  type pipe = {
    source : source;
    sink : sink;
    read_endpoint : endpoint;
    write_endpoint : endpoint;
  }

  let create_endpoint fd = { fd; closed = Atomic.make false }
  let file_descr endpoint = endpoint.fd

  let close_endpoint endpoint =
    if Atomic.compare_and_set endpoint.closed false true then
      match Unix.close endpoint.fd with
      | () -> ()
      | exception Unix.Unix_error (Unix.EBADF, _, _) -> ()

  module Source = struct
    type t = endpoint

    let read_methods = []

    let single_read endpoint buffer =
      if Atomic.get endpoint.closed then raise End_of_file;
      let bytes_read =
        Eio_unix.run_in_systhread ~label:"windows-pipe-read" (fun () ->
            Unix.read_bigarray endpoint.fd buffer.Cstruct.buffer
              buffer.Cstruct.off buffer.Cstruct.len)
      in
      if bytes_read = 0 then raise End_of_file else bytes_read
  end

  module Sink = struct
    type t = endpoint

    let write_one endpoint buffer =
      if Atomic.get endpoint.closed then raise End_of_file;
      Eio_unix.run_in_systhread ~label:"windows-pipe-write" (fun () ->
          Unix.write_bigarray endpoint.fd buffer.Cstruct.buffer
            buffer.Cstruct.off buffer.Cstruct.len)

    let rec single_write endpoint buffers =
      match buffers with
      | [] -> 0
      | buffer :: remaining when Cstruct.is_empty buffer ->
          single_write endpoint remaining
      | buffer :: remaining -> (
          match write_one endpoint buffer with
          | 0 -> 0
          | bytes_written when bytes_written = Cstruct.length buffer ->
              bytes_written + single_write endpoint remaining
          | bytes_written -> bytes_written)

    let copy endpoint ~src = Eio.Flow.Pi.simple_copy ~single_write endpoint ~src
  end

  let source_handler =
    Eio.Resource.handler
      [
        Eio.Resource.H (Eio.Resource.Close, close_endpoint);
        Eio.Resource.H (Eio.Flow.Pi.Source, (module Source));
      ]

  let sink_handler =
    Eio.Resource.handler
      [
        Eio.Resource.H (Eio.Resource.Close, close_endpoint);
        Eio.Resource.H (Eio.Flow.Pi.Sink, (module Sink));
      ]

  let create ~sw =
    let read_fd, write_fd = Unix.pipe ~cloexec:true () in
    let read_endpoint = create_endpoint read_fd in
    let write_endpoint = create_endpoint write_fd in
    Eio.Switch.on_release sw (fun () ->
        close_endpoint read_endpoint;
        close_endpoint write_endpoint);
    {
      source = Eio.Resource.T (read_endpoint, source_handler);
      sink = Eio.Resource.T (write_endpoint, sink_handler);
      read_endpoint;
      write_endpoint;
    }
end

external create_process :
  string ->
  string ->
  string option ->
  string array ->
  Unix.file_descr ->
  Unix.file_descr ->
  Unix.file_descr ->
  int * nativeint * nativeint
  = "concurrently_windows_create_process_bytecode"
    "concurrently_windows_create_process"

external await_exit_code : nativeint -> int = "concurrently_windows_await"

external terminate_job : nativeint -> int -> unit
  = "concurrently_windows_terminate_job"

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
  | None -> (entry, "")
  | Some separator ->
      ( String.sub entry 0 separator,
        String.sub entry (separator + 1) (String.length entry - separator - 1)
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
  env_by_key |> Hashtbl.to_seq_values |> List.of_seq
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

let shell_path command env =
  match Command.shell command with
  | Some path when String.trim path <> "" -> path
  | Some _ | None -> (
      match env_value "ComSpec" env with
      | Some path when String.trim path <> "" -> path
      | Some _ | None -> "cmd.exe")

let close_process_handles native_process =
  close_handle native_process.process_handle;
  close_handle native_process.job_handle

let spawn_native ~stdin_read ~stdout_write ~stderr_write command =
  let env = command_env command in
  let shell_path = shell_path command env in
  let command_line =
    Windows_command_line.shell_command_line ~shell_path
      ~command_text:(Command.text command)
  in
  let process_id, process_handle, job_handle =
    create_process shell_path command_line (Command.cwd command) env
      (Blocking_pipe.file_descr stdin_read)
      (Blocking_pipe.file_descr stdout_write)
      (Blocking_pipe.file_descr stderr_write)
  in
  { process_id; process_handle; job_handle }

let spawn ~sw ~command =
  let stdin_pipe = Blocking_pipe.create ~sw in
  let stdout_pipe = Blocking_pipe.create ~sw in
  let stderr_pipe = Blocking_pipe.create ~sw in
  let close_child_sources () = Eio.Flow.close stdin_pipe.source in
  let close_child_sinks () =
    Eio.Flow.close stdout_pipe.sink;
    Eio.Flow.close stderr_pipe.sink
  in
  match
    spawn_native ~stdin_read:stdin_pipe.read_endpoint
      ~stdout_write:stdout_pipe.write_endpoint
      ~stderr_write:stderr_pipe.write_endpoint command
  with
  | native_process ->
      let exit_status, resolve_exit_status = Eio.Promise.create () in
      let closed = ref false in
      let close_handles_once () =
        if not !closed then (
          closed := true;
          close_process_handles native_process)
      in
      let terminate_job exit_code =
        terminate_job native_process.job_handle exit_code
      in
      let _cleanup_hook =
        Eio.Switch.on_release_cancellable sw (fun () ->
            (if not (Eio.Promise.is_resolved exit_status) then
               try terminate_job 1 with _ -> ());
            close_handles_once ())
      in
      close_child_sources ();
      close_child_sinks ();
      let signal _signal =
        if Eio.Promise.is_resolved exit_status then Ok false
        else
          try
            terminate_job 1;
            Ok true
          with exn -> Error (Printexc.to_string exn)
      in
      {
        Runner_backend.process_id = string_of_int native_process.process_id;
        write_stdin = (fun input -> Eio.Flow.copy_string input stdin_pipe.sink);
        close_stdin = (fun () -> Eio.Flow.close stdin_pipe.sink);
        stdout = (stdout_pipe.source :> Runner_backend.source);
        stderr = (stderr_pipe.source :> Runner_backend.source);
        signal;
        cleanup_after_exit = (fun () -> ());
        await =
          (fun () ->
            let exit_code =
              Eio_unix.run_in_systhread ~label:"windows-await-process"
                (fun () -> await_exit_code native_process.process_handle)
            in
            ignore
              (Eio.Promise.try_resolve resolve_exit_status
                 (Close_event.Exited exit_code));
            close_handles_once ();
            Close_event.Exited exit_code);
      }
  | exception exn ->
      close_child_sources ();
      Eio.Flow.close stdin_pipe.sink;
      close_child_sinks ();
      raise exn

let backend = { Runner_backend.spawn }
