type chunk = {
  process_id : string option;
  stream : Output_event.stream;
  wall_time : float;
  text : string;
}

type run = {
  process_id : string option;
  stream : Output_event.stream;
  wall_time : float;
  chunks : string list;
}

type t

val create : int -> t
val append : t -> command_index:int -> chunk -> unit

val drain_runs :
  t ->
  command_index:int ->
  displayed_process_id:(string option -> string option) ->
  split_chunks:bool ->
  run list
