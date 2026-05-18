type route =
  { target_index : int
  ; payload : string
  }

type t =
  { commands : Command.t list
  ; default_target_index : int
  }

type create_error =
  [ `Empty_default_input_target
  | `Unknown_default_input_target of string
  ]

let resolve_target commands token =
  let rec loop resolved = function
    | [] -> resolved
    | command :: rest ->
      let command_index = Command.index command in
      let resolved =
        if String.equal token (string_of_int command_index) then
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

let create ~commands ~default_input_target =
  let target = String.trim default_input_target in
  if String.equal target "" then Error `Empty_default_input_target
  else
    match resolve_target commands target with
    | Some default_target_index -> Ok { commands; default_target_index }
    | None -> Error (`Unknown_default_input_target default_input_target)

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
    (match resolve_target t.commands target with
     | Some target_index -> { target_index; payload }
     | None -> { target_index = t.default_target_index; payload = input })
  | None -> { target_index = t.default_target_index; payload = input }

let error_message = function
  | `Empty_default_input_target -> "default input target must not be empty"
  | `Unknown_default_input_target target ->
    Printf.sprintf "unknown default input target: %s" target
