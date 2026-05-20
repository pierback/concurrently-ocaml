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

let () =
  test_spawn_maps_cwd_env_stdout_stderr_and_exit ();
  test_stdin_write_and_close_reaches_child ();
  test_signal_after_exit_reports_not_running ();
  test_signal_reaches_running_process_group ()
