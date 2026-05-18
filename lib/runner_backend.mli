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
  (** [signal n] returns [Ok true] when the signal was sent and [Ok false]
      when the process has already exited. *)
  (** [await] returns the primary process status. Backends must make inherited
      stdout/stderr handles drain promptly after this returns, including
      cleaning up descendants that kept pipe handles open. *)
  ; await : unit -> Close_event.exit_status
  }

type t =
  { spawn : sw:Eio.Switch.t -> command:Command.t -> process
  }
