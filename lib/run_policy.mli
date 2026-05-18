type kill_condition =
  | Success
  | Failure

type kill_signal =
  | Sigterm
  | Sigkill
  | Named_signal of string

type success_condition =
  | All
  | First
  | Last
  | Commands of int list
  | NoCommands

type restart_delay =
  | Fixed_delay_ms of int
  | Exponential_backoff

type restart_limit =
  | Finite_restarts of int
  | Infinite_restarts

type t

type create_error =
  [ `Duplicate_kill_condition
  | `Empty_signal
  | `Exponential_restart_delay_overflow
  | `Max_processes_less_than_one
  | `Negative_kill_timeout_ms
  | `Negative_success_command_index
  | `Negative_restart_delay_ms
  ]

val default : t

val create :
  ?kill_others_on:kill_condition list ->
  ?kill_signal:kill_signal ->
  ?kill_timeout_ms:int ->
  ?max_processes:int ->
  ?success_condition:success_condition ->
  ?restart_tries:int ->
  ?restart_delay:restart_delay ->
  ?teardown:Command.t list ->
  unit ->
  (t, create_error) result

val kill_others_on : t -> kill_condition list
val kill_signal : t -> kill_signal
val kill_timeout_ms : t -> int option
val max_processes : t -> int option
val success_condition : t -> success_condition
val restart_tries : t -> int
val restart_limit : t -> restart_limit
val restart_delay : t -> restart_delay
val restart_delay_ms : t -> next_attempt:int -> int
val teardown : t -> Command.t list
val should_retry : t -> Close_event.t -> bool
val close_event_completes_command : t -> Close_event.t -> bool
val attempt_exceeds_restart_limit : t -> attempt:int -> bool
val collect_retry_close_events : t -> bool
val close_event_capacity : t -> command_count:int -> (int, [ `Close_event_capacity_overflow ]) result
val should_kill_after_close : t -> Close_event.t -> bool
val run_succeeded : t -> Close_event.t list -> bool
