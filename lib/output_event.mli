type stream =
  | Stdout
  | Stderr

type lifecycle =
  | Started
  | Restarting of
      { next_attempt : int
      ; delay_ms : int option
      }
  | Stopping
  | Stopped

type t

type payload =
  | Output_chunk_payload of
      { process_id : string option
      ; stream : stream
      ; chunk : string
      }
  | Lifecycle_payload of lifecycle

type create_error =
  [ `Invalid_next_attempt of int * int
  | `Negative_attempt
  | `Negative_delay_ms
  ]

val output_chunk :
  command:Command.t ->
  attempt:int ->
  process_id:string option ->
  stream:stream ->
  chunk:string ->
  (t, create_error) result

val lifecycle :
  command:Command.t ->
  attempt:int ->
  lifecycle:lifecycle ->
  (t, create_error) result

val command : t -> Command.t
val attempt : t -> int
val payload : t -> payload
val process_id : t -> string option
