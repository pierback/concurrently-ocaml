type route =
  { target_index : int
  ; payload : string
  }

type t

type create_error =
  [ `Empty_default_input_target
  | `Unknown_default_input_target of string
  ]

val create :
  commands:Command.t list ->
  default_input_target:string ->
  (t, create_error) result

val route : t -> string -> route
val error_message : create_error -> string
