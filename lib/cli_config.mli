type display =
  { labels : string list option
  ; prefix : string option
  ; prefix_length : int
  ; pad_prefix : bool
  ; timestamp_format : string
  ; spacious : bool
  ; timings : bool
  ; no_color : bool
  }

type t

type create_error =
  [ `Command_error of int * Command.create_error
  | `Empty_command_name of int
  | `Empty_name_separator
  | `Input_router_error of Input_router.create_error
  | `Invalid_restart_after of string
  | `Invalid_success_condition of string
  | `Name_count_mismatch of int * int
  | `Run_policy_error of Run_policy.create_error
  | `Run_spec_error of Run_spec.create_error
  ]

val create :
  teardown_texts:string list ->
  command_texts:string list ->
  names_csv:string option ->
  name_separator:string ->
  spacious:bool ->
  timings:bool ->
  raw:bool ->
  hide_csv:string option ->
  no_color:bool ->
  prefix:string option ->
  prefix_colors_csv:string option ->
  prefix_length:int ->
  pad_prefix:bool ->
  timestamp_format:string ->
  handle_input:bool ->
  default_input_target:string ->
  success:string ->
  kill_others:bool ->
  kill_others_on_fail:bool ->
  kill_signal:string ->
  kill_timeout_ms:int option ->
  max_processes:int option ->
  restart_tries:int ->
  restart_after:string ->
  (t, create_error) result

val spec : t -> Run_spec.t
val commands : t -> Command.t list
val policy : t -> Run_policy.t
val display : t -> display
val input : t -> Input_router.t option
val error_message : create_error -> string
