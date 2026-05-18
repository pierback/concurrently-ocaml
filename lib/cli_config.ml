type display =
  { labels : string list option
  ; prefix : string option
  ; prefix_length : int
  ; pad_prefix : bool
  ; timestamp_format : string
  ; spacious : bool
  ; timings : bool
  ; group : bool
  ; raw : bool
  ; no_color : bool
  }

type t =
  { spec : Run_spec.t
  ; display : display
  ; input : Input_router.t option
  ; no_op : bool
  }

type command_input =
  { command_text : string
  ; command_name : string
  ; has_command_name : bool
  ; command_cwd : string option
  ; command_env : (string * string) list
  ; command_raw : bool option
  }

type create_error =
  [ `Command_error of int * Command.create_error
  | `Duplicate_api_command_field of int * string
  | `Empty_name_separator
  | `Invalid_api_command_name of string
  | `Invalid_api_command_cwd of string
  | `Invalid_api_command_env of string
  | `Invalid_api_command_raw of string
  | `Input_router_error of Input_router.create_error
  | `Invalid_max_processes of string
  | `Invalid_restart_after of string
  | `Invalid_success_condition of string
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
    else Ok (Some (split_on_separator ~separator names_csv))

let name_at names index =
  match names with
  | None -> None
  | Some values -> List.nth_opt values index

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

type api_command_overrides =
  { names : string option array
  ; cwds : string option array
  ; envs : (string * string) list array
  ; raws : bool option array
  }

let split_api_index_value entry =
  match String.index_opt entry '=' with
  | None -> None
  | Some separator ->
    let index_text = String.sub entry 0 separator in
    let value =
      String.sub entry (separator + 1) (String.length entry - separator - 1)
    in
    (match int_of_string_opt index_text with
     | Some index when index >= 0 -> Some (index, value)
     | Some _ | None -> None)

let validate_api_command_index ~command_count entry index =
  if index < command_count then Ok ()
  else Error entry

let parse_api_command_names ~command_count entries overrides =
  let rec loop = function
    | [] -> Ok ()
    | entry :: rest ->
      (match split_api_index_value entry with
       | None -> Error (`Invalid_api_command_name entry)
       | Some (index, name) ->
         (match validate_api_command_index ~command_count entry index with
          | Error entry -> Error (`Invalid_api_command_name entry)
          | Ok () ->
            (match overrides.names.(index) with
             | Some _ -> Error (`Duplicate_api_command_field (index, "name"))
             | None ->
               overrides.names.(index) <- Some name;
               loop rest)))
  in
  loop entries

let parse_api_command_cwds ~command_count entries overrides =
  let rec loop = function
    | [] -> Ok ()
    | entry :: rest ->
      (match split_api_index_value entry with
       | None -> Error (`Invalid_api_command_cwd entry)
       | Some (index, cwd) ->
         (match validate_api_command_index ~command_count entry index with
          | Error entry -> Error (`Invalid_api_command_cwd entry)
          | Ok () ->
            (match overrides.cwds.(index) with
             | Some _ -> Error (`Duplicate_api_command_field (index, "cwd"))
             | None ->
               overrides.cwds.(index) <- Some cwd;
               loop rest)))
  in
  loop entries

let parse_api_command_envs ~command_count entries overrides =
  let rec loop = function
    | [] -> Ok ()
    | entry :: rest ->
      (match split_api_index_value entry with
       | None -> Error (`Invalid_api_command_env entry)
       | Some (index, assignment) ->
         (match validate_api_command_index ~command_count entry index with
          | Error entry -> Error (`Invalid_api_command_env entry)
          | Ok () ->
            (match String.index_opt assignment '=' with
             | None -> Error (`Invalid_api_command_env entry)
             | Some separator ->
               let key = String.sub assignment 0 separator in
               let value =
                 String.sub
                   assignment
                   (separator + 1)
                   (String.length assignment - separator - 1)
               in
               if String.trim key = "" then Error (`Invalid_api_command_env entry)
               else (
                 overrides.envs.(index) <- (key, value) :: overrides.envs.(index);
                 loop rest))))
  in
  loop entries

let bool_of_api_raw = function
  | "true" | "1" -> Some true
  | "false" | "0" -> Some false
  | _ -> None

let parse_api_command_raws ~command_count entries overrides =
  let rec loop = function
    | [] -> Ok ()
    | entry :: rest ->
      (match split_api_index_value entry with
       | None -> Error (`Invalid_api_command_raw entry)
       | Some (index, value) ->
         (match validate_api_command_index ~command_count entry index with
          | Error entry -> Error (`Invalid_api_command_raw entry)
          | Ok () ->
            (match bool_of_api_raw (String.lowercase_ascii (String.trim value)) with
             | None -> Error (`Invalid_api_command_raw entry)
             | Some raw ->
               (match overrides.raws.(index) with
                | Some _ -> Error (`Duplicate_api_command_field (index, "raw"))
                | None ->
                  overrides.raws.(index) <- Some raw;
                  loop rest))))
  in
  loop entries

let parse_api_command_overrides
    ~command_count
    ~api_command_names
    ~api_command_cwds
    ~api_command_envs
    ~api_command_raws =
  let overrides =
    { names = Array.make command_count None
    ; cwds = Array.make command_count None
    ; envs = Array.make command_count []
    ; raws = Array.make command_count None
    }
  in
  match parse_api_command_names ~command_count api_command_names overrides with
  | Error _ as error -> error
  | Ok () ->
    (match parse_api_command_cwds ~command_count api_command_cwds overrides with
     | Error _ as error -> error
     | Ok () ->
       (match parse_api_command_envs ~command_count api_command_envs overrides with
        | Error _ as error -> error
        | Ok () ->
          (match parse_api_command_raws ~command_count api_command_raws overrides with
           | Error _ as error -> error
           | Ok () ->
             Array.iteri
               (fun index env -> overrides.envs.(index) <- List.rev env)
               overrides.envs;
             Ok overrides)))

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

let ends_with ~suffix value =
  let suffix_length = String.length suffix in
  let value_length = String.length value in
  value_length >= suffix_length
  && String.sub value (value_length - suffix_length) suffix_length = suffix

let finite_float value =
  match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true

let round_nonnegative_to_int value =
  assert (value >= 0.0);
  assert (finite_float value);
  int_of_float (floor (value +. 0.5))

let max_processes_of_string ~cpu_count = function
  | None -> Ok None
  | Some max_processes ->
    assert (cpu_count >= 1);
    let value = String.trim max_processes in
    if value = "" then Error (`Invalid_max_processes max_processes)
    else if ends_with ~suffix:"%" value then
      let percent_text = String.sub value 0 (String.length value - 1) in
      let percent_text = String.trim percent_text in
      (match float_of_string_opt percent_text with
       | Some percent
         when finite_float percent
              && percent >= 0.0
              && (float_of_int cpu_count *. percent /. 100.0)
                 <= float_of_int max_int ->
         let resolved =
           float_of_int cpu_count *. percent /. 100.0
           |> round_nonnegative_to_int
           |> max 1
         in
         Ok (Some resolved)
       | Some _ | None -> Error (`Invalid_max_processes max_processes))
    else
      match int_of_string_opt value with
      | Some count when count >= 1 -> Ok (Some count)
      | Some _ | None -> Error (`Invalid_max_processes max_processes)

let shortcut_runner = function
  | "npm" -> Some "npm run"
  | "yarn" -> Some "yarn run"
  | "pnpm" -> Some "pnpm run"
  | "bun" -> Some "bun run"
  | "node" -> Some "node --run"
  | "deno" -> Some "deno task"
  | _ -> None

let is_whitespace = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let find_first_whitespace_from value start =
  let length = String.length value in
  assert (start >= 0);
  assert (start <= length);
  let rec loop index =
    if index = length then None
    else if is_whitespace value.[index] then Some index
    else loop (index + 1)
  in
  loop start

let option_of_name name =
  if String.equal name "" then None else Some name

let command_input ?command_cwd ?(command_env = []) ?command_raw
    ?(command_name = "") ?(has_command_name = false) command_text =
  { command_text
  ; command_name
  ; has_command_name
  ; command_cwd
  ; command_env
  ; command_raw
  }

let strip_quotes command_input =
  let command_text = command_input.command_text in
  let length = String.length command_text in
  if
    length >= 2
    && ((command_text.[0] = '"' && command_text.[length - 1] = '"')
        || (command_text.[0] = '\'' && command_text.[length - 1] = '\''))
  then
    { command_input with command_text = String.sub command_text 1 (length - 2) }
  else command_input

let expand_shortcut command_text =
  match String.index_opt command_text ':' with
  | None -> command_input command_text
  | Some separator_index ->
    let prefix = String.sub command_text 0 separator_index in
    (match shortcut_runner prefix with
     | None -> command_input command_text
     | Some runner ->
       let script_start = separator_index + 1 in
       let command_length = String.length command_text in
       if script_start = command_length then
         command_input command_text
       else
         let script_end =
           match find_first_whitespace_from command_text script_start with
           | None -> command_length
           | Some index -> index
         in
         assert (script_end > script_start);
         let script =
           String.sub command_text script_start (script_end - script_start)
         in
         let suffix =
           String.sub command_text script_end (command_length - script_end)
         in
         command_input
           ~command_name:script
           ~has_command_name:true
           (runner ^ " " ^ script ^ suffix))

let expand_shortcut command_input =
  match expand_shortcut command_input.command_text with
  | { has_command_name = false; command_text; _ } ->
    { command_input with command_text }
  | expanded ->
    let command_name =
      if command_input.has_command_name && not (String.equal command_input.command_name "")
      then command_input.command_name
      else expanded.command_name
    in
    { expanded with
      command_name
    ; has_command_name = true
    ; command_cwd = command_input.command_cwd
    ; command_env = command_input.command_env
    ; command_raw = command_input.command_raw
    }

let command_prefixes =
  [ "npm run"; "yarn run"; "pnpm run"; "bun run"; "node --run"; "deno task" ]

let command_script_and_args command_text command =
  let prefix = command ^ " " in
  let prefix_length = String.length prefix in
  if
    String.length command_text <= prefix_length
    || String.sub command_text 0 prefix_length <> prefix
  then None
  else
    let script_start = prefix_length in
    let script_end =
      match find_first_whitespace_from command_text script_start with
      | None -> String.length command_text
      | Some index -> index
    in
    let script_glob =
      String.sub command_text script_start (script_end - script_start)
    in
    let args =
      String.sub command_text script_end (String.length command_text - script_end)
    in
    Some (command, script_glob, args)

let wildcard_command command_text =
  List.find_map (command_script_and_args command_text) command_prefixes

let omission script_glob =
  match String.index_opt script_glob '(' with
  | None -> None
  | Some open_index ->
    if
      open_index + 1 >= String.length script_glob
      || script_glob.[open_index + 1] <> '!'
    then None
    else
      match String.index_from_opt script_glob (open_index + 2) ')' with
      | None -> None
      | Some close_index ->
        let omitted =
          String.sub script_glob (open_index + 2) (close_index - open_index - 2)
        in
        let without =
          String.sub script_glob 0 open_index
          ^ String.sub
              script_glob
              (close_index + 1)
              (String.length script_glob - close_index - 1)
        in
        Some (omitted, without)

let omitted_by_pattern omission script =
  match Str.search_forward (Str.regexp omission) script 0 with
  | _ -> true
  | exception _ -> false

let wildcard_match ~pattern ~wildcard_position script =
  let pattern_length = String.length pattern in
  let prefix =
    String.sub pattern 0 (min wildcard_position pattern_length)
  in
  let suffix_start = min (wildcard_position + 1) pattern_length in
  let suffix =
    String.sub pattern suffix_start (pattern_length - suffix_start)
  in
  let prefix_length = String.length prefix in
  let suffix_length = String.length suffix in
  let script_length = String.length script in
  if
    script_length < prefix_length + suffix_length
    || String.sub script 0 prefix_length <> prefix
    || String.sub script (script_length - suffix_length) suffix_length <> suffix
  then None
  else Some (String.sub script prefix_length (script_length - prefix_length - suffix_length))

let relevant_scripts ~cwd command =
  let package_scripts = Script_catalog.package_scripts ~cwd in
  if String.equal command "deno task" then
    Script_catalog.deno_tasks ~cwd @ package_scripts
  else package_scripts

let expand_wildcard ~cwd command_input =
  match wildcard_command command_input.command_text with
  | None -> [ command_input ]
  | Some (command, script_glob, args) ->
    (match String.index_opt script_glob '*' with
     | None -> [ command_input ]
     | Some wildcard_position ->
       let omission, pattern =
         match omission script_glob with
         | None -> None, script_glob
         | Some (omission, pattern) -> Some omission, pattern
       in
       let name_prefix =
         if String.equal command_input.command_name script_glob then ""
         else command_input.command_name
       in
       relevant_scripts ~cwd command
       |> List.filter_map (fun script ->
         match wildcard_match ~pattern ~wildcard_position script with
         | None -> None
         | Some match_text ->
           if
             match omission with
             | Some omission -> omitted_by_pattern omission match_text
             | None -> false
           then None
           else
             let command_name = name_prefix ^ match_text in
             Some
               { command_input with
                 command_text =
                   command ^ " " ^ Argument_expander.shell_quote script ^ args
               ; command_name
               ; has_command_name = true
               }))

let expand_arguments ~additional_arguments command_input =
  { command_input with
    command_text =
      Argument_expander.expand
        ~additional_arguments
        command_input.command_text
  }

let effective_names command_inputs =
  if List.exists (fun command_input -> command_input.has_command_name) command_inputs
  then Some (List.map (fun command_input -> command_input.command_name) command_inputs)
  else None

let command_cwd ~global_cwd command_input =
  match command_input.command_cwd with
  | Some _ as cwd -> cwd
  | None -> global_cwd

let command_raw ~global_raw command_input =
  match command_input.command_raw with
  | Some raw -> raw
  | None -> global_raw

let create_commands ?cwd ~raw ~hidden_indexes ~prefix_colors command_inputs =
  let rec create index = function
    | [] -> Ok []
    | command_input :: rest ->
      (match
         Command.create
           ?name:(option_of_name command_input.command_name)
           ?cwd:(command_cwd ~global_cwd:cwd command_input)
           ~env:command_input.command_env
           ?prefix_color:(prefix_color_at prefix_colors index)
           ~raw:(command_raw ~global_raw:raw command_input)
           ~hidden:(List.mem index hidden_indexes)
           ~index
           command_input.command_text
       with
       | Error error -> Error (`Command_error (index, error))
       | Ok command ->
         (match create (index + 1) rest with
          | Error error -> Error error
          | Ok commands -> Ok (command :: commands)))
  in
  create 0 command_inputs

let create_teardown_commands ?cwd ~main_command_count teardown_texts =
  let rec create offset = function
    | [] -> Ok []
    | command_text :: rest ->
      let index = main_command_count + offset in
      (match Command.create ?cwd ~raw:true ~index command_text with
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

let create
    ~api_command_names
    ~api_command_cwds
    ~api_command_envs
    ~api_command_raws
    ~cwd
    ~passthrough_arguments
    ~teardown_texts
    ~command_texts
    ~names_csv
    ~name_separator
    ~spacious
    ~timings
    ~group
    ~raw
    ~hide_csv
    ~no_color
    ~prefix
    ~prefix_colors_csv
    ~prefix_length
    ~pad_prefix
    ~timestamp_format
    ~handle_input
    ~default_input_target
    ~success
    ~kill_others
    ~kill_others_on_fail
    ~kill_signal
    ~kill_timeout_ms
    ~max_processes
    ~restart_tries
    ~restart_after =
  let cpu_count = Domain.recommended_domain_count () in
  assert (cpu_count >= 1);
  match split_names ~separator:name_separator names_csv with
  | Error error -> Error error
  | Ok names ->
    let original_command_count = List.length command_texts in
    let expansion_cwd =
      match cwd with
      | None -> Sys.getcwd ()
      | Some cwd -> cwd
    in
    match
      parse_api_command_overrides
        ~command_count:original_command_count
        ~api_command_names
        ~api_command_cwds
        ~api_command_envs
        ~api_command_raws
    with
    | Error error -> Error error
    | Ok api_overrides ->
      let command_inputs =
        command_texts
        |> List.mapi (fun index command_text ->
          let command_input =
            command_input
              ?command_cwd:api_overrides.cwds.(index)
              ~command_env:api_overrides.envs.(index)
              ?command_raw:api_overrides.raws.(index)
              command_text
          in
          match api_overrides.names.(index), name_at names index with
          | Some command_name, _ | None, Some command_name ->
            { command_input with command_name; has_command_name = true }
          | None, None -> command_input)
        |> List.map strip_quotes
        |> List.map expand_shortcut
        |> List.concat_map (fun command_input ->
          let cwd =
            match command_input.command_cwd with
            | Some cwd -> cwd
            | None -> expansion_cwd
          in
          expand_wildcard ~cwd command_input)
        |> fun command_inputs ->
        match passthrough_arguments with
        | None -> command_inputs
        | Some additional_arguments ->
          List.map (expand_arguments ~additional_arguments) command_inputs
      in
      let command_count = List.length command_inputs in
      let empty_expansion = command_count = 0 && command_texts <> [] in
      let no_op = empty_expansion && teardown_texts = [] in
      let effective_names = effective_names command_inputs in
      let hidden_indexes =
        hidden_indexes ~command_count ~names:effective_names hide_csv
      in
      let prefix_colors = split_csv prefix_colors_csv in
      let kill_others_on =
        kill_conditions ~kill_others ~kill_others_on_fail
      in
      let kill_signal = kill_signal_of_string kill_signal in
      match max_processes_of_string ~cpu_count max_processes with
      | Error error -> Error error
      | Ok max_processes ->
        (match
           success_condition_of_string
             ~command_count
             ~names:effective_names
             success
         with
         | Error error -> Error error
         | Ok success_condition ->
           (match restart_delay_of_string restart_after with
            | Error error -> Error error
            | Ok restart_delay ->
              if empty_expansion then
                match
                  create_teardown_commands
                    ?cwd
                    ~main_command_count:0
                    teardown_texts
                with
                | Error error -> Error error
                | Ok teardown ->
                  (match
                     Run_policy.create
                       ~kill_others_on
                       ~kill_signal
                       ?kill_timeout_ms
                       ~success_condition:Run_policy.NoCommands
                       ~restart_tries
                       ~restart_delay
                       ~teardown
                       ?max_processes
                       ()
                   with
                   | Error error -> Error (`Run_policy_error error)
                   | Ok policy ->
                     (match Run_spec.create_empty ~policy with
                      | Error error -> Error (`Run_spec_error error)
                      | Ok spec ->
                        Ok
                          { spec
                          ; display =
                              { labels = effective_names
                              ; prefix
                              ; prefix_length
                              ; pad_prefix
                              ; timestamp_format
                              ; spacious
                              ; timings
                              ; group
                              ; raw
                              ; no_color
                              }
                          ; input = None
                          ; no_op
                          }))
              else
                match
                  create_commands
                    ?cwd
                    ~raw
                    ~hidden_indexes
                    ~prefix_colors
                    command_inputs
                with
                | Error error -> Error error
                | Ok commands ->
                  (match
                     create_input_router
                       ~handle_input
                       ~commands
                       ~default_input_target
                   with
                   | Error error -> Error error
                   | Ok input ->
                     (match
                        create_teardown_commands
                          ?cwd
                          ~main_command_count:command_count
                          teardown_texts
                      with
                      | Error error -> Error error
                      | Ok teardown ->
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
                                    { labels = effective_names
                                    ; prefix
                                    ; prefix_length
                                    ; pad_prefix
                                    ; timestamp_format
                                    ; spacious
                                    ; timings
                                    ; group
                                    ; raw
                                    ; no_color
                                    }
                                ; input
                                ; no_op
                                }))))))

let spec t = t.spec
let commands t = Run_spec.commands t.spec
let policy t = Run_spec.policy t.spec
let display t = t.display
let input t = t.input
let is_no_op t = t.no_op

let command_error_message = function
  | `Empty_command -> "command text must not be empty"
  | `Empty_cwd -> "command cwd must not be empty"
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
  | `Duplicate_api_command_field (index, field) ->
    Printf.sprintf "duplicate API command %s for command %d" field index
  | `Empty_name_separator -> "name separator must not be empty"
  | `Invalid_api_command_name value ->
    Printf.sprintf "invalid API command name: %s" value
  | `Invalid_api_command_cwd value ->
    Printf.sprintf "invalid API command cwd: %s" value
  | `Invalid_api_command_env value ->
    Printf.sprintf "invalid API command env: %s" value
  | `Invalid_api_command_raw value ->
    Printf.sprintf "invalid API command raw: %s" value
  | `Input_router_error error -> Input_router.error_message error
  | `Invalid_max_processes value ->
    Printf.sprintf "invalid max processes: %s" value
  | `Invalid_restart_after value ->
    Printf.sprintf "invalid restart delay: %s" value
  | `Invalid_success_condition value ->
    Printf.sprintf "invalid success condition: %s" value
  | `Run_policy_error error -> run_policy_error_message error
  | `Run_spec_error error -> run_spec_error_message error
