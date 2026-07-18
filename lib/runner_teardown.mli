type t

val create :
  backend:Runner_backend.t ->
  now:(unit -> float) ->
  sleep:(float -> unit) ->
  policy:Run_policy.t ->
  output:Runner_output.t ->
  t

(** Delivers a signal received by [Runner_parent_signals.protect]. Calls must
    remain in that signal serializer's ordering domain. Each signal generation
    is attempted at most once for the active teardown process. *)
val handle_parent_signal : t -> Runner_parent_signals.signal -> unit

(** Runs teardown commands sequentially in policy order. Spawn, I/O, signal,
    await, and cleanup failures are emitted through [output] and never replace
    the main-command result. *)
val run_all : t -> parent_signals:Runner_parent_signals.t -> unit
