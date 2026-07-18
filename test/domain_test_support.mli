val ok : ('a, 'e) result -> 'a

val expect_error : 'e -> ('a, 'e) result -> unit

val command : int -> string -> Concurrentlyocaml.Command.t

val close_event :
  ?attempt:int ->
  ?killed:bool ->
  ?status:Concurrentlyocaml.Close_event.exit_status ->
  ?started_at:float ->
  ?ended_at:float ->
  Concurrentlyocaml.Command.t ->
  Concurrentlyocaml.Close_event.t
