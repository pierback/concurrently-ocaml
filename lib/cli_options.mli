type boolean_option = {
  boolean_option_names : string list;
  negated_option_names : string list;
  emitted_boolean_option : string;
}

type env_option_kind = Env_flag | Env_value

type env_option = {
  option_names : string list;
  env_names : string list;
  kind : env_option_kind;
  emitted_option : string;
}

val boolean_options : boolean_option list
val boolean_flag_option_names : string list
val boolean_negated_option_names : string list
val short_boolean_flags : char list
val consumes_value : string -> bool
val is_known_flag : string -> bool
val is_known : string -> bool
val env_options : env_option list
val accepts_dash_prefixed_value : option_name:string -> value:string -> bool
val accepts_single_dash_prefixed_value : string -> bool
val emitted_value_option : string -> string option
