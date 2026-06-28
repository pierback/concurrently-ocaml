type source = Eio.Flow.source_ty Eio.Resource.t

type process =
  { process_id : string
  (** Stable process identity for output prefixes. Backends choose the
      OS-appropriate value; POSIX uses the spawned shell process PID. *)
  ; write_stdin : string -> unit
  (** Writes forwarded user input to process stdin. *)
  ; close_stdin : unit -> unit
  (** Closes process stdin after the input source reaches EOF. *)
  ; stdout : source
  ; stderr : source
  ; signal : int -> (bool, string) result
  (** [signal n] returns [Ok true] when the backend still had a live target for
      the signal and [Ok false] when neither the root process nor any
      backend-owned descendants remained. When [needs_cleanup_after_exit ()] can
      still be true after the root exits, post-exit [SIGKILL] must keep
      attempting that descendant cleanup and report [Ok true] while work
      remains. *)
  ; needs_cleanup_after_exit : unit -> bool
  (** [needs_cleanup_after_exit ()] reports whether backend-owned descendants
      may still need reclamation after the root process exits. *)
  ; cleanup_after_exit : unit -> unit
  (** [cleanup_after_exit ()] reclaims backend-owned descendants after the root
      process exits without emitting another logical signal result. *)
  ; await : unit -> Close_event.exit_status
  (** [await] returns the primary process status. *)
  }

type t =
  { spawn : sw:Eio.Switch.t -> command:Command.t -> process
  }
