type read_error =
  [ `Output_event_error of int * Output_event.create_error
  | `Unexpected_runner_error of string ]

let max_line_bytes = 1_048_576
let read_buffer_bytes = 16_384

let emit_output_chunk ~emit_event ~command ~attempt ~process_id ~stream ~chunk
    ~line_terminated =
  match
    Output_event.output_chunk ~command ~attempt ~process_id ~stream ~chunk
      ~line_terminated
  with
  | Ok event -> (
      match emit_event event with
      | () -> Ok ()
      | exception exn ->
          Error (`Unexpected_runner_error (Printexc.to_string exn)))
  | Error error -> Error (`Output_event_error (Command.index command, error))

let read_raw_output ~emit_event ~command ~attempt ~process_id ~stream source =
  let read_buffer = Cstruct.create read_buffer_bytes in
  let rec read_chunks () =
    match Eio.Flow.single_read source read_buffer with
    | bytes_read -> (
        let chunk = Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read) in
        match
          emit_output_chunk ~emit_event ~command ~attempt ~process_id ~stream
            ~chunk ~line_terminated:false
        with
        | Ok () -> read_chunks ()
        | Error _ as error -> error)
    | exception End_of_file -> Ok ()
    | exception exn -> Error (`Unexpected_runner_error (Printexc.to_string exn))
  in
  read_chunks ()

let read_line_output ~emit_event ~command ~attempt ~process_id ~stream source =
  let read_buffer = Cstruct.create read_buffer_bytes in
  let line_buffer = Buffer.create read_buffer_bytes in
  let line_was_split = ref false in
  let emit_chunk ~line_terminated chunk =
    emit_output_chunk ~emit_event ~command ~attempt ~process_id ~stream ~chunk
      ~line_terminated
  in
  let flush_buffer ?(line_end = false) () =
    let chunk = Buffer.contents line_buffer in
    Buffer.clear line_buffer;
    emit_chunk ~line_terminated:line_end chunk
  in
  let flush_oversized_line_part () =
    line_was_split := true;
    flush_buffer ~line_end:false ()
  in
  let flush_line () =
    if Buffer.length line_buffer = 0 && !line_was_split then (
      line_was_split := false;
      emit_chunk ~line_terminated:true "")
    else
      match flush_buffer ~line_end:true () with
      | Ok () ->
          line_was_split := false;
          Ok ()
      | Error _ as error -> error
  in
  let flush_final_partial_line () =
    if Buffer.length line_buffer = 0 then Ok ()
    else flush_buffer ~line_end:false ()
  in
  let flush_available_partial_line () =
    if Buffer.length line_buffer = 0 then Ok ()
    else flush_buffer ~line_end:false ()
  in
  let process_byte byte =
    if byte = '\n' then flush_line ()
    else (
      Buffer.add_char line_buffer byte;
      if Buffer.length line_buffer >= max_line_bytes then
        flush_oversized_line_part ()
      else Ok ())
  in
  let process_chunk chunk =
    let length = String.length chunk in
    let rec loop index =
      if index = length then Ok ()
      else
        match process_byte chunk.[index] with
        | Ok () -> loop (index + 1)
        | Error _ as error -> error
    in
    loop 0
  in
  let rec read_chunks () =
    match Eio.Flow.single_read source read_buffer with
    | bytes_read -> (
        let chunk = Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read) in
        match process_chunk chunk with
        | Ok () -> (
            match flush_available_partial_line () with
            | Ok () -> read_chunks ()
            | Error _ as error -> error)
        | Error _ as error -> error)
    | exception End_of_file -> flush_final_partial_line ()
    | exception exn -> Error (`Unexpected_runner_error (Printexc.to_string exn))
  in
  read_chunks ()

let read ~emit_event ~command ~attempt ~process_id ~stream source =
  if Command.raw command then
    read_raw_output ~emit_event ~command ~attempt ~process_id ~stream source
  else read_line_output ~emit_event ~command ~attempt ~process_id ~stream source
