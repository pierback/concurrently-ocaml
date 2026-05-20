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
  | Stopped_with_status of
      { status : Close_event.exit_status
      ; killed : bool
      }

type t =
  | Output_chunk of
      { command : Command.t
      ; attempt : int
      ; process_id : string option
      ; stream : stream
      ; chunk : string
      ; line_terminated : bool
      }
  | Lifecycle of
      { command : Command.t
      ; attempt : int
      ; process_id : string option
      ; lifecycle : lifecycle
      }
  | Status_message of
      { stream : stream
      ; chunk : string
      ; after_command : Command.t option
      }
  | Runtime_warning of
      { stream : stream
      ; chunk : string
      }

type payload =
  | Output_chunk_payload of
      { process_id : string option
      ; stream : stream
      ; chunk : string
      ; line_terminated : bool
      }
  | Lifecycle_payload of lifecycle
  | Status_message_payload of
      { stream : stream
      ; chunk : string
      ; after_command : Command.t option
      }
  | Runtime_warning_payload of
      { stream : stream
      ; chunk : string
      }

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
  | Started | Stopping | Stopped | Stopped_with_status _ -> Ok ()

let output_chunk ~command ~attempt ~process_id ~stream ~chunk ~line_terminated =
  match validate_attempt attempt with
  | Error error -> Error error
  | Ok () ->
      Ok
        (Output_chunk
           { command; attempt; process_id; stream; chunk; line_terminated })

let lifecycle_internal ~process_id ~command ~attempt ~lifecycle =
  match validate_attempt attempt with
  | Error error -> Error error
  | Ok () ->
    (match validate_lifecycle ~attempt lifecycle with
     | Error error -> Error error
     | Ok () -> Ok (Lifecycle { command; attempt; process_id; lifecycle }))

let lifecycle ~command ~attempt ~lifecycle =
  lifecycle_internal ~process_id:None ~command ~attempt ~lifecycle

let lifecycle_with_process_id ~process_id ~command ~attempt ~lifecycle =
  lifecycle_internal
    ~process_id:(Some process_id)
    ~command
    ~attempt
    ~lifecycle

let status_message ~after_command ~stream ~chunk =
  Status_message { stream; chunk; after_command }

let runtime_warning ~stream ~chunk = Runtime_warning { stream; chunk }

let command = function
  | Output_chunk { command; _ } | Lifecycle { command; _ } -> Some command
  | Status_message _ | Runtime_warning _ -> None

let attempt = function
  | Output_chunk { attempt; _ } | Lifecycle { attempt; _ } -> attempt
  | Status_message _ | Runtime_warning _ -> 0

let payload = function
  | Output_chunk { process_id; stream; chunk; line_terminated; _ } ->
      Output_chunk_payload { process_id; stream; chunk; line_terminated }
  | Lifecycle { lifecycle; _ } -> Lifecycle_payload lifecycle
  | Status_message { stream; chunk; after_command } ->
    Status_message_payload { stream; chunk; after_command }
  | Runtime_warning { stream; chunk } -> Runtime_warning_payload { stream; chunk }

let process_id = function
  | Output_chunk { process_id; _ } -> process_id
  | Lifecycle { process_id; _ } -> process_id
  | Status_message _ | Runtime_warning _ -> None
