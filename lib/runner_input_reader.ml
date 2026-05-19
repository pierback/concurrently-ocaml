let read ~source ~router ~write_input ~close_running_stdins
    ~record_unexpected_error =
  let read_buffer = Cstruct.create Runner_output_reader.read_buffer_bytes in
  let rec read_chunks () =
    match Eio.Flow.single_read source read_buffer with
    | bytes_read ->
        let chunk = Cstruct.to_string (Cstruct.sub read_buffer 0 bytes_read) in
        if not (String.equal chunk "") then
          Input_router.route router chunk |> write_input;
        read_chunks ()
    | exception End_of_file ->
        close_running_stdins ()
    | exception exn ->
        if not (Eio.Fiber.is_cancelled ()) then
          record_unexpected_error (Printexc.to_string exn)
  in
  read_chunks ()
