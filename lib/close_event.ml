type exit_status =
  | Exited of int
  | Signaled of string
  | Spawn_error of string

type timings =
  { started_at : float
  ; ended_at : float
  ; duration_seconds : float
  }

type t =
  { command : Command.t
  ; attempt : int
  ; killed : bool
  ; status : exit_status
  ; timings : timings
  }

type create_error =
  [ `Empty_signal
  | `Empty_spawn_error
  | `Negative_attempt
  | `Negative_exit_code
  | `Ended_before_started
  ]

let validate_status = function
  | Exited code ->
    if code < 0 then Error `Negative_exit_code else Ok ()
  | Signaled signal ->
    if String.trim signal = "" then Error `Empty_signal else Ok ()
  | Spawn_error message ->
    if String.trim message = "" then Error `Empty_spawn_error else Ok ()

let create ~command ~attempt ~killed ~status ~started_at ~ended_at =
  if attempt < 0 then Error `Negative_attempt
  else if ended_at < started_at then Error `Ended_before_started
  else
    match validate_status status with
    | Error error -> Error error
    | Ok () ->
      let timings =
        { started_at; ended_at; duration_seconds = ended_at -. started_at }
      in
      Ok { command; attempt; killed; status; timings }

let command t = t.command
let attempt t = t.attempt
let killed t = t.killed
let status t = t.status
let timings t = t.timings

let is_success t =
  match t.status with
  | Exited 0 -> true
  | Exited _ | Signaled _ | Spawn_error _ -> false
