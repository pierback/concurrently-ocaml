type t

type create_error =
  [ `Empty_command
  | `Empty_cwd
  | `Negative_index
  ]

val create :
  ?name:string ->
  ?cwd:string ->
  ?env:(string * string) list ->
  ?prefix_color:string ->
  ?raw:bool ->
  ?hidden:bool ->
  ?ipc:bool ->
  ?display_text:string ->
  ?allow_empty:bool ->
  index:int ->
  string ->
  (t, create_error) result

val index : t -> int
val text : t -> string
val display_text : t -> string
val name : t -> string option
val cwd : t -> string option
val env : t -> (string * string) list
val prefix_color : t -> string option
val raw : t -> bool
val hidden : t -> bool
val ipc : t -> bool
val equal : t -> t -> bool
