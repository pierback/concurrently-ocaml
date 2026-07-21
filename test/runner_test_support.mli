val output_chunks : Concurrentlyocaml.Output_event.t list -> string list
val status_messages : Concurrentlyocaml.Output_event.t list -> string list
val stopped_command_indexes : Concurrentlyocaml.Output_event.t list -> int list

val run_with_events :
  policy:Concurrentlyocaml.Run_policy.t ->
  string list ->
  (Concurrentlyocaml.Run_result.t, Concurrentlyocaml.Runner.run_error) result
  * Concurrentlyocaml.Output_event.t list

val run_commands_with_events :
  policy:Concurrentlyocaml.Run_policy.t ->
  Concurrentlyocaml.Command.t list ->
  (Concurrentlyocaml.Run_result.t, Concurrentlyocaml.Runner.run_error) result
  * Concurrentlyocaml.Output_event.t list

val run_commands_with_backend_events :
  backend:Concurrentlyocaml.Runner_backend.t ->
  policy:Concurrentlyocaml.Run_policy.t ->
  Concurrentlyocaml.Command.t list ->
  (Concurrentlyocaml.Run_result.t, Concurrentlyocaml.Runner.run_error) result
  * Concurrentlyocaml.Output_event.t list

val slow_eof_source :
  sleep:(unit -> unit) -> Concurrentlyocaml.Runner_backend.source

val failing_source : unit -> Concurrentlyocaml.Runner_backend.source

val await_signal_source :
  wait_for_signal:(unit -> unit) -> Concurrentlyocaml.Runner_backend.source

val backend_process :
  ?process_id:string ->
  ?write_stdin:(string -> unit) ->
  ?close_stdin:(unit -> unit) ->
  ?stdout:Concurrentlyocaml.Runner_backend.source ->
  ?stderr:Concurrentlyocaml.Runner_backend.source ->
  ?signal:(int -> (bool, string) result) ->
  ?needs_cleanup_after_exit:(unit -> bool) ->
  ?cleanup_after_exit:(unit -> unit) ->
  ?await:(unit -> Concurrentlyocaml.Close_event.exit_status) ->
  unit ->
  Concurrentlyocaml.Runner_backend.process
