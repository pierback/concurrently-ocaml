type read_error =
  [ `Output_event_error of int * Output_event.create_error
  | `Unexpected_runner_error of string ]

val max_line_bytes : int
val read_buffer_bytes : int

val read :
  emit_event:(Output_event.t -> unit) ->
  command:Command.t ->
  attempt:int ->
  process_id:string option ->
  stream:Output_event.stream ->
  Runner_backend.source ->
  (unit, read_error) result
