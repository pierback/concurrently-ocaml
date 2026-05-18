type t

type create_error =
  [ `Close_event_capacity_overflow
  | `Command_index_mismatch of int * int
  | `Empty_command_list
  ]

val create :
  commands:Command.t list ->
  policy:Run_policy.t ->
  (t, create_error) result

val commands : t -> Command.t list
val policy : t -> Run_policy.t
val command_count : t -> int
val close_event_capacity : t -> int
