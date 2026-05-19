type lookup_error = [ `Unsupported_kill_signal of string ]

val number : Run_policy.kill_signal -> (int, lookup_error) result
val kill_label : Run_policy.kill_signal -> string
val label : string -> string
val exit_status_label : Close_event.exit_status -> string
