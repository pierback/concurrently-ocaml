module Runner_input_queue = Concurrentlyocaml.Runner_input_queue

let route target_index target_label payload =
  { Concurrentlyocaml.Input_router.target_index; target_label; payload }

let test_queues_and_drains_pending_input_in_order () =
  let queue = Runner_input_queue.create ~command_count:2 () in
  assert (
    Runner_input_queue.enqueue queue ~closed_command_indexes:[]
      (route 1 "worker" "first")
    = Runner_input_queue.Queued);
  assert (
    Runner_input_queue.enqueue queue ~closed_command_indexes:[]
      (route 1 "worker" "second")
    = Runner_input_queue.Queued);
  assert (
    Runner_input_queue.drain_for_spawn queue ~command_index:1
      ~stdin_should_follow_input:true
    = ([ "first"; "second" ], false));
  assert (
    Runner_input_queue.drain_for_spawn queue ~command_index:1
      ~stdin_should_follow_input:true
    = ([], false))

let test_reports_missing_and_overflow_targets () =
  let queue =
    Runner_input_queue.create ~max_chunks_per_command:1 ~command_count:1 ()
  in
  assert (
    Runner_input_queue.enqueue queue ~closed_command_indexes:[]
      (route (-1) "missing" "payload")
    = Runner_input_queue.Missing "missing");
  assert (
    Runner_input_queue.enqueue queue ~closed_command_indexes:[ 0 ]
      (route 0 "api" "payload")
    = Runner_input_queue.Missing "api");
  assert (
    Runner_input_queue.enqueue queue ~closed_command_indexes:[]
      (route 0 "api" "first")
    = Runner_input_queue.Queued);
  assert (
    Runner_input_queue.enqueue queue ~closed_command_indexes:[]
      (route 0 "api" "second")
    = Runner_input_queue.Overflow)

let test_source_closed_closes_stdin_after_spawn () =
  let queue = Runner_input_queue.create ~command_count:1 () in
  Runner_input_queue.mark_source_closed queue;
  assert (
    Runner_input_queue.drain_for_spawn queue ~command_index:0
      ~stdin_should_follow_input:true
    = ([], true));
  let queue = Runner_input_queue.create ~command_count:1 () in
  assert (
    Runner_input_queue.drain_for_spawn queue ~command_index:0
      ~stdin_should_follow_input:false
    = ([], true))

let () =
  test_queues_and_drains_pending_input_in_order ();
  test_reports_missing_and_overflow_targets ();
  test_source_closed_closes_stdin_after_spawn ()
