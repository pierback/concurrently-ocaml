type entry = {
  command_index : int;
  name : string;
  duration_ms : int;
  exit_code : string;
  killed : bool;
  command_text : string;
}

val duration_ms : float -> int
val format_integer_with_separators : int -> string
val summary_lines : command_count:int -> entry list -> string list
