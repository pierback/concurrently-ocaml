type kill_condition = Success | Failure
type kill_signal = Sigterm | Sigkill | Named_signal of string

type success_condition =
  | All
  | First
  | Last
  | Commands of int list
  | NoCommands

type restart_delay = Fixed_delay_ms of int | Exponential_backoff
type restart_limit = Finite_restarts of int | Infinite_restarts
type timer_warning = Timeout_nan | Timeout_negative of string

type t = {
  kill_others_on : kill_condition list;
  kill_signal : kill_signal;
  kill_timeout_ms : int option;
  kill_timeout_warning : timer_warning option;
  max_processes : int option;
  success_condition : success_condition;
  drop_failed_close_events_for_success : bool;
  restart_limit : restart_limit;
  restart_delay : restart_delay;
  restart_delay_warning : timer_warning option;
  teardown : Command.t list;
}

type create_error =
  [ `Duplicate_kill_condition
  | `Empty_signal
  | `Exponential_restart_delay_overflow
  | `Max_processes_less_than_one
  | `Negative_success_command_index ]

let default =
  {
    kill_others_on = [];
    kill_signal = Sigterm;
    kill_timeout_ms = None;
    kill_timeout_warning = None;
    max_processes = None;
    success_condition = All;
    drop_failed_close_events_for_success = false;
    restart_limit = Finite_restarts 0;
    restart_delay = Fixed_delay_ms 0;
    restart_delay_warning = None;
    teardown = [];
  }

let has_duplicates values =
  List.length values <> List.length (List.sort_uniq Stdlib.compare values)

let validate_signal = function
  | Sigterm | Sigkill -> Ok ()
  | Named_signal signal ->
      if String.trim signal = "" then Error `Empty_signal else Ok ()

let exponential_delay_ms ~next_attempt =
  assert (next_attempt > 0);
  let rec double remaining delay_ms =
    if remaining = 0 then Some delay_ms
    else if delay_ms > max_int / 2 then None
    else double (remaining - 1) (delay_ms * 2)
  in
  double (next_attempt - 1) 1000

let validate_restart_delay_bounds ~restart_tries = function
  | Fixed_delay_ms _ -> Ok ()
  | Exponential_backoff -> (
      if restart_tries = 0 then Ok ()
      else
        match exponential_delay_ms ~next_attempt:restart_tries with
        | Some _ -> Ok ()
        | None -> Error `Exponential_restart_delay_overflow)

let restart_limit_of_tries restart_tries =
  if restart_tries < 0 then Infinite_restarts else Finite_restarts restart_tries

let validate_restart_limit_delay_bounds restart_limit restart_delay =
  match restart_limit with
  | Infinite_restarts -> Ok ()
  | Finite_restarts restart_tries ->
      validate_restart_delay_bounds ~restart_tries restart_delay

let validate_success_condition = function
  | All | First | Last | NoCommands -> Ok ()
  | Commands indexes ->
      if List.exists (fun index -> index < 0) indexes then
        Error `Negative_success_command_index
      else Ok ()

let create ?(kill_others_on = []) ?(kill_signal = default.kill_signal)
    ?kill_timeout_ms ?max_processes
    ?(success_condition = default.success_condition)
    ?(drop_failed_close_events_for_success = false) ?(restart_tries = 0)
    ?(restart_delay = default.restart_delay) ?restart_delay_warning
    ?kill_timeout_warning ?(teardown = []) () =
  if has_duplicates kill_others_on then Error `Duplicate_kill_condition
  else
    match validate_signal kill_signal with
    | Error error -> Error error
    | Ok () -> (
        match max_processes with
        | Some value when value < 1 -> Error `Max_processes_less_than_one
        | Some _ | None -> (
            match validate_success_condition success_condition with
            | Error error -> Error error
            | Ok () -> (
                let restart_limit = restart_limit_of_tries restart_tries in
                match
                  validate_restart_limit_delay_bounds restart_limit
                    restart_delay
                with
                | Error error -> Error error
                | Ok () ->
                    Ok
                      {
                        kill_others_on;
                        kill_signal;
                        kill_timeout_ms;
                        kill_timeout_warning;
                        max_processes;
                        success_condition;
                        drop_failed_close_events_for_success;
                        restart_limit;
                        restart_delay;
                        restart_delay_warning;
                        teardown;
                      })))

let kill_others_on t = t.kill_others_on
let kill_signal t = t.kill_signal
let kill_timeout_ms t = t.kill_timeout_ms
let max_processes t = t.max_processes
let success_condition t = t.success_condition

let drop_failed_close_events_for_success t =
  t.drop_failed_close_events_for_success

let restart_tries t =
  match t.restart_limit with
  | Finite_restarts restart_tries -> restart_tries
  | Infinite_restarts -> -1

let restart_limit t = t.restart_limit
let restart_delay t = t.restart_delay
let restart_delay_warning t = t.restart_delay_warning
let kill_timeout_warning t = t.kill_timeout_warning

let restart_delay_ms t ~next_attempt =
  match t.restart_delay with
  | Fixed_delay_ms delay_ms -> delay_ms
  | Exponential_backoff -> (
      match exponential_delay_ms ~next_attempt with
      | Some delay_ms -> delay_ms
      | None -> max_int)

let teardown t = t.teardown

let attempt_exceeds_restart_limit t ~attempt =
  match t.restart_limit with
  | Infinite_restarts -> false
  | Finite_restarts restart_tries -> attempt > restart_tries

let should_retry t close_event =
  (not (Close_event.killed close_event))
  && (not (Close_event.is_success close_event))
  &&
  match t.restart_limit with
  | Infinite_restarts -> true
  | Finite_restarts restart_tries ->
      Close_event.attempt close_event < restart_tries

let close_event_completes_command t close_event =
  Close_event.killed close_event
  || Close_event.is_success close_event
  ||
  match t.restart_limit with
  | Infinite_restarts -> false
  | Finite_restarts restart_tries ->
      Close_event.attempt close_event >= restart_tries

let collect_retry_close_events t =
  match t.restart_limit with
  | Finite_restarts _ -> true
  | Infinite_restarts -> false

let close_event_capacity t ~command_count =
  match t.restart_limit with
  | Infinite_restarts -> Ok command_count
  | Finite_restarts restart_tries ->
      if restart_tries = max_int then Error `Close_event_capacity_overflow
      else
        let attempt_count = restart_tries + 1 in
        if command_count > max_int / attempt_count then
          Error `Close_event_capacity_overflow
        else Ok (command_count * attempt_count)

let condition_matches_close t condition close_event =
  match condition with
  | Success -> Close_event.is_success close_event
  | Failure ->
      (not (Close_event.killed close_event))
      && (not (Close_event.is_success close_event))
      && close_event_completes_command t close_event

let should_kill_after_close t close_event =
  List.exists
    (fun condition -> condition_matches_close t condition close_event)
    t.kill_others_on

let replace_final_attempt command_index close_event close_events =
  match List.assoc_opt command_index close_events with
  | None -> (command_index, close_event) :: close_events
  | Some existing_close_event ->
      if
        Close_event.attempt close_event
        >= Close_event.attempt existing_close_event
      then
        (command_index, close_event)
        :: List.remove_assoc command_index close_events
      else close_events

let final_attempts close_events =
  close_events
  |> List.fold_left
       (fun final_events close_event ->
         let command_index = Command.index (Close_event.command close_event) in
         replace_final_attempt command_index close_event final_events)
       []
  |> List.sort
       (fun (left_index, left_close_event) (right_index, right_close_event) ->
         let left_ended_at = (Close_event.timings left_close_event).ended_at in
         let right_ended_at =
           (Close_event.timings right_close_event).ended_at
         in
         match Float.compare left_ended_at right_ended_at with
         | 0 -> Int.compare left_index right_index
         | order -> order)
  |> List.map snd

let rec last = function
  | [] -> None
  | [ value ] -> Some value
  | _ :: rest -> last rest

let close_event_by_command_index close_events =
  close_events
  |> List.map (fun close_event ->
      (Command.index (Close_event.command close_event), close_event))

let command_indexes_succeeded required_indexes close_events =
  let close_event_by_index = close_event_by_command_index close_events in
  required_indexes <> []
  && List.for_all
       (fun command_index ->
         match List.assoc_opt command_index close_event_by_index with
         | None -> false
         | Some close_event -> Close_event.is_success close_event)
       required_indexes

let run_succeeded t close_events =
  let final_close_events =
    let events = final_attempts close_events in
    if t.drop_failed_close_events_for_success then
      List.filter Close_event.is_success events
    else events
  in
  if t.drop_failed_close_events_for_success && final_close_events = [] then true
  else
    match t.success_condition with
    | All ->
        final_close_events <> []
        && List.for_all Close_event.is_success final_close_events
    | First -> (
        match final_close_events with
        | [] -> false
        | first :: _ -> Close_event.is_success first)
    | Last -> (
        match last final_close_events with
        | None -> false
        | Some close_event -> Close_event.is_success close_event)
    | Commands command_indexes ->
        command_indexes_succeeded command_indexes final_close_events
    | NoCommands -> true
