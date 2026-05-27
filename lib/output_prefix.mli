type mode =
  | Default
  | Index
  | Pid
  | Name
  | Command
  | No_prefix
  | Time
  | Template of string

type options = {
  index_labels : string list option;
  prefix_length : float;
  pad_prefix : bool;
  timestamp_format : string;
}

val mode : string option -> mode
val format_timestamp : string -> float -> string
val name_label : Command.t -> string

val label_width :
  wall_now:(unit -> float) ->
  options:options ->
  mode:mode ->
  labels:string list ->
  Command.t list ->
  int option

val label_for_command :
  wall_time:float ->
  process_id:string option ->
  options:options ->
  mode:mode ->
  labels:string array ->
  width:int option ->
  Command.t ->
  string

val mentions_time : mode -> bool
val displayed_process_id : mode -> string option -> string option
val brackets_label : mode -> bool
