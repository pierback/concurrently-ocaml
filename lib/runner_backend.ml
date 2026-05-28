type source = Eio.Flow.source_ty Eio.Resource.t

type process =
  { process_id : string
  ; write_stdin : string -> unit
  ; close_stdin : unit -> unit
  ; stdout : source
  ; stderr : source
  ; signal : int -> (bool, string) result
  ; cleanup_after_exit : unit -> unit
  ; await : unit -> Close_event.exit_status
  }

type t =
  { spawn : sw:Eio.Switch.t -> command:Command.t -> process
  }
