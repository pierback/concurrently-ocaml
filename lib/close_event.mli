type exit_status =
  | Exited of int
  | Signaled of string
  | Spawn_error of string

type timings =
  { started_at : float
  ; ended_at : float
  ; duration_seconds : float
  }

type t

type create_error =
  [ `Empty_signal
  | `Empty_spawn_error
  | `Negative_attempt
  | `Negative_exit_code
  | `Ended_before_started
  ]

val create :
  command:Command.t ->
  attempt:int ->
  killed:bool ->
  status:exit_status ->
  started_at:float ->
  ended_at:float ->
  (t, create_error) result

val command : t -> Command.t
val attempt : t -> int
val killed : t -> bool
val status : t -> exit_status
val timings : t -> timings
val is_success : t -> bool
