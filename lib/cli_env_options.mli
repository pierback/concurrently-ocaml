val add_arguments :
  env:(string -> string option) ->
  option_was_provided:(string list -> bool) ->
  string array ->
  string array
