type t =
  { commands : Command.t list
  ; policy : Run_policy.t
  ; close_event_capacity : int
  }

type create_error =
  [ `Close_event_capacity_overflow
  | `Command_index_mismatch of int * int
  | `Empty_command_list
  ]

let rec validate_command_indexes expected_index = function
  | [] -> Ok ()
  | command :: rest ->
    let actual_index = Command.index command in
    if actual_index <> expected_index then
      Error (`Command_index_mismatch (expected_index, actual_index))
    else validate_command_indexes (expected_index + 1) rest

let calculate_close_event_capacity ~command_count ~restart_tries =
  if restart_tries = max_int then Error `Close_event_capacity_overflow
  else
    let attempt_count = restart_tries + 1 in
    if command_count > max_int / attempt_count then
    Error `Close_event_capacity_overflow
    else Ok (command_count * attempt_count)

let create ~commands ~policy =
  match commands with
  | [] -> Error `Empty_command_list
  | _ ->
    (match validate_command_indexes 0 commands with
     | Error error -> Error error
     | Ok () ->
       let command_count = List.length commands in
       let restart_tries = Run_policy.restart_tries policy in
       (match calculate_close_event_capacity ~command_count ~restart_tries with
        | Error error -> Error error
        | Ok close_event_capacity -> Ok { commands; policy; close_event_capacity }))

let commands t = t.commands
let policy t = t.policy
let command_count t = List.length t.commands
let close_event_capacity t = t.close_event_capacity
