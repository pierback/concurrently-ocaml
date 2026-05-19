type t
type expand_error = [ `Invalid_wildcard_omission of string ]

val command_text : t -> string
val command_name : t -> string
val has_command_name : t -> bool

val expand :
  cwd:string option ->
  passthrough_arguments:string list option ->
  command_texts:string list ->
  names:string list option ->
  (t list, expand_error) result

val effective_names : t list -> string list option
