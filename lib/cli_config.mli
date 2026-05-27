type display = {
  labels : string list option;
  index_labels : string list option;
  prefix : string option;
  prefix_length : float;
  pad_prefix : bool;
  timestamp_format : string;
  spacious : bool;
  timings : bool;
  group : bool;
  raw : bool;
  no_color : bool;
}

type t

type create_error =
  [ `Command_error of int * Command.create_error
  | `Command_input_error of Cli_command_inputs.expand_error
  | `Display_command_count_mismatch of int * int
  | `Input_router_error of Input_router.create_error
  | `Run_policy_error of Run_policy.create_error
  | `Run_spec_error of Run_spec.create_error ]

val create :
  cwd:string option ->
  passthrough_arguments:string list option ->
  teardown_texts:string list ->
  command_texts:string list ->
  names_csv:string option ->
  name_separator:string ->
  spacious:bool ->
  timings:bool ->
  group:bool ->
  raw:bool ->
  hide_csv:string option ->
  api_hide_indexes_csv:string option ->
  api_raw_indexes_csv:string option ->
  api_formatted_indexes_csv:string option ->
  api_index_labels_csv:string option ->
  no_color:bool ->
  prefix:string option ->
  prefix_colors_csv:string option ->
  prefix_length:float ->
  pad_prefix:bool ->
  timestamp_format:string ->
  handle_input:bool ->
  default_input_target:string ->
  success:string ->
  kill_others_on_success:bool ->
  kill_others:bool ->
  kill_others_on_fail:bool ->
  kill_signal:string ->
  kill_timeout_ms:string option ->
  max_processes:string option ->
  restart_tries:string ->
  restart_after:string ->
  (t, create_error) result

val create_with_display :
  cwd:string option ->
  passthrough_arguments:string list option ->
  teardown_texts:string list ->
  command_texts:string list ->
  display_command_texts:string list ->
  names_csv:string option ->
  force_empty_expansion:bool ->
  name_separator:string ->
  spacious:bool ->
  timings:bool ->
  group:bool ->
  raw:bool ->
  hide_csv:string option ->
  api_hide_indexes_csv:string option ->
  api_raw_indexes_csv:string option ->
  api_formatted_indexes_csv:string option ->
  api_index_labels_csv:string option ->
  no_color:bool ->
  prefix:string option ->
  prefix_colors_csv:string option ->
  prefix_length:float ->
  pad_prefix:bool ->
  timestamp_format:string ->
  handle_input:bool ->
  default_input_target:string ->
  success:string ->
  kill_others_on_success:bool ->
  kill_others:bool ->
  kill_others_on_fail:bool ->
  kill_signal:string ->
  kill_timeout_ms:string option ->
  max_processes:string option ->
  restart_tries:string ->
  restart_after:string ->
  (t, create_error) result

val spec : t -> Run_spec.t
val commands : t -> Command.t list
val policy : t -> Run_policy.t
val display : t -> display
val input : t -> Input_router.t option
val is_no_op : t -> bool
val error_message : create_error -> string
