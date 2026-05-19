type t = {
  argv : string array;
  passthrough_arguments : string list;
  deprecated_name_separator_used : bool;
}

type passthrough_extraction = {
  normalized_argv : string array;
  passthrough_arguments : string list;
}

let is_passthrough_flag argument =
  argument = "-P" || argument = "--passthrough-arguments"

let option_consumes_value = Cli_options.consumes_value
let boolean_options = Cli_options.boolean_options

let argument_has_prefix ~prefix argument =
  let prefix_length = String.length prefix in
  String.length argument >= prefix_length
  && String.sub argument 0 prefix_length = prefix

let option_has_inline_value argument =
  String.length argument > 2
  && argument.[0] = '-'
  && String.contains argument '='

let option_name_without_inline_value argument =
  match String.index_opt argument '=' with
  | None -> argument
  | Some index -> String.sub argument 0 index

let is_known_option = Cli_options.is_known

let is_dash_prefixed_argument argument =
  String.length argument > 1 && argument.[0] = '-'

let is_single_dash_numeric_argument argument =
  String.length argument > 1
  && argument.[0] = '-'
  &&
  match argument.[1] with
  | '0' .. '9' | '.' -> true
  | _ -> false

let option_accepts_dash_prefixed_value option_name argument =
  Cli_options.accepts_dash_prefixed_value ~option_name ~value:argument
  ||
  (Cli_options.accepts_single_dash_prefixed_value option_name
   && is_single_dash_numeric_argument argument
   && not (is_known_option (option_name_without_inline_value argument)))

module String_set = Set.Make (String)

let provided_option_names argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then String_set.empty
    else
      let option_name = option_name_without_inline_value argv.(index) in
      String_set.add option_name (loop (index + 1))
  in
  loop 1

let provided_option_name_matches provided_option_names option_names =
  List.exists
    (fun option_name -> String_set.mem option_name provided_option_names)
    option_names

let boolean_option_for_name option_name =
  List.find_opt
    (fun (option : Cli_options.boolean_option) ->
      List.mem option_name option.boolean_option_names)
    boolean_options

let boolean_option_for_negated_name option_name =
  List.find_opt
    (fun (option : Cli_options.boolean_option) ->
      List.mem option_name option.negated_option_names)
    boolean_options

let boolean_inline_value argument option_name =
  let value_start = String.length option_name + 1 in
  String.sub argument value_start (String.length argument - value_start)

let set_boolean_state states (option : Cli_options.boolean_option) enabled =
  (option.emitted_boolean_option, enabled)
  :: List.remove_assoc option.emitted_boolean_option states

let enabled_boolean_arguments states =
  boolean_options
  |> List.filter_map (fun (option : Cli_options.boolean_option) ->
      match List.assoc_opt option.emitted_boolean_option states with
      | Some true -> Some option.emitted_boolean_option
      | Some false | None -> None)

let normalize_boolean_options_argv argv =
  let assemble states arguments tail =
    Array.of_list
      (List.concat
         [
           [ argv.(0) ];
           enabled_boolean_arguments states;
           List.rev arguments;
           tail;
         ])
  in
  let rec loop index states arguments =
    if index >= Array.length argv then assemble states arguments []
    else if argv.(index) = "--" then
      let tail_count = Array.length argv - index in
      let tail = List.init tail_count (fun offset -> argv.(index + offset)) in
      assemble states arguments tail
    else
      let argument = argv.(index) in
      let option_name = option_name_without_inline_value argument in
      match boolean_option_for_name option_name with
      | Some option ->
          let enabled =
            if option_has_inline_value argument then
              String.equal (boolean_inline_value argument option_name) "true"
            else true
          in
          loop (index + 1) (set_boolean_state states option enabled) arguments
      | None -> (
          match boolean_option_for_negated_name option_name with
          | Some option ->
              if option_has_inline_value argument then
                loop (index + 1) states arguments
              else
                loop (index + 1) (set_boolean_state states option false)
                  arguments
          | None -> loop (index + 1) states (argument :: arguments))
  in
  match Array.length argv with 0 -> argv | _ -> loop 1 [] []

let drop_unknown_options_argv argv =
  let rec loop index normalized =
    if index >= Array.length argv then Array.of_list (List.rev normalized)
    else if argv.(index) = "--" then
      let tail_count = Array.length argv - index in
      let tail = List.init tail_count (fun offset -> argv.(index + offset)) in
      Array.of_list (List.rev_append normalized tail)
    else
      let argument = argv.(index) in
      let option_name = option_name_without_inline_value argument in
      if
        index > 0
        && option_consumes_value option_name
        && (not (option_has_inline_value argument))
        && (index + 1 >= Array.length argv
           || is_dash_prefixed_argument argv.(index + 1)
              && not
                   (option_accepts_dash_prefixed_value option_name
                      argv.(index + 1)))
      then loop (index + 1) normalized
      else if
        index > 0
        && is_dash_prefixed_argument argument
        && not (is_known_option option_name)
      then
        let next_index =
          if
            option_has_inline_value argument
            || index + 1 >= Array.length argv
            || String.length argv.(index + 1) = 0
            || argv.(index + 1).[0] = '-'
          then index + 1
          else index + 2
        in
        loop next_index normalized
      else loop (index + 1) (argument :: normalized)
  in
  loop 0 []

let normalize_builtin_aliases_argv argv =
  let argv = Array.copy argv in
  let after_command_separator = ref false in
  Array.iteri
    (fun index argument ->
      if index > 0 && not !after_command_separator then
        if argument = "--" then after_command_separator := true
          (* yargs handles these built-in aliases before this package binds
             separate option values, so `--prefix -v` prints the version while
             `--prefix=-v` remains the way to pass a dash-prefixed value. *)
        else if argument = "-h" then argv.(index) <- "--help"
        else if argument = "-v" || argument = "-V" then
          argv.(index) <- "--version")
    argv;
  argv

let normalize_short_inline_value_options_argv argv =
  let normalize_argument argument =
    if
      String.length argument >= 4
      && argument.[0] = '-'
      && argument.[1] <> '-'
      && argument.[2] = '='
    then
      let option_name = String.sub argument 0 2 in
      match Cli_options.emitted_value_option option_name with
      | None -> argument
      | Some emitted_option ->
          emitted_option
          ^ String.sub argument 2 (String.length argument - 2)
    else argument
  in
  let rec loop index normalized =
    if index >= Array.length argv then Array.of_list (List.rev normalized)
    else if argv.(index) = "--" then
      let tail_count = Array.length argv - index in
      let tail = List.init tail_count (fun offset -> argv.(index + offset)) in
      Array.of_list (List.rev_append normalized tail)
    else loop (index + 1) (normalize_argument argv.(index) :: normalized)
  in
  loop 0 []

let requests_help_before_separator argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then false
    else
      let argument = argv.(index) in
      if
        argument = "-h" || argument = "--help"
        || String.equal argument "--help=true"
      then true
      else if option_consumes_value argument then loop (index + 2)
      else loop (index + 1)
  in
  loop 1

let requests_builtin_exit_before_separator argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then false
    else
      let argument = argv.(index) in
      if argument = "--help" || argument = "--version" then true
      else if option_consumes_value argument then loop (index + 2)
      else loop (index + 1)
  in
  loop 1

let has_command_argument argv =
  let rec loop index =
    if index >= Array.length argv then false
    else if argv.(index) = "--" then index + 1 < Array.length argv
    else
      let argument = argv.(index) in
      let option_name = option_name_without_inline_value argument in
      if
        option_consumes_value option_name
        && not (option_has_inline_value argument)
      then loop (index + 2)
      else if
        option_has_inline_value argument
        || (String.length argument > 0 && argument.[0] = '-')
      then loop (index + 1)
      else true
  in
  loop 1

let requests_default_help argv =
  (not (requests_builtin_exit_before_separator argv))
  && not (has_command_argument argv)

let argv_contains_passthrough_flag_before_separator argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then false
    else
      let argument = argv.(index) in
      if option_consumes_value argument then
        is_passthrough_flag argument || loop (index + 2)
      else if option_has_inline_value argument then loop (index + 1)
      else is_passthrough_flag argument || loop (index + 1)
  in
  loop 1

let has_command_argument_before_separator argv separator_index =
  let rec loop index =
    if index >= separator_index then false
    else
      let argument = argv.(index) in
      if option_consumes_value argument then loop (index + 2)
      else if
        is_passthrough_flag argument
        || option_has_inline_value argument
        || (String.length argument > 0 && argument.[0] = '-')
      then loop (index + 1)
      else true
  in
  loop 1

let extract_passthrough_arguments argv =
  if not (argv_contains_passthrough_flag_before_separator argv) then
    { normalized_argv = argv; passthrough_arguments = [] }
  else
    let rec find_separator index =
      if index = Array.length argv then None
      else if argv.(index) = "--" then Some index
      else find_separator (index + 1)
    in
    let separator_index =
      match find_separator 1 with
      | Some first_separator
        when not (has_command_argument_before_separator argv first_separator) ->
          find_separator (first_separator + 1)
      | first_separator -> first_separator
    in
    match separator_index with
    | None -> { normalized_argv = argv; passthrough_arguments = [] }
    | Some separator_index ->
        let additional_count = Array.length argv - separator_index - 1 in
        let passthrough_arguments =
          List.init additional_count (fun offset ->
              argv.(separator_index + offset + 1))
        in
        {
          normalized_argv = Array.sub argv 0 separator_index;
          passthrough_arguments;
        }

let is_name_separator_argument argument =
  argument = "--name-separator"
  || argument_has_prefix ~prefix:"--name-separator=" argument

let uses_deprecated_name_separator argv =
  let rec loop index =
    if index >= Array.length argv || argv.(index) = "--" then false
    else is_name_separator_argument argv.(index) || loop (index + 1)
  in
  loop 1

let normalize_negative_option_name option_name =
  match Cli_options.emitted_value_option option_name with
  | Some emitted_option -> emitted_option
  | None -> option_name

let normalize_negative_option_values_argv argv =
  let rec loop index normalized =
    if index >= Array.length argv then Array.of_list (List.rev normalized)
    else if argv.(index) = "--" then
      let tail_count = Array.length argv - index in
      let tail = List.init tail_count (fun offset -> argv.(index + offset)) in
      Array.of_list (List.rev_append normalized tail)
    else if
      option_consumes_value argv.(index)
      && index + 1 < Array.length argv
      && option_accepts_dash_prefixed_value argv.(index) argv.(index + 1)
    then
      let option_name = normalize_negative_option_name argv.(index) in
      loop (index + 2) ((option_name ^ "=" ^ argv.(index + 1)) :: normalized)
    else loop (index + 1) (argv.(index) :: normalized)
  in
  loop 0 []

let normalize_with_env ~env argv =
  let expanded_argv = Cli_short_options.expand_clusters argv in
  let provided_option_names = provided_option_names expanded_argv in
  let with_env_argv =
    Cli_env_options.add_arguments ~env
      ~option_was_provided:(fun option_names ->
        provided_option_name_matches provided_option_names option_names)
      expanded_argv
  in
  let argv =
    with_env_argv |> normalize_builtin_aliases_argv
    |> normalize_short_inline_value_options_argv
    |> normalize_negative_option_values_argv |> drop_unknown_options_argv
    |> normalize_boolean_options_argv
  in
  let deprecated_name_separator_used = uses_deprecated_name_separator argv in
  let passthrough = extract_passthrough_arguments argv in
  {
    argv = passthrough.normalized_argv;
    passthrough_arguments = passthrough.passthrough_arguments;
    deprecated_name_separator_used;
  }

let normalize argv = normalize_with_env ~env:Sys.getenv_opt argv
