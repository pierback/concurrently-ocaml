type t = {
  command_count : int;
  max_chunks_per_command : int;
  pending_chunks : string list array;
  mutable source_closed : bool;
}

type enqueue_result = Queued | Missing of string | Overflow

let create ?(max_chunks_per_command = 64) ~command_count () =
  assert (command_count >= 0);
  assert (max_chunks_per_command > 0);
  {
    command_count;
    max_chunks_per_command;
    pending_chunks = Array.make command_count [];
    source_closed = false;
  }

let enqueue t ~closed_command_indexes route =
  let command_index = route.Input_router.target_index in
  if
    command_index < 0
    || command_index >= t.command_count
    || List.mem command_index closed_command_indexes
  then Missing route.Input_router.target_label
  else
    let pending = t.pending_chunks.(command_index) in
    if List.length pending >= t.max_chunks_per_command then Overflow
    else (
      t.pending_chunks.(command_index) <- route.Input_router.payload :: pending;
      Queued)

let drain_for_spawn t ~command_index ~stdin_should_follow_input =
  assert (command_index >= 0 && command_index < t.command_count);
  let pending = List.rev t.pending_chunks.(command_index) in
  t.pending_chunks.(command_index) <- [];
  (pending, t.source_closed || not stdin_should_follow_input)

let mark_source_closed t = t.source_closed <- true
