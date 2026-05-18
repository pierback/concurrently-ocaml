type display =
  { labels : string list option
  ; prefix : string option
  ; prefix_length : int
  ; pad_prefix : bool
  ; timestamp_format : string
  ; spacious : bool
  ; timings : bool
  ; no_color : bool
  }

type t =
  { spec : Run_spec.t
  ; display : display
  ; input : Input_router.t option
  }

type create_error =
  [ `Command_error of int * Command.create_error
  | `Empty_command_name of int
  | `Empty_name_separator
  | `Input_router_error of Input_router.create_error
  | `Invalid_restart_after of string
  | `Invalid_success_condition of string
  | `Name_count_mismatch of int * int
  | `Run_policy_error of Run_policy.create_error
  | `Run_spec_error of Run_spec.create_error
  ]

let split_on_separator ~separator value =
  let separator_length = String.length separator in
  assert (separator_length > 0);
  let value_length = String.length value in
  let rec find_separator index =
    if index + separator_length > value_length then None
    else if String.sub value index separator_length = separator then Some index
    else find_separator (index + 1)
  in
  let rec loop start names =
    if start > value_length then List.rev names
    else
      match find_separator start with
      | None ->
        String.sub value start (value_length - start) :: names |> List.rev
      | Some index ->
        let name = String.sub value start (index - start) in
        loop (index + separator_length) (name :: names)
  in
  loop 0 []

let split_names ~separator = function
  | None -> Ok None
  | Some names_csv ->
    if separator = "" then Error `Empty_name_separator
    else
      let names = split_on_separator ~separator names_csv in
      (* npm concurrently preserves spaces around name separators. Trim only for
         rejecting names that are blank after whitespace. *)
      let rec validate index = function
        | [] -> Ok (Some names)
        | name :: rest ->
          if String.trim name = "" then Error (`Empty_command_name index)
          else validate (index + 1) rest
      in
      validate 0 names

let name_at names index =
  match names with
  | None -> None
  | Some values -> Some (List.nth values index)

let validate_name_count ~command_count = function
  | None -> Ok ()
  | Some names ->
    let name_count = List.length names in
    if name_count = command_count then Ok ()
    else Error (`Name_count_mismatch (name_count, command_count))

let indexes_for_name names token =
  names
  |> List.mapi (fun index name -> index, name)
  |> List.filter_map (fun (index, name) ->
    if String.equal name token then Some index else None)

let indexes_for_token ~command_count ~names token =
  let by_index =
    match int_of_string_opt token with
    | Some index when index >= 0 && index < command_count -> [ index ]
    | Some _ | None -> []
  in
  let by_name =
    match names with
    | None -> []
    | Some values -> indexes_for_name values token
  in
  List.rev_append by_name by_index

let hidden_indexes ~command_count ~names hide_csv =
  match hide_csv with
  | None -> []
  | Some csv ->
    csv
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun token -> not (String.equal token ""))
    |> List.concat_map (indexes_for_token ~command_count ~names)
    |> List.sort_uniq Int.compare

let split_csv = function
  | None -> []
  | Some csv ->
    csv
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun token -> not (String.equal token ""))

let last = function
  | [] -> None
  | first :: rest -> Some (List.fold_left (fun _ item -> item) first rest)

let prefix_color_at prefix_colors index =
  match prefix_colors with
  | [] -> None
  | _ ->
    (match List.nth_opt prefix_colors index with
     | Some prefix_color -> Some prefix_color
     | None -> last prefix_colors)

let kill_signal_of_string signal =
  match String.uppercase_ascii (String.trim signal) with
  | "SIGTERM" | "TERM" -> Run_policy.Sigterm
  | "SIGKILL" | "KILL" -> Run_policy.Sigkill
  | named_signal -> Run_policy.Named_signal named_signal

let kill_conditions ~kill_others ~kill_others_on_fail =
  if kill_others then [ Run_policy.Success; Run_policy.Failure ]
  else if kill_others_on_fail then [ Run_policy.Failure ]
  else []

let starts_with ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let success_selector_indexes ~command_count ~names selector =
  selector
  |> indexes_for_token ~command_count ~names
  |> List.sort_uniq Int.compare

let command_indexes command_count = List.init command_count Fun.id

let success_condition_except ~command_count ~names selector =
  let excluded_indexes = success_selector_indexes ~command_count ~names selector in
  let required_indexes =
    command_indexes command_count
    |> List.filter (fun index -> not (List.mem index excluded_indexes))
  in
  match required_indexes with
  | [] -> Run_policy.NoCommands
  | _ :: _ -> Run_policy.Commands required_indexes

let success_condition_of_string ~command_count ~names success =
  let value = String.trim success in
  match String.lowercase_ascii value with
  | "all" -> Ok Run_policy.All
  | "first" -> Ok Run_policy.First
  | "last" -> Ok Run_policy.Last
  | _ ->
    (* npm treats unmatched command selectors as valid: positive selectors can
       never succeed, while negated selectors exclude no commands. *)
    if starts_with ~prefix:"!command-" value then
      let selector = String.sub value 9 (String.length value - 9) in
      if selector = "" then Error (`Invalid_success_condition success)
      else Ok (success_condition_except ~command_count ~names selector)
    else if starts_with ~prefix:"command-" value then
      let selector = String.sub value 8 (String.length value - 8) in
      if selector = "" then Error (`Invalid_success_condition success)
      else
        Ok
          (Run_policy.Commands
             (success_selector_indexes ~command_count ~names selector))
    else Error (`Invalid_success_condition success)

let restart_delay_of_string restart_after =
  let value = String.trim restart_after in
  match String.lowercase_ascii value with
  | "exponential" -> Ok Run_policy.Exponential_backoff
  | _ ->
    (match int_of_string_opt value with
     | Some delay_ms -> Ok (Run_policy.Fixed_delay_ms delay_ms)
     | None -> Error (`Invalid_restart_after restart_after))

let create_commands ~names ~raw ~hidden_indexes ~prefix_colors command_texts =
  let rec create index = function
    | [] -> Ok []
    | command_text :: rest ->
      (match
         Command.create
           ?name:(name_at names index)
           ?prefix_color:(prefix_color_at prefix_colors index)
           ~raw
           ~hidden:(List.mem index hidden_indexes)
           ~index
           command_text
       with
       | Error error -> Error (`Command_error (index, error))
       | Ok command ->
         (match create (index + 1) rest with
          | Error error -> Error error
          | Ok commands -> Ok (command :: commands)))
  in
  create 0 command_texts

let create_teardown_commands ~main_command_count teardown_texts =
  let rec create offset = function
    | [] -> Ok []
    | command_text :: rest ->
      let index = main_command_count + offset in
      (match Command.create ~raw:true ~index command_text with
       | Error error -> Error (`Command_error (index, error))
       | Ok command ->
         (match create (offset + 1) rest with
          | Error error -> Error error
          | Ok commands -> Ok (command :: commands)))
  in
  create 0 teardown_texts

let create_input_router ~handle_input ~commands ~default_input_target =
  if not handle_input then Ok None
  else
    match Input_router.create ~commands ~default_input_target with
    | Ok router -> Ok (Some router)
    | Error error -> Error (`Input_router_error error)

let create ~teardown_texts ~command_texts ~names_csv ~name_separator ~spacious
    ~timings ~raw ~hide_csv ~no_color ~prefix ~prefix_colors_csv ~prefix_length
    ~pad_prefix ~timestamp_format ~handle_input ~default_input_target ~success
    ~kill_others ~kill_others_on_fail ~kill_signal ~kill_timeout_ms ~max_processes
    ~restart_tries ~restart_after =
  let command_count = List.length command_texts in
  match split_names ~separator:name_separator names_csv with
  | Error error -> Error error
  | Ok names ->
    (match validate_name_count ~command_count names with
     | Error error -> Error error
     | Ok () ->
       let hidden_indexes = hidden_indexes ~command_count ~names hide_csv in
       let prefix_colors = split_csv prefix_colors_csv in
       (match create_commands ~names ~raw ~hidden_indexes ~prefix_colors command_texts with
        | Error error -> Error error
        | Ok commands ->
          (match
             create_input_router ~handle_input ~commands ~default_input_target
           with
           | Error error -> Error error
           | Ok input ->
             (match create_teardown_commands ~main_command_count:command_count teardown_texts with
              | Error error -> Error error
              | Ok teardown ->
             let kill_others_on = kill_conditions ~kill_others ~kill_others_on_fail in
             let kill_signal = kill_signal_of_string kill_signal in
             (match success_condition_of_string ~command_count ~names success with
              | Error error -> Error error
              | Ok success_condition ->
                (match restart_delay_of_string restart_after with
                 | Error error -> Error error
                 | Ok restart_delay ->
                   (match
                      Run_policy.create
                        ~kill_others_on
                        ~kill_signal
                        ?kill_timeout_ms
                        ~success_condition
                        ~restart_tries
                        ~restart_delay
                        ~teardown
                        ?max_processes
                        ()
                    with
                    | Error error -> Error (`Run_policy_error error)
                    | Ok policy ->
                      (match Run_spec.create ~commands ~policy with
                       | Error error -> Error (`Run_spec_error error)
                       | Ok spec ->
                         Ok
                           { spec
                           ; display =
                               { labels = names
                               ; prefix
                               ; prefix_length
                               ; pad_prefix
                               ; timestamp_format
                               ; spacious
                               ; timings
                               ; no_color
                               }
                           ; input
                           }))))))))

let spec t = t.spec
let commands t = Run_spec.commands t.spec
let policy t = Run_spec.policy t.spec
let display t = t.display
let input t = t.input

let command_error_message = function
  | `Empty_command -> "command text must not be empty"
  | `Negative_index -> "command index must not be negative"

let run_policy_error_message = function
  | `Duplicate_kill_condition -> "kill conditions must not contain duplicates"
  | `Empty_signal -> "kill signal must not be empty"
  | `Exponential_restart_delay_overflow ->
    "exponential restart delay overflows integer bounds"
  | `Max_processes_less_than_one -> "max processes must be at least 1"
  | `Negative_kill_timeout_ms -> "kill timeout must not be negative"
  | `Negative_success_command_index ->
    "success condition command index must not be negative"
  | `Negative_restart_delay_ms -> "restart delay must not be negative"
  | `Negative_restart_tries -> "restart tries must not be negative"

let run_spec_error_message = function
  | `Close_event_capacity_overflow -> "close event capacity overflow"
  | `Command_index_mismatch (expected, actual) ->
    Printf.sprintf
      "command index mismatch: expected %d but got %d"
      expected
      actual
  | `Empty_command_list -> "at least one command is required"

let error_message = function
  | `Command_error (index, error) ->
    Printf.sprintf
      "command %d is invalid: %s"
      index
      (command_error_message error)
  | `Empty_command_name index ->
    Printf.sprintf "command name %d must not be empty" index
  | `Empty_name_separator -> "name separator must not be empty"
  | `Input_router_error error -> Input_router.error_message error
  | `Invalid_restart_after value ->
    Printf.sprintf "invalid restart delay: %s" value
  | `Invalid_success_condition value ->
    Printf.sprintf "invalid success condition: %s" value
  | `Name_count_mismatch (name_count, command_count) ->
    Printf.sprintf
      "number of names (%d) must match number of commands (%d)"
      name_count
      command_count
  | `Run_policy_error error -> run_policy_error_message error
  | `Run_spec_error error -> run_spec_error_message error
