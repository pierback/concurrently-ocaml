type t

type signal = private { generation : int; number : int }

type 'a outcome = [ `Completed of 'a | `Interrupted of int * 'a ]

(** [protect ~on_signal run] installs handlers for SIGHUP, SIGINT, and SIGTERM
    while [run] executes, then restores the previous handlers. Signals are
    delivered to [on_signal] in one reentrant-safe ordering domain. The first
    received signal determines [Interrupted]; later signals are still
    delivered. *)
val protect : on_signal:(signal -> unit) -> (t -> 'a) -> 'a outcome

val current : t -> signal option

(** [serialize t callback] orders [callback] with [protect]'s signal
    callbacks and permits callbacks to submit more serialized work. *)
val serialize : t -> (unit -> unit) -> unit
