type command_input =
  { text : string
  ; name : string option
  ; cwd : string option
  ; env : (string * string) list
  ; prefix_color : string option
  ; raw : bool option
  ; hidden : bool
  ; ipc : bool
  }

type t

type create_error =
  [ `Command_error of int * Command.create_error
  | `Input_router_error of Input_router.create_error
  | `Run_spec_error of Run_spec.create_error
  ]

val command :
  ?name:string ->
  ?cwd:string ->
  ?env:(string * string) list ->
  ?prefix_color:string ->
  ?raw:bool ->
  ?hidden:bool ->
  ?ipc:bool ->
  string ->
  command_input

val create :
  ?cwd:string ->
  ?policy:Run_policy.t ->
  ?labels:string list ->
  ?prefix:string ->
  ?prefix_length:int ->
  ?pad_prefix:bool ->
  ?timestamp_format:string ->
  ?spacious:bool ->
  ?timings:bool ->
  ?group:bool ->
  ?raw:bool ->
  ?color_mode:Output_formatter.color_mode ->
  ?handle_input:bool ->
  ?default_input_target:string ->
  command_input list ->
  (t, create_error) result

val run :
  t ->
  input_source:Runner_backend.source option ->
  backend:Runner_backend.t ->
  process_mgr:_ Eio.Process.mgr ->
  now:(unit -> float) ->
  sleep:(float -> unit) ->
  on_output_event:(Output_event.t -> unit) ->
  (Run_result.t, Runner.run_error) result

val spec : t -> Run_spec.t
val commands : t -> Command.t list
val policy : t -> Run_policy.t
val input : t -> Input_router.t option
val formatter_options : t -> Output_formatter.options
val error_message : create_error -> string
