type style = { open_codes : int list; close_codes : int list }

val reset_style : style
val prefix_styles :
  color_level:int -> command_index:int -> string -> (style list, string) result
