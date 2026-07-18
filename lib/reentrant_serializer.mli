(** A callback serializer that is safe to submit to from inside its callback.

    Values are handled in submission-entry order. The submitter that acquires
    drain ownership invokes callbacks; other submitters may return before their
    value is handled. An owner drains all currently handleable values and then
    re-raises the first callback exception that it observed. *)

type 'a t

val create : handle:('a -> unit) -> 'a t
val submit : 'a t -> 'a -> unit

module For_testing : sig
  val create :
    ?before_publish:(int -> unit) ->
    ?before_release:(unit -> unit) ->
    handle:('a -> unit) ->
    unit ->
    'a t
  (** Hooks run at ticket-publication and ownership-release race boundaries.
      They must not raise and should only make concurrency tests deterministic. *)
end
