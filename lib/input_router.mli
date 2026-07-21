type route =
  { target_index : int
  ; target_label : string
  ; payload : string
  }

type t

val create :
  commands:Command.t list ->
  index_labels:string list option ->
  default_input_target:string ->
  t

val route : t -> string -> route
