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

let read_chunks command source_text =
  let events = ref [] in
  let result =
    Runner_output_reader.read
      ~emit_event:(fun event -> events := event :: !events)
      ~command ~attempt:0 ~process_id:(Some "123") ~stream:Output_event.Stdout
      (Eio.Flow.string_source source_text)
  in
  assert (result = Ok ());
  output_chunks (List.rev !events)

let test_line_reader_splits_lines_and_drops_cr () =
  assert (read_chunks (command 0 "echo") "a\r\nb" = [ "a"; "b" ])

let test_raw_reader_preserves_bytes () =
  assert (read_chunks (command ~raw:true 0 "echo") "a\r\nb" = [ "a\r\nb" ])

let () =
  test_line_reader_splits_lines_and_drops_cr ();
  test_raw_reader_preserves_bytes ()
