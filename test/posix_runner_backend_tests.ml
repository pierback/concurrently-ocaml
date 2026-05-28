module Close_event = Concurrentlyocaml.Close_event
module Command = Concurrentlyocaml.Command
module Posix_runner_backend = Concurrentlyocaml_posix.Posix_runner_backend

let ok = function Ok value -> value | Error _ -> assert false

let command ?cwd ?(env = []) text =
  ok (Command.create ?cwd ~env ~index:0 text)

let read_all source =
  let buffer = Buffer.create 128 in
  let read_buffer = Cstruct.create 4096 in
  let rec loop () =
    match Eio.Flow.single_read source read_buffer with
    | bytes_read ->
      Buffer.add_string buffer
        (Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read));
      loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let with_process command_text test =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let process =
    Posix_runner_backend.backend.spawn ~sw ~command:(command command_text)
  in
  test process

let with_closed_stdin test =
  let saved_stdin = Unix.dup Unix.stdin in
  Fun.protect
    ~finally:(fun () ->
      Unix.dup2 saved_stdin Unix.stdin;
      Unix.close saved_stdin)
    (fun () ->
      Unix.close Unix.stdin;
      test ())

let test_spawn_maps_cwd_env_stdout_stderr_and_exit () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let cwd = Sys.getcwd () in
  let process =
    Posix_runner_backend.backend.spawn ~sw
      ~command:
        (command ~cwd ~env:[ "CONCURRENTLY_OCAML_BACKEND_TEST", "ok" ]
           "printf 'cwd:%s\nenv:%s\n' \"$PWD\" \
            \"$CONCURRENTLY_OCAML_BACKEND_TEST\"; printf 'err:ok\n' >&2")
  in
  assert (process.process_id <> "");
  assert (process.await () = Close_event.Exited 0);
  assert (read_all process.stdout = Printf.sprintf "cwd:%s\nenv:ok\n" cwd);
  assert (read_all process.stderr = "err:ok\n")

let test_stdin_write_and_close_reaches_child () =
  with_process "cat" @@ fun process ->
  process.write_stdin "hello\n";
  process.close_stdin ();
  assert (process.await () = Close_event.Exited 0);
  assert (read_all process.stdout = "hello\n");
  assert (read_all process.stderr = "")

let test_stdin_survives_when_runtime_stdin_fd_is_reused () =
  Eio_main.run @@ fun _env ->
  with_closed_stdin @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let process =
    Posix_runner_backend.backend.spawn ~sw ~command:(command "cat")
  in
  process.write_stdin "hello\n";
  process.close_stdin ();
  assert (process.await () = Close_event.Exited 0);
  assert (read_all process.stdout = "hello\n");
  assert (read_all process.stderr = "")

let test_child_stdin_is_blocking () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let process =
    Posix_runner_backend.backend.spawn ~sw
      ~command:(command "dd bs=5 count=1 2>/dev/null")
  in
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.2;
  process.write_stdin "hello";
  process.close_stdin ();
  assert (process.await () = Close_event.Exited 0);
  assert (read_all process.stdout = "hello");
  assert (read_all process.stderr = "")

let test_signal_after_exit_reports_not_running () =
  with_process "printf done" @@ fun process ->
  assert (process.await () = Close_event.Exited 0);
  assert (read_all process.stdout = "done");
  assert (process.signal Sys.sigterm = Ok false)

let test_signal_reaches_running_process_group () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let process =
    Posix_runner_backend.backend.spawn ~sw
      ~command:
        (command
           "trap 'printf term; exit 130' TERM; while :; do sleep 10; done")
  in
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
  assert (process.signal Sys.sigterm = Ok true);
  assert (process.await () = Close_event.Exited 130);
  assert (read_all process.stdout = "term")

let rec wait_until_pid_gone clock pid deadline =
  match Unix.kill pid 0 with
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()
  | exception exn -> raise exn
  | () ->
    if Eio.Time.now clock >= deadline then assert false;
    Eio.Time.sleep clock 0.01;
    wait_until_pid_gone clock pid deadline

let test_switch_release_kills_running_process () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let pid = ref None in
  Eio.Switch.run (fun sw ->
      let process =
        Posix_runner_backend.backend.spawn ~sw ~command:(command "sleep 10")
      in
      pid := Some (int_of_string process.process_id);
      Eio.Time.sleep clock 0.05);
  match !pid with
  | None -> assert false
  | Some pid -> wait_until_pid_gone clock pid (Eio.Time.now clock +. 1.0)

let test_cancelled_await_does_not_block_switch_release () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
    match
      Eio.Switch.run (fun sw ->
        let process =
          Posix_runner_backend.backend.spawn ~sw ~command:(command "sleep 10")
        in
        Eio.Fiber.fork ~sw (fun () -> ignore (process.await ()));
        Eio.Time.sleep clock 0.05;
        raise Exit)
    with
    | () -> assert false
    | exception Exit -> ())

let test_cancelled_stdout_reader_does_not_block_switch_release () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 1.0 (fun () ->
    match
      Eio.Switch.run (fun sw ->
        let process =
          Posix_runner_backend.backend.spawn ~sw ~command:(command "sleep 10")
        in
        Eio.Fiber.fork ~sw (fun () -> ignore (read_all process.stdout));
        Eio.Time.sleep clock 0.05;
        raise Exit)
    with
    | () -> assert false
    | exception Exit -> ())

let () =
  test_spawn_maps_cwd_env_stdout_stderr_and_exit ();
  test_stdin_write_and_close_reaches_child ();
  test_stdin_survives_when_runtime_stdin_fd_is_reused ();
  test_child_stdin_is_blocking ();
  test_signal_after_exit_reports_not_running ();
  test_signal_reaches_running_process_group ();
  test_switch_release_kills_running_process ();
  test_cancelled_await_does_not_block_switch_release ();
  test_cancelled_stdout_reader_does_not_block_switch_release ()
