type t

type create_error =
  [ `Attempt_after_success of int * int
  | `Attempt_exceeds_restart_tries of int * int
  | `Duplicate_close_event_attempt of int * int
  | `Incomplete_restart_attempt of int * int
  | `Missing_close_event_attempt of int * int
  | `Missing_close_events
  | `Negative_output_event_count
  | `Too_many_close_events
  | `Unexpected_command of int
  | `Unknown_command_index of int
  ]

val create :
  spec:Run_spec.t ->
  close_events:Close_event.t list ->
  output_event_count:int ->
  interrupted:bool ->
  (t, create_error) result

val spec : t -> Run_spec.t
val close_events : t -> Close_event.t list
val output_event_count : t -> int
val interrupted : t -> bool
val exit_code : t -> int
