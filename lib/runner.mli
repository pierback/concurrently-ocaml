type run_error =
  [ `Close_event_error of int * Close_event.create_error
  | `Output_event_error of int * Output_event.create_error
  | `Run_result_error of Run_result.create_error
  | `Unsupported_kill_signal of string
  | `Unexpected_runner_error of string
  ]

val run :
  input:Input_router.t option ->
  input_source:Runner_backend.source option ->
  backend:Runner_backend.t ->
  process_mgr:_ Eio.Process.mgr ->
  now:(unit -> float) ->
  sleep:(float -> unit) ->
  spec:Run_spec.t ->
  on_output_event:(Output_event.t -> unit) ->
  (Run_result.t, run_error) result

val error_message : run_error -> string
