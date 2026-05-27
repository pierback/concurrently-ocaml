type route =
  { target_index : int
  ; target_label : string
  ; payload : string
  }

type t =
  { commands : Command.t list
  ; index_labels : string array option
  ; default_target : string
  ; default_target_index : int option
  }

type create_error =
  [ `Empty_default_input_target ]

let command_index_label index_labels command_index =
  match index_labels with
  | Some labels when command_index < Array.length labels -> labels.(command_index)
  | Some _ | None -> string_of_int command_index

let resolve_target ?index_labels commands token =
  let rec loop resolved = function
    | [] -> resolved
    | command :: rest ->
      let command_index = Command.index command in
      let resolved =
        if String.equal token (command_index_label index_labels command_index)
        then
          Some command_index
        else resolved
      in
      let resolved =
        match Command.name command with
        | Some name when String.equal token name -> Some command_index
        | Some _ | None -> resolved
      in
      loop resolved rest
  in
  loop None commands

let create ~commands ~index_labels ~default_input_target =
  let target = String.trim default_input_target in
  let target = if String.equal target "" then "0" else target in
  let index_labels = Option.map Array.of_list index_labels in
  Ok
    {
      commands;
      index_labels;
      default_target = target;
      default_target_index = resolve_target ?index_labels commands target;
    }

let split_target_prefix input =
  match String.index_opt input ':' with
  | Some separator when separator + 1 < String.length input ->
    Some
      ( String.sub input 0 separator
      , String.sub
          input
          (separator + 1)
          (String.length input - separator - 1) )
  | Some _ | None -> None

let route t input =
  match split_target_prefix input with
  | Some (target, payload) ->
    (match resolve_target ?index_labels:t.index_labels t.commands target with
     | Some target_index -> { target_index; target_label = target; payload }
     | None ->
       { target_index = Option.value ~default:(-1) t.default_target_index
       ; target_label = t.default_target
       ; payload = input
       })
  | None ->
    { target_index = Option.value ~default:(-1) t.default_target_index
    ; target_label = t.default_target
    ; payload = input
    }

let error_message = function
  | `Empty_default_input_target -> "default input target must not be empty"
