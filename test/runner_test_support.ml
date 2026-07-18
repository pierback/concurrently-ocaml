module Command = Concurrentlyocaml.Command
module Close_event = Concurrentlyocaml.Close_event
module Output_event = Concurrentlyocaml.Output_event
module Posix_runner_backend = Concurrentlyocaml_posix.Posix_runner_backend
module Runner_backend = Concurrentlyocaml.Runner_backend
module Runner = Concurrentlyocaml.Runner
module Run_spec = Concurrentlyocaml.Run_spec

open Domain_test_support

let output_chunks events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Output_chunk_payload { chunk; _ } -> Some chunk
      | Output_event.Lifecycle_payload _ | Output_event.Status_message_payload _
      | Output_event.Runtime_warning_payload _
        ->
          None)

let status_messages events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Status_message_payload { chunk; _ } -> Some chunk
      | Output_event.Output_chunk_payload _ | Output_event.Lifecycle_payload _
      | Output_event.Runtime_warning_payload _
        ->
          None)

let runtime_warnings events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Runtime_warning_payload { chunk; _ } -> Some chunk
      | Output_event.Output_chunk_payload _ | Output_event.Lifecycle_payload _
      | Output_event.Status_message_payload _
        ->
          None)

let stopped_command_indexes events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Lifecycle_payload Output_event.Stopped
      | Output_event.Lifecycle_payload (Output_event.Stopped_with_status _) -> (
          match Output_event.command event with
          | Some command -> Some (Command.index command)
          | None -> None)
      | Output_event.Output_chunk_payload _ | Output_event.Lifecycle_payload _
      | Output_event.Status_message_payload _
      | Output_event.Runtime_warning_payload _ ->
          None)

let rec run_with_events ~policy command_texts =
  let commands =
    command_texts
    |> List.mapi (fun index text -> ok (Command.create ~index text))
  in
  run_commands_with_events ~policy commands

and run_commands_with_events ~policy commands =
  run_commands_with_backend_events ~backend:Posix_runner_backend.backend ~policy
    commands

and run_commands_with_backend_events ~backend ~policy commands =
  Eio_main.run (fun env ->
      let spec = ok (Run_spec.create ~commands ~policy) in
      let events = ref [] in
      let result =
        Runner.run ~input:None ~input_source:None ~backend
          ~now:(fun () -> Eio.Time.now (Eio.Stdenv.clock env))
          ~sleep:(fun seconds -> Eio.Time.sleep (Eio.Stdenv.clock env) seconds)
          ~spec
          ~on_output_event:(fun event -> events := event :: !events)
      in
      (result, List.rev !events))

module Slow_eof_source = struct
  type t = { mutable first_read : bool; sleep : unit -> unit }

  let read_methods = []

  let single_read t _buffer =
    if t.first_read then (
      t.first_read <- false;
      t.sleep ());
    raise End_of_file
end

let slow_eof_source ~sleep =
  Eio.Resource.T
    ( { Slow_eof_source.first_read = true; sleep },
      Eio.Flow.Pi.source (module Slow_eof_source) )

module Failing_source = struct
  type t = unit

  let read_methods = []
  let single_read () _buffer = failwith "reader boom"
end

let failing_source () =
  Eio.Resource.T ((), Eio.Flow.Pi.source (module Failing_source))

module Await_signal_source = struct
  type t = { mutable first_read : bool; wait_for_signal : unit -> unit }

  let read_methods = []

  let single_read t _buffer =
    if t.first_read then (
      t.first_read <- false;
      t.wait_for_signal ());
    raise End_of_file
end

let await_signal_source ~wait_for_signal =
  Eio.Resource.T
    ( { Await_signal_source.first_read = true; wait_for_signal },
      Eio.Flow.Pi.source (module Await_signal_source) )

let backend_process ?(process_id = "test") ?(write_stdin = fun _ -> ())
    ?(close_stdin = fun () -> ()) ?stdout ?stderr ?(signal = fun _ -> Ok true)
    ?(needs_cleanup_after_exit = fun () -> false)
    ?(cleanup_after_exit = fun () -> ())
    ?(await = fun () -> Close_event.Exited 0) () =
  let stdout =
    match stdout with
    | Some stdout -> stdout
    | None -> Eio.Flow.string_source ""
  in
  let stderr =
    match stderr with
    | Some stderr -> stderr
    | None -> Eio.Flow.string_source ""
  in
  {
    Runner_backend.process_id;
    write_stdin;
    close_stdin;
    stdout :> Runner_backend.source;
    stderr :> Runner_backend.source;
    signal;
    needs_cleanup_after_exit;
    cleanup_after_exit;
    await;
  }
