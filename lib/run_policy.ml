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

type t =
  { kill_others_on : kill_condition list
  ; kill_signal : kill_signal
  ; kill_timeout_ms : int option
  ; max_processes : int option
  ; success_condition : success_condition
  ; restart_tries : int
  ; restart_delay : restart_delay
  ; teardown : Command.t list
  }

type create_error =
  [ `Duplicate_kill_condition
  | `Empty_signal
  | `Exponential_restart_delay_overflow
  | `Max_processes_less_than_one
  | `Negative_kill_timeout_ms
  | `Negative_success_command_index
  | `Negative_restart_delay_ms
  | `Negative_restart_tries
  ]

let default =
  { kill_others_on = []
  ; kill_signal = Sigterm
  ; kill_timeout_ms = None
  ; max_processes = None
  ; success_condition = All
  ; restart_tries = 0
  ; restart_delay = Fixed_delay_ms 0
  ; teardown = []
  }

let has_duplicates values =
  List.length values <> List.length (List.sort_uniq Stdlib.compare values)

let validate_signal = function
  | Sigterm | Sigkill -> Ok ()
  | Named_signal signal ->
    if String.trim signal = "" then Error `Empty_signal else Ok ()

let validate_restart_delay = function
  | Fixed_delay_ms delay_ms ->
    if delay_ms < 0 then Error `Negative_restart_delay_ms else Ok ()
  | Exponential_backoff -> Ok ()

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
  | Exponential_backoff ->
    if restart_tries = 0 then Ok ()
    else
      match exponential_delay_ms ~next_attempt:restart_tries with
      | Some _ -> Ok ()
      | None -> Error `Exponential_restart_delay_overflow

let validate_success_condition = function
  | All | First | Last | NoCommands -> Ok ()
  | Commands indexes ->
    if List.exists (fun index -> index < 0) indexes then
      Error `Negative_success_command_index
    else Ok ()

let create ?(kill_others_on = []) ?(kill_signal = default.kill_signal)
    ?kill_timeout_ms ?max_processes
    ?(success_condition = default.success_condition)
    ?(restart_tries = default.restart_tries)
    ?(restart_delay = default.restart_delay) ?(teardown = []) () =
  if has_duplicates kill_others_on then Error `Duplicate_kill_condition
  else
    match validate_signal kill_signal with
    | Error error -> Error error
    | Ok () ->
      (match max_processes with
       | Some value when value < 1 -> Error `Max_processes_less_than_one
       | Some _ | None ->
         (match kill_timeout_ms with
          | Some value when value < 0 -> Error `Negative_kill_timeout_ms
          | Some _ | None ->
            (match validate_success_condition success_condition with
             | Error error -> Error error
             | Ok () ->
               if restart_tries < 0 then Error `Negative_restart_tries
               else
                 match validate_restart_delay restart_delay with
                 | Error error -> Error error
                 | Ok () ->
                   (match validate_restart_delay_bounds ~restart_tries restart_delay with
                    | Error error -> Error error
                    | Ok () ->
                      Ok
                        { kill_others_on
                        ; kill_signal
                        ; kill_timeout_ms
                        ; max_processes
                        ; success_condition
                        ; restart_tries
                        ; restart_delay
                        ; teardown
                        }))))

let kill_others_on t = t.kill_others_on
let kill_signal t = t.kill_signal
let kill_timeout_ms t = t.kill_timeout_ms
let max_processes t = t.max_processes
let success_condition t = t.success_condition
let restart_tries t = t.restart_tries
let restart_delay t = t.restart_delay
let restart_delay_ms t ~next_attempt =
  match t.restart_delay with
  | Fixed_delay_ms delay_ms -> delay_ms
  | Exponential_backoff ->
    (match exponential_delay_ms ~next_attempt with
     | Some delay_ms -> delay_ms
     | None -> assert false)
let teardown t = t.teardown

let condition_matches_close t condition close_event =
  match condition with
  | Success -> Close_event.is_success close_event
  | Failure ->
    (not (Close_event.killed close_event))
    &&
    (not (Close_event.is_success close_event))
    && Close_event.attempt close_event >= t.restart_tries

let should_kill_after_close t close_event =
  List.exists
    (fun condition -> condition_matches_close t condition close_event)
    t.kill_others_on

let replace_final_attempt command_index close_event close_events =
  match List.assoc_opt command_index close_events with
  | None -> (command_index, close_event) :: close_events
  | Some existing_close_event ->
    if Close_event.attempt close_event >= Close_event.attempt existing_close_event
    then (command_index, close_event) :: List.remove_assoc command_index close_events
    else close_events

let final_attempts close_events =
  close_events
  |> List.fold_left
       (fun final_events close_event ->
         let command_index = Command.index (Close_event.command close_event) in
         replace_final_attempt command_index close_event final_events)
       []
  |> List.sort (fun (left_index, left_close_event) (right_index, right_close_event) ->
    let left_ended_at = (Close_event.timings left_close_event).ended_at in
    let right_ended_at = (Close_event.timings right_close_event).ended_at in
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
    Command.index (Close_event.command close_event), close_event)

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
  let final_close_events = final_attempts close_events in
  match t.success_condition with
  | All ->
    final_close_events <> []
    && List.for_all Close_event.is_success final_close_events
  | First ->
    (match final_close_events with
     | [] -> false
     | first :: _ -> Close_event.is_success first)
  | Last ->
    (match last final_close_events with
     | None -> false
     | Some close_event -> Close_event.is_success close_event)
  | Commands command_indexes ->
    command_indexes_succeeded command_indexes final_close_events
  | NoCommands -> true
