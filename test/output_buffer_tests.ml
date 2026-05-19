module Output_buffer = Concurrentlyocaml.Output_buffer
module Output_event = Concurrentlyocaml.Output_event

let chunk ?process_id ?(stream = Output_event.Stdout) text =
  { Output_buffer.process_id; stream; wall_time = 10.0; text }

let displayed_process_id process_id = process_id

let test_drains_in_append_order_and_clears_buffer () =
  let buffer = Output_buffer.create 2 in
  Output_buffer.append buffer ~command_index:1 (chunk ~process_id:"1" "a");
  Output_buffer.append buffer ~command_index:1 (chunk ~process_id:"1" "b");
  assert (
    Output_buffer.drain_runs buffer ~command_index:1 ~displayed_process_id
      ~split_chunks:false
    = [
        {
          Output_buffer.process_id = Some "1";
          stream = Output_event.Stdout;
          wall_time = 10.0;
          chunks = [ "a"; "b" ];
        };
      ]);
  assert (
    Output_buffer.drain_runs buffer ~command_index:1 ~displayed_process_id
      ~split_chunks:false
    = [])

let test_splits_when_displayed_process_or_stream_changes () =
  let buffer = Output_buffer.create 1 in
  Output_buffer.append buffer ~command_index:0 (chunk ~process_id:"1" "a");
  Output_buffer.append buffer ~command_index:0 (chunk ~process_id:"2" "b");
  Output_buffer.append buffer ~command_index:0
    (chunk ~process_id:"2" ~stream:Output_event.Stderr "c");
  let runs =
    Output_buffer.drain_runs buffer ~command_index:0 ~displayed_process_id
      ~split_chunks:false
  in
  assert (
    List.map (fun run -> run.Output_buffer.chunks) runs
    = [ [ "a" ]; [ "b" ]; [ "c" ] ])

let test_keeps_absent_and_empty_displayed_process_ids_distinct () =
  let buffer = Output_buffer.create 1 in
  Output_buffer.append buffer ~command_index:0 (chunk "a");
  Output_buffer.append buffer ~command_index:0 (chunk ~process_id:"" "b");
  let runs =
    Output_buffer.drain_runs buffer ~command_index:0 ~displayed_process_id
      ~split_chunks:false
  in
  assert (
    List.map (fun run -> run.Output_buffer.chunks) runs = [ [ "a" ]; [ "b" ] ])

let test_can_force_one_run_per_chunk () =
  let buffer = Output_buffer.create 1 in
  Output_buffer.append buffer ~command_index:0 (chunk ~process_id:"1" "a");
  Output_buffer.append buffer ~command_index:0 (chunk ~process_id:"1" "b");
  let runs =
    Output_buffer.drain_runs buffer ~command_index:0 ~displayed_process_id
      ~split_chunks:true
  in
  assert (
    List.map (fun run -> run.Output_buffer.chunks) runs = [ [ "a" ]; [ "b" ] ])

let () =
  test_drains_in_append_order_and_clears_buffer ();
  test_splits_when_displayed_process_or_stream_changes ();
  test_keeps_absent_and_empty_displayed_process_ids_distinct ();
  test_can_force_one_run_per_chunk ()
