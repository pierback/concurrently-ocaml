type t

val create_error_message : Output_event.create_error -> string

val create :
  on_output_event:(Output_event.t -> unit) ->
  invalid_event:(string -> Output_event.create_error -> exn) ->
  t

val emit : t -> Output_event.t -> unit
val emit_best_effort : t -> Output_event.t -> unit

val lifecycle :
  t ->
  command:Command.t ->
  attempt:int ->
  Output_event.lifecycle ->
  unit

val lifecycle_best_effort :
  t ->
  command:Command.t ->
  attempt:int ->
  Output_event.lifecycle ->
  unit

val lifecycle_with_process_id :
  t ->
  process_id:string ->
  command:Command.t ->
  attempt:int ->
  Output_event.lifecycle ->
  unit

val lifecycle_with_process_id_best_effort :
  t ->
  process_id:string ->
  command:Command.t ->
  attempt:int ->
  Output_event.lifecycle ->
  unit

val output_chunk_best_effort :
  t ->
  command:Command.t ->
  attempt:int ->
  process_id:string option ->
  stream:Output_event.stream ->
  chunk:string ->
  line_terminated:bool ->
  unit

val count : t -> int
