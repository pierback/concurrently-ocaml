[@@@alert "-unstable"]

open Concurrentlyocaml

let shell_args command =
  [ "/bin/sh"; "-c"; Command.text command ]

let close_status = function
  | Unix.WEXITED code -> Close_event.Exited code
  | Unix.WSIGNALED signal -> Close_event.Signaled (string_of_int signal)
  | Unix.WSTOPPED signal -> Close_event.Signaled ("STOP:" ^ string_of_int signal)

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

let spawn_process_group ~sw ~stdin_source ~stdout_sink ~stderr_sink command =
  let stdin_fd = Eio_unix.Resource.fd stdin_source in
  let stdout_fd = Eio_unix.Resource.fd stdout_sink in
  let stderr_fd = Eio_unix.Resource.fd stderr_sink in
  let module Fork_action = Eio_unix.Private.Fork_action in
  let argv = Array.of_list (shell_args command) in
  let cwd_actions =
    match Command.cwd command with
    | None -> []
    | Some cwd -> [ Fork_action.chdir cwd ]
  in
  Eio_posix.Low_level.Process.spawn
    ~sw
    (List.concat
       [ [ Posix_process_group.start_new_session
         ; Fork_action.inherit_fds
             [ 0, stdin_fd, `Blocking
             ; 1, stdout_fd, `Blocking
             ; 2, stderr_fd, `Blocking
             ]
         ]
       ; cwd_actions
       ; [ Fork_action.execve "/bin/sh" ~argv ~env:(command_env command) ]
       ])

let spawn ~sw ~command =
  let stdin_source, stdin_sink = Eio_unix.pipe sw in
  let stdout_source, stdout_sink = Eio_unix.pipe sw in
  let stderr_source, stderr_sink = Eio_unix.pipe sw in
  let close_child_sources () =
    Eio.Flow.close stdin_source
  in
  let close_child_sinks () =
    Eio.Flow.close stdout_sink;
    Eio.Flow.close stderr_sink
  in
  match
    spawn_process_group ~sw ~stdin_source ~stdout_sink ~stderr_sink command
  with
  | process ->
    close_child_sources ();
    close_child_sinks ();
    let pid = Eio_posix.Low_level.Process.pid process in
    let exit_status = Eio_posix.Low_level.Process.exit_status process in
    let signal signal =
      if Eio.Promise.is_resolved exit_status then Ok false
      else Posix_process_group.signal_group ~pid signal
    in
    { Runner_backend.process_id = string_of_int pid
    ; write_stdin = (fun input -> Eio.Flow.copy_string input stdin_sink)
    ; close_stdin = (fun () -> Eio.Flow.close stdin_sink)
    ; stdout = (stdout_source :> Runner_backend.source)
    ; stderr = (stderr_source :> Runner_backend.source)
    ; signal
    ; await =
        (fun () ->
          let status = Eio.Promise.await exit_status in
          (match Posix_process_group.signal_group ~pid Sys.sigkill with
          | Ok _ | Error _ -> ());
          close_status status)
    }
  | exception exn ->
    close_child_sources ();
    Eio.Flow.close stdin_sink;
    close_child_sinks ();
    raise exn

let backend = { Runner_backend.spawn }
