type t =
  { spec : Run_spec.t
  ; close_events : Close_event.t list
  ; output_event_count : int
  ; interrupted : bool
  ; interrupted_signal : int option
  }

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

let validate_close_events ~commands ~policy close_events =
  let command_count = Array.length commands in
  let close_events_by_command = Array.make command_count [] in
  let validate_contiguous_attempts () =
    if not (Run_policy.collect_retry_close_events policy) then Ok ()
    else
      let validate_attempts command_index close_events =
      let sorted_close_events =
        List.sort
          (fun left right ->
            Int.compare (Close_event.attempt left) (Close_event.attempt right))
          close_events
      in
      let rec validate_expected ~previous_attempt_succeeded expected_attempt = function
        | [] -> Ok ()
        | close_event :: rest ->
          let attempt = Close_event.attempt close_event in
          if attempt <> expected_attempt then
            Error (`Missing_close_event_attempt (command_index, expected_attempt))
          else if previous_attempt_succeeded then
            Error (`Attempt_after_success (command_index, attempt))
          else
            validate_expected
              ~previous_attempt_succeeded:(Close_event.is_success close_event)
              (expected_attempt + 1)
              rest
      in
      validate_expected ~previous_attempt_succeeded:false 0 sorted_close_events
    in
    let rec validate_command command_index =
      if command_index = command_count then Ok ()
      else
        match
          validate_attempts command_index close_events_by_command.(command_index)
        with
        | Error error -> Error error
        | Ok () -> validate_command (command_index + 1)
      in
      validate_command 0
  in
  let rec validate = function
    | [] -> validate_contiguous_attempts ()
    | close_event :: rest ->
      let command = Close_event.command close_event in
      let index = Command.index command in
      let attempt = Close_event.attempt close_event in
      if index < 0 || index >= command_count then
        Error (`Unknown_command_index index)
      else if not (Command.equal command commands.(index)) then
        Error (`Unexpected_command index)
      else if Run_policy.attempt_exceeds_restart_limit policy ~attempt then
        Error (`Attempt_exceeds_restart_tries (index, attempt))
      else
        let seen_close_events = close_events_by_command.(index) in
        if
          List.exists
            (fun seen_close_event ->
              Close_event.attempt seen_close_event = attempt)
            seen_close_events
        then
          Error (`Duplicate_close_event_attempt (index, attempt))
        else (
          close_events_by_command.(index) <- close_event :: seen_close_events;
          validate rest)
  in
  validate close_events

let final_close_events ~command_count close_events =
  let final_events = Array.make command_count None in
  List.iter
    (fun close_event ->
      let command_index = Command.index (Close_event.command close_event) in
      match final_events.(command_index) with
      | None -> final_events.(command_index) <- Some close_event
      | Some existing_close_event ->
        if Close_event.attempt close_event >= Close_event.attempt existing_close_event
        then final_events.(command_index) <- Some close_event)
    close_events;
  final_events

let cancelling_command_indexes policy close_events =
  close_events
  |> List.filter_map (fun close_event ->
    if
      (not (Close_event.killed close_event))
      && Run_policy.close_event_completes_command policy close_event
      && Run_policy.should_kill_after_close policy close_event
    then Some (Command.index (Close_event.command close_event))
    else None)
  |> List.sort_uniq Int.compare

let has_cancelling_complete_close_event policy close_events =
  cancelling_command_indexes policy close_events <> []

let validate_complete_close_events ~command_count ~policy close_events =
  let final_events = final_close_events ~command_count close_events in
  let rec validate command_index =
    if command_index = command_count then Ok ()
    else
      match final_events.(command_index) with
      | None -> Error `Missing_close_events
      | Some close_event ->
        if Run_policy.close_event_completes_command policy close_event then
          validate (command_index + 1)
        else
          Error
            (`Incomplete_restart_attempt
              (command_index, Close_event.attempt close_event))
  in
  validate 0

let create_internal ~interrupted_signal ~spec ~close_events ~output_event_count
    ~interrupted =
  let close_event_count = List.length close_events in
  let commands = Array.of_list (Run_spec.commands spec) in
  let command_count = Array.length commands in
  let policy = Run_spec.policy spec in
  let interrupted_signal =
    if interrupted then interrupted_signal else None
  in
  if output_event_count < 0 then Error `Negative_output_event_count
  else if close_event_count > Run_spec.close_event_capacity spec then
    Error `Too_many_close_events
  else
    match validate_close_events ~commands ~policy close_events with
    | Error error -> Error error
    | Ok () ->
      if
        (not interrupted)
        && not
             (has_cancelling_complete_close_event policy close_events)
      then
        validate_complete_close_events
          ~command_count
          ~policy
          close_events
        |> Result.map (fun () ->
          {
            spec;
            close_events;
            output_event_count;
            interrupted;
            interrupted_signal;
          })
      else
        Ok
          {
            spec;
            close_events;
            output_event_count;
            interrupted;
            interrupted_signal;
          }

let spec t = t.spec
let close_events t = t.close_events
let output_event_count t = t.output_event_count
let interrupted t = t.interrupted

let create ~spec ~close_events ~output_event_count ~interrupted =
  create_internal ~interrupted_signal:None ~spec ~close_events
    ~output_event_count ~interrupted

let create_interrupted_by_signal ~signal ~spec ~close_events ~output_event_count =
  create_internal ~interrupted_signal:(Some signal) ~spec ~close_events
    ~output_event_count ~interrupted:true

let close_events_for_exit t =
  let policy = Run_spec.policy t.spec in
  match cancelling_command_indexes policy t.close_events with
  | [] -> t.close_events
  | cancelling_command_indexes ->
    (* npm -k still evaluates the configured success condition after sibling
       cancellation. Signaled siblings remain failures, but a sibling that traps
       the signal and exits 0 still satisfies the default "all" condition. *)
    List.filter
      (fun close_event ->
        let command_index = Command.index (Close_event.command close_event) in
        List.mem command_index cancelling_command_indexes
        || Run_policy.close_event_completes_command policy close_event)
      t.close_events

let exit_code t =
  if t.interrupted then
    match t.interrupted_signal with
    | Some signal when signal = Sys.sigint -> 0
    | Some _ ->
        if
          Run_policy.run_succeeded
            (Run_spec.policy t.spec)
            (close_events_for_exit t)
        then 0
        else 1
    | None -> 1
  else if
    Run_policy.run_succeeded
      (Run_spec.policy t.spec)
      (close_events_for_exit t)
  then 0
  else 1
