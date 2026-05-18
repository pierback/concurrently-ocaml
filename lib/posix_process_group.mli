val start_new_session : Eio_unix.Private.Fork_action.t

val signal_group : pid:int -> int -> (bool, string) result
