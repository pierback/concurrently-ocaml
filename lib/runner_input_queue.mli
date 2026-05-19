type t
type enqueue_result = Queued | Missing of string | Overflow

val create : ?max_chunks_per_command:int -> command_count:int -> unit -> t

val enqueue :
  t -> closed_command_indexes:int list -> Input_router.route -> enqueue_result

val drain_for_spawn :
  t -> command_index:int -> stdin_should_follow_input:bool -> string list * bool

val mark_source_closed : t -> unit
