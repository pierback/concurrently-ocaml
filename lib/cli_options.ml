type boolean_option = {
  boolean_option_names : string list;
  negated_option_names : string list;
  emitted_boolean_option : string;
}

type env_option_kind = Env_flag | Env_value

type env_option = {
  option_names : string list;
  env_names : string list;
  kind : env_option_kind;
  emitted_option : string;
}

type env_binding = {
  env_names : string list;
  env_order : int;
  emitted_option : string;
}

type value_option = {
  emitted_value_option : string;
  accepts_negative_number_value : bool;
  accepts_negative_percent_value : bool;
}

type option_kind =
  | Boolean of {
      negated_names : string list;
      emitted_boolean_option : string;
      boolean_order : int;
    }
  | Value of value_option

type spec = {
  names : string list;
  kind : option_kind;
  env_binding : env_binding option;
}

let env_binding ?env_order ~env_names emitted_option =
  match (env_names, env_order) with
  | [], None -> None
  | [], Some _ ->
      invalid_arg "Cli_options.env_binding: env_order requires env_names"
  | _ :: _, None ->
      invalid_arg "Cli_options.env_binding: env_names require env_order"
  | _ :: _, Some env_order -> Some { env_names; env_order; emitted_option }

let boolean ?(env_names = []) ?env_order names ~negated_names
    ~emitted_boolean_option ~boolean_order =
  {
    names;
    kind = Boolean { negated_names; emitted_boolean_option; boolean_order };
    env_binding = env_binding ?env_order ~env_names emitted_boolean_option;
  }

let value ?(env_names = []) ?env_order ?(accepts_negative_number_value = false)
    ?(accepts_negative_percent_value = false) names ~emitted_option =
  assert ((not accepts_negative_percent_value) || accepts_negative_number_value);
  {
    names;
    kind =
      Value
        {
          emitted_value_option = emitted_option;
          accepts_negative_number_value;
          accepts_negative_percent_value;
        };
    env_binding = env_binding ?env_order ~env_names emitted_option;
  }

let specs =
  [
    value
      [ "-m"; "--max-processes" ]
      ~env_names:[ "CONCURRENTLY_MAX_PROCESSES"; "CONCURRENTLY_M" ]
      ~env_order:1 ~accepts_negative_number_value:true
      ~accepts_negative_percent_value:true ~emitted_option:"--max-processes";
    boolean [ "-h"; "--help" ] ~negated_names:[ "--no-help" ]
      ~emitted_boolean_option:"--help" ~boolean_order:1;
    boolean
      [ "-v"; "-V"; "--version" ]
      ~negated_names:[ "--no-version" ] ~emitted_boolean_option:"--version"
      ~boolean_order:2;
    value [ "-n"; "--names" ]
      ~env_names:[ "CONCURRENTLY_NAMES"; "CONCURRENTLY_N" ]
      ~env_order:2 ~emitted_option:"--names";
    value [ "--name-separator" ]
      ~env_names:[ "CONCURRENTLY_NAME_SEPARATOR" ]
      ~env_order:3 ~emitted_option:"--name-separator";
    value [ "-s"; "--success" ]
      ~env_names:[ "CONCURRENTLY_SUCCESS"; "CONCURRENTLY_S" ]
      ~env_order:4 ~emitted_option:"--success";
    boolean [ "-g"; "--group" ]
      ~env_names:[ "CONCURRENTLY_GROUP"; "CONCURRENTLY_G" ]
      ~env_order:8 ~negated_names:[ "--no-group" ]
      ~emitted_boolean_option:"--group" ~boolean_order:3;
    boolean [ "-r"; "--raw" ]
      ~env_names:[ "CONCURRENTLY_RAW"; "CONCURRENTLY_R" ]
      ~env_order:5 ~negated_names:[ "--no-raw" ] ~emitted_boolean_option:"--raw"
      ~boolean_order:4;
    boolean [ "--no-color" ]
      ~env_names:[ "CONCURRENTLY_NO_COLOR" ]
      ~env_order:6 ~negated_names:[ "--no-no-color" ]
      ~emitted_boolean_option:"--no-color" ~boolean_order:5;
    value [ "--hide" ] ~env_names:[ "CONCURRENTLY_HIDE" ] ~env_order:7
      ~emitted_option:"--hide";
    boolean
      [ "-P"; "--passthrough-arguments" ]
      ~env_names:[ "CONCURRENTLY_PASSTHROUGH_ARGUMENTS" ]
      ~env_order:10
      ~negated_names:[ "--no-passthrough-arguments" ]
      ~emitted_boolean_option:"--passthrough-arguments" ~boolean_order:6;
    value [ "--teardown" ]
      ~env_names:[ "CONCURRENTLY_TEARDOWN" ]
      ~env_order:11 ~emitted_option:"--teardown";
    value [ "-p"; "--prefix" ]
      ~env_names:[ "CONCURRENTLY_PREFIX"; "CONCURRENTLY_P" ]
      ~env_order:12 ~emitted_option:"--prefix";
    value
      [ "-c"; "--prefix-colors" ]
      ~env_names:[ "CONCURRENTLY_PREFIX_COLORS"; "CONCURRENTLY_C" ]
      ~env_order:13 ~emitted_option:"--prefix-colors";
    value
      [ "-l"; "--prefix-length" ]
      ~env_names:[ "CONCURRENTLY_PREFIX_LENGTH"; "CONCURRENTLY_L" ]
      ~env_order:14 ~accepts_negative_number_value:true
      ~emitted_option:"--prefix-length";
    boolean [ "--timings" ] ~env_names:[ "CONCURRENTLY_TIMINGS" ] ~env_order:9
      ~negated_names:[ "--no-timings" ] ~emitted_boolean_option:"--timings"
      ~boolean_order:10;
    boolean [ "--pad-prefix" ]
      ~env_names:[ "CONCURRENTLY_PAD_PREFIX" ]
      ~env_order:15 ~negated_names:[ "--no-pad-prefix" ]
      ~emitted_boolean_option:"--pad-prefix" ~boolean_order:11;
    value
      [ "-t"; "--timestamp-format" ]
      ~env_names:[ "CONCURRENTLY_TIMESTAMP_FORMAT"; "CONCURRENTLY_T" ]
      ~env_order:16 ~emitted_option:"--timestamp-format";
    boolean [ "-i"; "--handle-input" ]
      ~env_names:[ "CONCURRENTLY_HANDLE_INPUT"; "CONCURRENTLY_I" ]
      ~env_order:17 ~negated_names:[ "--no-handle-input" ]
      ~emitted_boolean_option:"--handle-input" ~boolean_order:7;
    value
      [ "--default-input-target" ]
      ~env_names:[ "CONCURRENTLY_DEFAULT_INPUT_TARGET" ]
      ~env_order:18 ~emitted_option:"--default-input-target";
    boolean [ "-k"; "--kill-others" ]
      ~env_names:[ "CONCURRENTLY_KILL_OTHERS"; "CONCURRENTLY_K" ]
      ~env_order:19 ~negated_names:[ "--no-kill-others" ]
      ~emitted_boolean_option:"--kill-others" ~boolean_order:8;
    boolean [ "--kill-others-on-success" ]
      ~env_names:[ "CONCURRENTLY_KILL_OTHERS_ON_SUCCESS" ]
      ~env_order:20
      ~negated_names:[ "--no-kill-others-on-success" ]
      ~emitted_boolean_option:"--kill-others-on-success" ~boolean_order:9;
    boolean
      [ "--kill-others-on-fail" ]
      ~env_names:[ "CONCURRENTLY_KILL_OTHERS_ON_FAIL" ]
      ~env_order:21
      ~negated_names:[ "--no-kill-others-on-fail" ]
      ~emitted_boolean_option:"--kill-others-on-fail" ~boolean_order:10;
    value
      [ "--kill-signal"; "--ks" ]
      ~env_names:[ "CONCURRENTLY_KILL_SIGNAL"; "CONCURRENTLY_KS" ]
      ~env_order:22 ~emitted_option:"--kill-signal";
    value [ "--kill-timeout" ]
      ~env_names:[ "CONCURRENTLY_KILL_TIMEOUT" ]
      ~env_order:23 ~accepts_negative_number_value:true
      ~emitted_option:"--kill-timeout";
    value [ "--restart-tries" ]
      ~env_names:[ "CONCURRENTLY_RESTART_TRIES" ]
      ~env_order:24 ~accepts_negative_number_value:true
      ~emitted_option:"--restart-tries";
    value [ "--restart-after" ]
      ~env_names:[ "CONCURRENTLY_RESTART_AFTER" ]
      ~env_order:25 ~accepts_negative_number_value:true
      ~emitted_option:"--restart-after";
    value [ "--api-display-command" ] ~emitted_option:"--api-display-command";
    value [ "--api-name-separator" ] ~emitted_option:"--api-name-separator";
    value [ "--api-hide-indexes" ] ~emitted_option:"--api-hide-indexes";
    value [ "--api-raw-indexes" ] ~emitted_option:"--api-raw-indexes";
    value [ "--api-formatted-indexes" ]
      ~emitted_option:"--api-formatted-indexes";
    value [ "--api-index-labels" ] ~emitted_option:"--api-index-labels";
    boolean [ "--api-empty-expansion" ] ~negated_names:[]
      ~emitted_boolean_option:"--api-empty-expansion" ~boolean_order:99;
  ]

let sort_ordered values =
  values
  |> List.sort (fun (left_order, _) (right_order, _) ->
      compare left_order right_order)
  |> List.map snd

let boolean_options =
  specs
  |> List.filter_map (fun spec ->
      match spec.kind with
      | Value _ -> None
      | Boolean { negated_names; emitted_boolean_option; boolean_order } ->
          Some
            ( boolean_order,
              {
                boolean_option_names = spec.names;
                negated_option_names = negated_names;
                emitted_boolean_option;
              } ))
  |> sort_ordered

let boolean_flag_option_names =
  List.concat_map (fun option -> option.boolean_option_names) boolean_options

let boolean_negated_option_names =
  List.concat_map (fun option -> option.negated_option_names) boolean_options

let short_boolean_flags =
  boolean_flag_option_names
  |> List.filter (fun option -> String.length option = 2 && option.[0] = '-')
  |> List.map (fun option -> option.[1])

let consumes_value option_name =
  specs
  |> List.exists (fun spec ->
      match spec.kind with
      | Value _ -> List.mem option_name spec.names
      | Boolean _ -> false)

let is_known_flag option_name =
  List.mem option_name boolean_flag_option_names
  || List.mem option_name boolean_negated_option_names

let is_known option_name =
  is_known_flag option_name || consumes_value option_name

let env_options =
  specs
  |> List.filter_map (fun spec ->
      match spec.env_binding with
      | None -> None
      | Some { env_names; env_order; emitted_option } ->
          let kind =
            match spec.kind with Boolean _ -> Env_flag | Value _ -> Env_value
          in
          Some
            ( env_order,
              { option_names = spec.names; env_names; kind; emitted_option } ))
  |> sort_ordered

let value_option_for_name option_name =
  specs
  |> List.find_map (fun spec ->
      match spec.kind with
      | Boolean _ -> None
      | Value value_option ->
          if List.mem option_name spec.names then Some value_option else None)

let emitted_value_option option_name =
  value_option_for_name option_name
  |> Option.map (fun value_option -> value_option.emitted_value_option)

let accepts_single_dash_prefixed_value option_name =
  match value_option_for_name option_name with
  | None -> false
  | Some { accepts_negative_number_value; accepts_negative_percent_value; _ } ->
      not (accepts_negative_number_value || accepts_negative_percent_value)

let dash_prefixed_value_is_negative_number value =
  String.length value > 1
  && value.[0] = '-'
  &&
  match float_of_string_opt value with
  | Some number -> number < 0.0
  | None -> false

let dash_prefixed_value_is_negative_percent value =
  String.length value > 2
  && value.[0] = '-'
  && value.[String.length value - 1] = '%'
  &&
  let number_text = String.sub value 0 (String.length value - 1) in
  match float_of_string_opt number_text with
  | Some number -> number < 0.0
  | None -> false

let accepts_dash_prefixed_value ~option_name ~value =
  match value_option_for_name option_name with
  | None -> false
  | Some { accepts_negative_number_value; accepts_negative_percent_value; _ } ->
      accepts_negative_number_value
      && dash_prefixed_value_is_negative_number value
      || accepts_negative_percent_value
         && (dash_prefixed_value_is_negative_number value
            || dash_prefixed_value_is_negative_percent value)
