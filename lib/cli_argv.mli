type t = {
  argv : string array;
  passthrough_arguments : string list;
  deprecated_name_separator_used : bool;
}

val requests_help_before_separator : string array -> bool
val requests_default_help : string array -> bool
val normalize_with_env : env:(string -> string option) -> string array -> t
val normalize : string array -> t
