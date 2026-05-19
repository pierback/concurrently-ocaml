let read ~source ~router ~write_input ~close_running_stdins
    ~record_unexpected_error =
  let read_buffer = Cstruct.create Runner_output_reader.read_buffer_bytes in
  let input_buffer = Buffer.create Runner_output_reader.read_buffer_bytes in
  let flush_buffer ?(line_end = false) () =
    let input = Buffer.contents input_buffer in
    Buffer.clear input_buffer;
    let input = if line_end then input ^ "\n" else input in
    if not (String.equal input "") then
      Input_router.route router input |> write_input
  in
  let flush_final_partial_input () =
    if Buffer.length input_buffer > 0 then flush_buffer ()
  in
  let process_byte byte =
    if byte = '\n' then flush_buffer ~line_end:true ()
    else (
      Buffer.add_char input_buffer byte;
      if Buffer.length input_buffer >= Runner_output_reader.max_line_bytes then
        flush_buffer ())
  in
  let process_chunk chunk =
    let length = String.length chunk in
    let rec loop index =
      if index = length then ()
      else (
        process_byte chunk.[index];
        loop (index + 1))
    in
    loop 0
  in
  let rec read_chunks () =
    match Eio.Flow.single_read source read_buffer with
    | bytes_read ->
        let chunk = Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read) in
        process_chunk chunk;
        read_chunks ()
    | exception End_of_file ->
        flush_final_partial_input ();
        close_running_stdins ()
    | exception exn ->
        if not (Eio.Fiber.is_cancelled ()) then
          record_unexpected_error (Printexc.to_string exn)
  in
  read_chunks ()
