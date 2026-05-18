type color_mode =
  | Always
  | Never

type options =
  { labels : string list option
  ; prefix : string option
  ; prefix_length : int
  ; pad_prefix : bool
  ; timestamp_format : string
  ; spacious : bool
  ; timings : bool
  ; group : bool
  ; raw : bool
  ; color_mode : color_mode
  }

type output =
  { stream : Output_event.stream
  ; text : string
  ; trailing_newline : bool
  }

type create_error =
  [ `Label_count_mismatch of int * int
  | `Negative_prefix_length
  | `Non_positive_command_count
  ]

type t

val create :
  now:(unit -> float) ->
  wall_now:(unit -> float) ->
  commands:Command.t list ->
  options ->
  (t, create_error) result

val handle_event : t -> Output_event.t -> output list
val default_labels : int -> (string list, create_error) result
val error_message : create_error -> string
