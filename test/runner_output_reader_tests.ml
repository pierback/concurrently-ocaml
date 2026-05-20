module Command = Concurrentlyocaml.Command
module Output_event = Concurrentlyocaml.Output_event
module Runner_output_reader = Concurrentlyocaml.Runner_output_reader

let ok = function Ok value -> value | Error _ -> assert false
let command ?(raw = false) index text = ok (Command.create ~index ~raw text)

let output_chunks events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Output_chunk_payload { chunk; _ } -> Some chunk
      | Output_event.Lifecycle_payload _ | Output_event.Status_message_payload _
      | Output_event.Runtime_warning_payload _
        ->
          None)

let output_line_terminated events =
  events
  |> List.filter_map (fun event ->
      match Output_event.payload event with
      | Output_event.Output_chunk_payload { line_terminated; _ } ->
          Some line_terminated
      | Output_event.Lifecycle_payload _ | Output_event.Status_message_payload _
      | Output_event.Runtime_warning_payload _
        ->
          None)

let read_events command source_text =
  let events = ref [] in
  let result =
    Runner_output_reader.read
      ~emit_event:(fun event -> events := event :: !events)
      ~command ~attempt:0 ~process_id:(Some "123") ~stream:Output_event.Stdout
      (Eio.Flow.string_source source_text)
  in
  assert (result = Ok ());
  List.rev !events

let read_chunks command source_text =
  output_chunks (read_events command source_text)

let test_line_reader_splits_lines_and_preserves_cr () =
  let events = read_events (command 0 "echo") "a\r\nb" in
  assert (output_chunks events = [ "a\r"; "b" ]);
  assert (output_line_terminated events = [ true; false ])

let test_line_reader_emits_terminator_after_exact_size_split () =
  let line = String.make Runner_output_reader.max_line_bytes 'x' in
  let events = read_events (command 0 "echo") (line ^ "\ny") in
  let chunks = output_chunks events in
  let line_terminated = output_line_terminated events in
  assert (String.concat "" chunks = line ^ "y");
  assert (
    match (List.rev chunks, List.rev line_terminated) with
    | "y" :: "" :: _, false :: true :: _ -> true
    | _ -> false)

let test_raw_reader_preserves_bytes () =
  assert (read_chunks (command ~raw:true 0 "echo") "a\r\nb" = [ "a\r\nb" ])

let () =
  test_line_reader_splits_lines_and_preserves_cr ();
  test_line_reader_emits_terminator_after_exact_size_split ();
  test_raw_reader_preserves_bytes ()
