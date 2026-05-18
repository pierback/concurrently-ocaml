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

let create_internal ~allow_empty ~commands ~policy : (t, create_error) result =
  match commands with
  | [] when not allow_empty -> Error `Empty_command_list
  | _ ->
    (match validate_command_indexes 0 commands with
     | Error error -> Error error
     | Ok () ->
       let command_count = List.length commands in
       (match Run_policy.close_event_capacity policy ~command_count with
        | Error error -> Error (error :> create_error)
        | Ok close_event_capacity -> Ok { commands; policy; close_event_capacity }))

let create ~commands ~policy =
  create_internal ~allow_empty:false ~commands ~policy

let create_empty ~policy =
  create_internal ~allow_empty:true ~commands:[] ~policy

let commands t = t.commands
let policy t = t.policy
let command_count t = List.length t.commands
let close_event_capacity t = t.close_event_capacity
