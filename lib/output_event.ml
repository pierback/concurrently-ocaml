type stream =
  | Stdout
  | Stderr

type lifecycle =
  | Started
  | Restarting of
      { next_attempt : int
      ; delay_ms : int option
      }
  | Stopping
  | Stopped

type t =
  | Output_chunk of
      { command : Command.t
      ; attempt : int
      ; process_id : string option
      ; stream : stream
      ; chunk : string
      }
  | Lifecycle of
      { command : Command.t
      ; attempt : int
      ; lifecycle : lifecycle
      }

type payload =
  | Output_chunk_payload of
      { process_id : string option
      ; stream : stream
      ; chunk : string
      }
  | Lifecycle_payload of lifecycle

type create_error =
  [ `Invalid_next_attempt of int * int
  | `Negative_attempt
  | `Negative_delay_ms
  ]

let validate_attempt attempt =
  if attempt < 0 then Error `Negative_attempt else Ok ()

let validate_lifecycle ~attempt = function
  | Restarting { next_attempt; delay_ms = Some delay_ms } ->
    if next_attempt < 0 then Error `Negative_attempt
    else if next_attempt <> attempt + 1 then
      Error (`Invalid_next_attempt (attempt, next_attempt))
    else if delay_ms < 0 then Error `Negative_delay_ms
    else Ok ()
  | Restarting { next_attempt; delay_ms = None } ->
    if next_attempt < 0 then Error `Negative_attempt
    else if next_attempt <> attempt + 1 then
      Error (`Invalid_next_attempt (attempt, next_attempt))
    else Ok ()
  | Started | Stopping | Stopped -> Ok ()

let output_chunk ~command ~attempt ~process_id ~stream ~chunk =
  match validate_attempt attempt with
  | Error error -> Error error
  | Ok () -> Ok (Output_chunk { command; attempt; process_id; stream; chunk })

let lifecycle ~command ~attempt ~lifecycle =
  match validate_attempt attempt with
  | Error error -> Error error
  | Ok () ->
    (match validate_lifecycle ~attempt lifecycle with
     | Error error -> Error error
     | Ok () -> Ok (Lifecycle { command; attempt; lifecycle }))

let command = function
  | Output_chunk { command; _ } | Lifecycle { command; _ } -> command

let attempt = function
  | Output_chunk { attempt; _ } | Lifecycle { attempt; _ } -> attempt

let payload = function
  | Output_chunk { process_id; stream; chunk; _ } ->
    Output_chunk_payload { process_id; stream; chunk }
  | Lifecycle { lifecycle; _ } -> Lifecycle_payload lifecycle

let process_id = function
  | Output_chunk { process_id; _ } -> process_id
  | Lifecycle _ -> None
