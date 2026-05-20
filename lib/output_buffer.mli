type chunk = {
  process_id : string option;
  stream : Output_event.stream;
  wall_time : float;
  text : string;
  line_terminated : bool;
}

type output_chunk = { text : string; line_terminated : bool }

type run = {
  process_id : string option;
  stream : Output_event.stream;
  wall_time : float;
  chunks : output_chunk list;
}

type t

val create : int -> t
val append : t -> command_index:int -> chunk -> unit
val last_chunk : t -> command_index:int -> chunk option

val drain_runs :
  t ->
  command_index:int ->
  displayed_process_id:(string option -> string option) ->
  split_chunks:bool ->
  run list
