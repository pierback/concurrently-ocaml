type display = {
  labels : string list option;
  prefix : string option;
  prefix_length : float;
  pad_prefix : bool;
  timestamp_format : string;
  spacious : bool;
  timings : bool;
  group : bool;
  raw : bool;
  no_color : bool;
}

type t = {
  spec : Run_spec.t;
  display : display;
  input : Input_router.t option;
  no_op : bool;
}

type prefix_palette = { colors : string array; last_color : string option }

type expanded_commands = {
  command_inputs : Cli_command_inputs.t list;
  command_count : int;
  empty_expansion : bool;
  no_op : bool;
  effective_names : string list option;
  hidden_by_index : bool array;
  prefix_palette : prefix_palette;
}

type policy_input = {
  kill_others_on : Run_policy.kill_condition list;
  kill_signal : Run_policy.kill_signal;
  kill_timeout_ms : int option;
  kill_timeout_warning : Run_policy.timer_warning option;
  success_condition : Run_policy.success_condition;
  drop_failed_close_events_for_success : bool;
  restart_tries : int;
  restart_delay : Run_policy.restart_delay;
  restart_delay_warning : Run_policy.timer_warning option;
  max_processes : int option;
}

type create_error =
  [ `Command_error of int * Command.create_error
  | `Command_input_error of Cli_command_inputs.expand_error
  | `Display_command_count_mismatch of int * int
  | `Input_router_error of Input_router.create_error
  | `Run_policy_error of Run_policy.create_error
  | `Run_spec_error of Run_spec.create_error ]

let utf8_character_length value index =
  let byte = Char.code value.[index] in
  let remaining = String.length value - index in
  if byte land 0b1000_0000 = 0 then 1
  else if byte land 0b1110_0000 = 0b1100_0000 && remaining >= 2 then 2
  else if byte land 0b1111_0000 = 0b1110_0000 && remaining >= 3 then 3
  else if byte land 0b1111_1000 = 0b1111_0000 && remaining >= 4 then 4
  else 1

let split_into_characters value =
  let rec loop index characters =
    if index >= String.length value then List.rev characters
    else
      let character_length = utf8_character_length value index in
      let character = String.sub value index character_length in
      loop (index + character_length) (character :: characters)
  in
  loop 0 []

let split_on_separator ~separator value =
  let separator_length = String.length separator in
  if separator_length = 0 then split_into_characters value
  else
    let value_length = String.length value in
    let rec find_separator index =
      if index + separator_length > value_length then None
      else if String.sub value index separator_length = separator then
        Some index
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
  | Some names_csv -> Ok (Some (split_on_separator ~separator names_csv))

let indexes_for_name names token =
  names
  |> List.mapi (fun index name -> (index, name))
  |> List.filter_map (fun (index, name) ->
      if String.equal name token then Some index else None)

let indexes_for_token ~command_count ~names token =
  let by_index =
    match int_of_string_opt token with
    | Some index when index >= 0 && index < command_count -> [ index ]
    | Some _ | None -> []
  in
  let by_name =
    match names with None -> [] | Some values -> indexes_for_name values token
  in
  List.rev_append by_name by_index

let indexes_for_csv ~command_count csv =
  csv |> String.split_on_char ',' |> List.map String.trim
  |> List.filter_map (fun token ->
         match int_of_string_opt token with
         | Some index when index >= 0 && index < command_count -> Some index
         | Some _ | None -> None)

let hidden_indexes ~command_count ~names ~api_hide_indexes_csv hide_csv =
  let hidden_from_identifiers =
    match hide_csv with
    | None -> []
    | Some csv ->
        csv |> String.split_on_char ',' |> List.map String.trim
        |> List.filter (fun token -> not (String.equal token ""))
        |> List.concat_map (indexes_for_token ~command_count ~names)
  in
  let hidden_from_indexes =
    match api_hide_indexes_csv with
    | None -> []
    | Some csv -> indexes_for_csv ~command_count csv
  in
  List.sort_uniq Int.compare (hidden_from_indexes @ hidden_from_identifiers)

let split_csv = function
  | None -> []
  | Some csv ->
      csv |> String.split_on_char ',' |> List.map String.trim
      |> List.filter (fun token -> not (String.equal token ""))

let last = function
  | [] -> None
  | first :: rest -> Some (List.fold_left (fun _ item -> item) first rest)

let prefix_palette prefix_colors_csv =
  let colors = split_csv prefix_colors_csv in
  { colors = Array.of_list colors; last_color = last colors }

let prefix_color_at palette index =
  if index < Array.length palette.colors then Some palette.colors.(index)
  else palette.last_color

let kill_signal_of_string signal =
  match String.trim signal with
  | "" -> Run_policy.Sigterm
  | "SIGTERM" -> Run_policy.Sigterm
  | "SIGKILL" -> Run_policy.Sigkill
  | named_signal -> Run_policy.Named_signal named_signal

let kill_conditions ~kill_others ~kill_others_on_success ~kill_others_on_fail =
  if kill_others then [ Run_policy.Success; Run_policy.Failure ]
  else
    List.concat
      [
        (if kill_others_on_success then [ Run_policy.Success ] else []);
        (if kill_others_on_fail then [ Run_policy.Failure ] else []);
      ]

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
  let excluded_indexes =
    success_selector_indexes ~command_count ~names selector
  in
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
  | "all" -> Run_policy.All
  | "first" -> Run_policy.First
  | "last" -> Run_policy.Last
  | _ ->
      (* npm treats unmatched success values as "all". Empty command selectors
         are unmatched by its regular expression, so they follow that fallback. *)
      if starts_with ~prefix:"!command-" value then
        let selector = String.sub value 9 (String.length value - 9) in
        if selector = "" then Run_policy.All
        else success_condition_except ~command_count ~names selector
      else if starts_with ~prefix:"command-" value then
        let selector = String.sub value 8 (String.length value - 8) in
        if selector = "" then Run_policy.All
        else
          Run_policy.Commands
            (success_selector_indexes ~command_count ~names selector)
      else Run_policy.All

let restart_delay_of_string restart_after =
  let value = String.trim restart_after in
  match String.lowercase_ascii value with
	  | "exponential" -> (Run_policy.Exponential_backoff, None)
	  | _ ->
	      let number =
	        if String.equal value "" then Some 0.0 else float_of_string_opt value
	      in
	      match number with
	      | Some number
	        when (match classify_float number with
              | FP_nan | FP_infinite -> false
              | FP_normal | FP_subnormal | FP_zero -> true)
             && number >= float_of_int min_int
             && number <= float_of_int max_int ->
          (Run_policy.Fixed_delay_ms (int_of_float number), None)
      | Some _ | None ->
          (Run_policy.Fixed_delay_ms 0, Some Run_policy.Timeout_nan)

let ends_with ~suffix value =
  let suffix_length = String.length suffix in
  let value_length = String.length value in
  value_length >= suffix_length
  && String.sub value (value_length - suffix_length) suffix_length = suffix

let finite_float value =
  match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true

let float_fits_int value =
  finite_float value
  && value >= float_of_int min_int
  && value <= float_of_int max_int

let round_to_int value =
  assert (float_fits_int value);
  int_of_float (floor (value +. 0.5))

let ceil_to_int value =
  assert (float_fits_int value);
  int_of_float (ceil value)

let js_number_of_string value =
  let value = String.trim value in
  if String.equal value "" then Some 0.0 else float_of_string_opt value

let kill_timeout_of_string = function
  | None -> (None, None)
  | Some value -> (
      let trimmed_value = String.trim value in
      match js_number_of_string trimmed_value with
      | Some number when float_fits_int number ->
          let timeout_ms = int_of_float number in
          let timeout_ms =
            if number <> 0.0 && timeout_ms = 0 then 1 else timeout_ms
          in
          let warning =
            if number < 0.0 then
              Some (Run_policy.Timeout_negative trimmed_value)
            else None
          in
          (Some timeout_ms, warning)
      | Some _ | None -> (Some 0, None))

let restart_tries_of_string value =
  match js_number_of_string value with
  | Some number when number < 0.0 ->
      (-1, false)
  | Some number when classify_float number = FP_infinite -> (-1, false)
  | Some number when float_fits_int number ->
      let restart_tries = int_of_float (floor number) in
      let integral = Float.equal number (floor number) in
      (restart_tries, not integral)
  | Some number when finite_float number -> (-1, false)
  | Some _ | None -> (0, true)

let all_command_processes command_count = Some (max 1 command_count)

let max_process_count_from_number ~command_count ~to_int value =
  if value = 0.0 then all_command_processes command_count
  else if not (float_fits_int value) then all_command_processes command_count
  else Some (max 1 (to_int value))

let max_process_count_from_percent ~cpu_count ~command_count percent =
  if not (finite_float percent) then all_command_processes command_count
  else
    let value = float_of_int cpu_count *. percent /. 100.0 in
    max_process_count_from_number ~command_count ~to_int:round_to_int value

let max_process_count_from_text ~command_count value =
  if String.equal value "" then all_command_processes command_count
  else
    match float_of_string_opt value with
    | Some number ->
        max_process_count_from_number ~command_count ~to_int:ceil_to_int number
    | None -> all_command_processes command_count

let max_processes_of_string ~cpu_count ~command_count = function
  | None -> None
  | Some max_processes ->
      assert (cpu_count >= 1);
      assert (command_count >= 0);
      let value = String.trim max_processes in
      if ends_with ~suffix:"%" value then
        let percent_text = String.sub value 0 (String.length value - 1) in
        let percent_text = String.trim percent_text in
        match float_of_string_opt percent_text with
        | Some percent ->
            max_process_count_from_percent ~cpu_count ~command_count percent
        | None -> all_command_processes command_count
      else max_process_count_from_text ~command_count value

let option_of_name name = if String.equal name "" then None else Some name

let expand_command_inputs ~cwd ~passthrough_arguments ~command_texts ~names
    ~hide_csv ~api_hide_indexes_csv ~prefix_colors_csv ~teardown_texts =
  match
    Cli_command_inputs.expand ~cwd ~passthrough_arguments ~command_texts ~names
  with
  | Error error -> Error (`Command_input_error error)
  | Ok command_inputs ->
  let command_count = List.length command_inputs in
  let empty_expansion = command_count = 0 && command_texts <> [] in
  let no_op = empty_expansion && teardown_texts = [] in
  let effective_names = Cli_command_inputs.effective_names command_inputs in
  let hidden_indexes =
    hidden_indexes ~command_count ~names:effective_names ~api_hide_indexes_csv
      hide_csv
  in
  let hidden_by_index = Array.make command_count false in
  List.iter
    (fun index ->
      assert (index >= 0);
      assert (index < command_count);
      hidden_by_index.(index) <- true)
    hidden_indexes;
  let prefix_palette = prefix_palette prefix_colors_csv in
  Ok {
    command_inputs;
    command_count;
    empty_expansion;
    no_op;
    effective_names;
    hidden_by_index;
    prefix_palette;
  }

let create_display ~labels ~prefix ~prefix_length ~pad_prefix ~timestamp_format
    ~spacious ~timings ~group ~raw ~no_color =
  {
    labels;
    prefix;
    prefix_length;
    pad_prefix;
    timestamp_format;
    spacious;
    timings;
    group;
    raw;
    no_color;
  }

let display_command_texts_for_count ~command_count display_command_texts =
  match display_command_texts with
  | [] -> Ok None
  | values ->
      let value_count = List.length values in
      if value_count = command_count then Ok (Some (Array.of_list values))
      else Error (`Display_command_count_mismatch (value_count, command_count))

let display_command_text_at display_command_texts index =
  match display_command_texts with
  | None -> None
  | Some values ->
      assert (index >= 0);
      assert (index < Array.length values);
      Some values.(index)

let create_commands ?cwd ~raw ~hidden_by_index ~prefix_palette
    ?display_command_texts command_inputs =
  let rec create index commands = function
    | [] -> Ok (List.rev commands)
    | command_input :: rest -> (
        assert (index < Array.length hidden_by_index);
        let command_name = Cli_command_inputs.command_name command_input in
        let command_text = Cli_command_inputs.command_text command_input in
        match
          Command.create
            ?name:(option_of_name command_name)
            ?cwd ~env:[]
            ?prefix_color:(prefix_color_at prefix_palette index)
            ?display_text:(display_command_text_at display_command_texts index)
            ~raw ~hidden:hidden_by_index.(index) ~index command_text
        with
        | Error error -> Error (`Command_error (index, error))
        | Ok command -> create (index + 1) (command :: commands) rest)
  in
  create 0 [] command_inputs

let create_teardown_commands ?cwd ~main_command_count teardown_texts =
  let rec create offset commands = function
    | [] -> Ok (List.rev commands)
    | command_text :: rest -> (
        let index = main_command_count + offset in
        match
          Command.create ?cwd ~raw:true ~allow_empty:true ~index command_text
        with
        | Error error -> Error (`Command_error (index, error))
        | Ok command -> create (offset + 1) (command :: commands) rest)
  in
  create 0 [] teardown_texts

let create_input_router ~handle_input ~commands ~default_input_target =
  if not handle_input then Ok None
  else
    match Input_router.create ~commands ~default_input_target with
    | Ok router -> Ok (Some router)
    | Error error -> Error (`Input_router_error error)

let create_policy input ~teardown =
  match
    Run_policy.create ~kill_others_on:input.kill_others_on
      ~kill_signal:input.kill_signal ?kill_timeout_ms:input.kill_timeout_ms
      ~success_condition:input.success_condition
      ~drop_failed_close_events_for_success:
        input.drop_failed_close_events_for_success
      ~restart_tries:input.restart_tries ~restart_delay:input.restart_delay
      ?restart_delay_warning:input.restart_delay_warning
      ?kill_timeout_warning:input.kill_timeout_warning
      ~teardown ?max_processes:input.max_processes ()
  with
  | Ok policy -> Ok policy
  | Error error -> Error (`Run_policy_error error)

let create_empty_spec ~policy =
  match Run_spec.create_empty ~policy with
  | Ok spec -> Ok spec
  | Error error -> Error (`Run_spec_error error)

let create_run_spec ~commands ~policy =
  match Run_spec.create ~commands ~policy with
  | Ok spec -> Ok spec
  | Error error -> Error (`Run_spec_error error)

let create_result ~spec ~display ~input ~no_op =
  Ok { spec; display; input; no_op }

let create_empty_expansion_config ~cwd ~teardown_texts ~policy_input ~display
    ~no_op =
  match create_teardown_commands ?cwd ~main_command_count:0 teardown_texts with
  | Error error -> Error error
  | Ok teardown -> (
      match create_policy policy_input ~teardown with
      | Error error -> Error error
      | Ok policy -> (
          match create_empty_spec ~policy with
          | Error error -> Error error
          | Ok spec -> create_result ~spec ~display ~input:None ~no_op))

let create_command_config ~cwd ~teardown_texts ~policy_input ~display
    ~handle_input ~default_input_target ~display_command_texts expanded =
  match
    display_command_texts_for_count ~command_count:expanded.command_count
      display_command_texts
  with
  | Error error -> Error error
  | Ok display_command_texts -> (
      match
        create_commands ?cwd ~raw:display.raw
          ~hidden_by_index:expanded.hidden_by_index
          ~prefix_palette:expanded.prefix_palette ?display_command_texts
          expanded.command_inputs
      with
      | Error error -> Error error
      | Ok commands -> (
          match
            create_input_router ~handle_input ~commands ~default_input_target
          with
          | Error error -> Error error
          | Ok input -> (
              match
                create_teardown_commands ?cwd
                  ~main_command_count:expanded.command_count teardown_texts
              with
              | Error error -> Error error
              | Ok teardown -> (
                  match create_policy policy_input ~teardown with
                  | Error error -> Error error
                  | Ok policy -> (
                      match create_run_spec ~commands ~policy with
                      | Error error -> Error error
                      | Ok spec ->
                          create_result ~spec ~display ~input
                            ~no_op:expanded.no_op)))))

let create_with_display ~cwd ~passthrough_arguments ~teardown_texts
    ~command_texts ~display_command_texts ~names_csv
    ~force_empty_expansion ~name_separator ~spacious ~timings ~group ~raw
    ~hide_csv ~api_hide_indexes_csv ~no_color ~prefix
    ~prefix_colors_csv ~prefix_length ~pad_prefix ~timestamp_format ~handle_input
    ~default_input_target ~success ~kill_others_on_success ~kill_others
    ~kill_others_on_fail ~kill_signal ~kill_timeout_ms ~max_processes
    ~restart_tries ~restart_after =
  let cpu_count = Domain.recommended_domain_count () in
  assert (cpu_count >= 1);
  match split_names ~separator:name_separator names_csv with
  | Error error -> Error error
  | Ok names -> (
      let create_from_expansion expanded =
        let display =
          create_display ~labels:expanded.effective_names ~prefix
            ~prefix_length ~pad_prefix ~timestamp_format ~spacious ~timings
            ~group ~raw ~no_color
        in
        let kill_others_on =
          kill_conditions ~kill_others ~kill_others_on_success
            ~kill_others_on_fail
        in
        let kill_signal = kill_signal_of_string kill_signal in
        let max_processes =
          max_processes_of_string ~cpu_count
            ~command_count:expanded.command_count max_processes
        in
        let success_condition =
          success_condition_of_string ~command_count:expanded.command_count
            ~names:expanded.effective_names success
        in
        let kill_timeout_ms, kill_timeout_warning =
          kill_timeout_of_string kill_timeout_ms
        in
        let restart_tries, drop_failed_close_events_for_success =
          restart_tries_of_string restart_tries
        in
        let restart_delay, restart_delay_warning =
          restart_delay_of_string restart_after
        in
        let policy_input =
          {
            kill_others_on;
            kill_signal;
            kill_timeout_ms;
            kill_timeout_warning;
            success_condition;
            drop_failed_close_events_for_success;
            restart_tries;
            restart_delay;
            restart_delay_warning;
            max_processes;
          }
        in
        if expanded.empty_expansion then
          let policy_input =
            { policy_input with success_condition = Run_policy.NoCommands }
          in
          create_empty_expansion_config ~cwd ~teardown_texts ~policy_input
            ~display ~no_op:expanded.no_op
        else
          create_command_config ~cwd ~teardown_texts ~policy_input ~display
            ~handle_input ~default_input_target ~display_command_texts expanded
      in
      if force_empty_expansion then
        let expanded =
          {
            command_inputs = [];
            command_count = 0;
            empty_expansion = true;
            no_op = teardown_texts = [];
            effective_names = None;
            hidden_by_index = [||];
            prefix_palette = prefix_palette prefix_colors_csv;
          }
        in
        create_from_expansion expanded
      else
      (match
        expand_command_inputs ~cwd ~passthrough_arguments ~command_texts ~names
          ~hide_csv ~api_hide_indexes_csv ~prefix_colors_csv ~teardown_texts
       with
       | Error error -> Error error
       | Ok expanded -> create_from_expansion expanded))

let create ~cwd ~passthrough_arguments ~teardown_texts ~command_texts ~names_csv
    ~name_separator ~spacious ~timings ~group ~raw ~hide_csv
    ~api_hide_indexes_csv ~no_color ~prefix ~prefix_colors_csv ~prefix_length
    ~pad_prefix ~timestamp_format ~handle_input ~default_input_target ~success
    ~kill_others_on_success ~kill_others ~kill_others_on_fail ~kill_signal
    ~kill_timeout_ms ~max_processes ~restart_tries ~restart_after =
  create_with_display ~cwd ~passthrough_arguments ~teardown_texts
    ~command_texts ~display_command_texts:[] ~names_csv
    ~force_empty_expansion:false ~name_separator
    ~spacious ~timings ~group ~raw ~hide_csv ~api_hide_indexes_csv ~no_color ~prefix
    ~prefix_colors_csv ~prefix_length ~pad_prefix ~timestamp_format
    ~handle_input ~default_input_target ~success ~kill_others_on_success
    ~kill_others ~kill_others_on_fail ~kill_signal ~kill_timeout_ms
    ~max_processes ~restart_tries ~restart_after

let spec t = t.spec
let commands t = Run_spec.commands t.spec
let policy t = Run_spec.policy t.spec
let display t = t.display
let input t = t.input
let is_no_op (t : t) = t.no_op

let command_error_message = function
  | `Empty_command -> "command text must not be empty"
  | `Empty_cwd -> "command cwd must not be empty"
  | `Negative_index -> "command index must not be negative"

let command_input_error_message = function
  | `Invalid_wildcard_omission omission ->
      Printf.sprintf "invalid wildcard omission regular expression: %s" omission

let run_policy_error_message = function
  | `Duplicate_kill_condition -> "kill conditions must not contain duplicates"
  | `Empty_signal -> "kill signal must not be empty"
  | `Exponential_restart_delay_overflow ->
      "exponential restart delay overflows integer bounds"
  | `Max_processes_less_than_one -> "max processes must be at least 1"
  | `Negative_success_command_index ->
      "success condition command index must not be negative"

let run_spec_error_message = function
  | `Close_event_capacity_overflow -> "close event capacity overflow"
  | `Command_index_mismatch (expected, actual) ->
      Printf.sprintf "command index mismatch: expected %d but got %d" expected
        actual
  | `Empty_command_list -> "at least one command is required"

let error_message = function
  | `Command_error (index, error) ->
      Printf.sprintf "command %d is invalid: %s" index
        (command_error_message error)
  | `Command_input_error error -> command_input_error_message error
  | `Display_command_count_mismatch (actual, expected) ->
      Printf.sprintf "display command count mismatch: expected %d but got %d"
        expected actual
  | `Input_router_error error -> Input_router.error_message error
  | `Run_policy_error error -> run_policy_error_message error
  | `Run_spec_error error -> run_spec_error_message error
