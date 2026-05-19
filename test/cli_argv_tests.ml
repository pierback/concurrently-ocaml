module Cli_argv = Concurrentlyocaml.Cli_argv

let assert_array_equal expected actual =
  assert (Array.to_list actual = Array.to_list expected)

let env values name = List.assoc_opt name values

let test_requests_help_before_separator () =
  assert (Cli_argv.requests_help_before_separator [| "conc"; "-h" |]);
  assert (
    not
      (Cli_argv.requests_help_before_separator
         [| "conc"; "--prefix"; "-h"; "echo ok" |]));
  assert (not (Cli_argv.requests_help_before_separator [| "conc"; "--"; "-h" |]))

let test_normalized_builtin_help_value () =
  let normalized = Cli_argv.normalize [| "conc"; "--prefix"; "-h" |] in
  assert_array_equal [| "conc"; "--help" |] normalized.Cli_argv.argv;
  assert (Cli_argv.requests_help_before_separator normalized.Cli_argv.argv)

let test_requests_default_help () =
  assert (Cli_argv.requests_default_help [| "conc"; "--no-color" |]);
  assert (Cli_argv.requests_default_help [| "conc"; "--unknown" |]);
  assert (
    Cli_argv.requests_default_help
      [| "conc"; "--no-color"; "--success"; "missing" |]);
  assert (not (Cli_argv.requests_default_help [| "conc"; "--version" |]));
  assert (not (Cli_argv.requests_default_help [| "conc"; "printf ok" |]));
  assert (not (Cli_argv.requests_default_help [| "conc"; "--"; "--help" |]))

let test_extracts_passthrough_arguments () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "-P"; "echo {1}"; "--"; "--watch"; "client build" |]
  in
  assert_array_equal
    [| "conc"; "--passthrough-arguments"; "echo {1}" |]
    normalized.Cli_argv.argv;
  assert (
    normalized.Cli_argv.passthrough_arguments = [ "--watch"; "client build" ]);
  assert (not normalized.Cli_argv.deprecated_name_separator_used)

let test_tracks_deprecated_name_separator () =
  let normalized =
    Cli_argv.normalize [| "conc"; "--name-separator"; "|"; "echo ok" |]
  in
  assert normalized.Cli_argv.deprecated_name_separator_used;
  assert (normalized.Cli_argv.passthrough_arguments = [])

let test_normalizes_negative_option_values () =
  let normalized =
    Cli_argv.normalize
      [|
        "conc";
        "-m";
        "-50%";
        "--kill-timeout";
        "-1";
        "-l";
        "-2";
        "--restart-after";
        "-3";
        "--restart-tries";
        "-4";
      |]
  in
  assert_array_equal
    [|
      "conc";
      "--max-processes=-50%";
      "--kill-timeout=-1";
      "--prefix-length=-2";
      "--restart-after=-3";
      "--restart-tries=-4";
    |]
    normalized.Cli_argv.argv

let test_drops_dangling_value_options_before_unknown_options () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--no-color"; "--prefix"; "--unknown"; "value"; "printf ok" |]
  in
  assert_array_equal
    [| "conc"; "--no-color"; "printf ok" |]
    normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize
      [|
        "conc";
        "--no-color";
        "--max-processes";
        "-foo";
        "printf ok";
        "printf two";
      |]
  in
  assert_array_equal
    [| "conc"; "--no-color"; "printf two" |]
    normalized.Cli_argv.argv

let test_drops_dangling_value_options_before_boolean_options () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--no-color"; "--prefix"; "--raw"; "printf ok" |]
  in
  assert_array_equal
    [| "conc"; "--raw"; "--no-color"; "printf ok" |]
    normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--no-color"; "--prefix"; "--group"; "printf ok" |]
  in
  assert_array_equal
    [| "conc"; "--group"; "--no-color"; "printf ok" |]
    normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--no-color"; "--success"; "--raw"; "printf ok" |]
  in
  assert_array_equal
	    [| "conc"; "--raw"; "--no-color"; "printf ok" |]
	    normalized.Cli_argv.argv

let test_preserves_single_dash_string_option_values () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--prefix"; "-1"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--prefix=-1"; "printf one"; "printf two" |]
    normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--prefix"; "-x"; "printf one"; "printf two" |]
  in
  assert_array_equal [| "conc"; "printf two" |] normalized.Cli_argv.argv

let test_drops_unknown_short_inline_option_without_consuming_command () =
  let normalized =
    Cli_argv.normalize [| "conc"; "-x=value"; "echo one"; "echo two" |]
  in
  assert_array_equal
    [| "conc"; "echo one"; "echo two" |]
    normalized.Cli_argv.argv

let test_normalizes_short_inline_value_options () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "-p=raw"; "-n=api"; "-c=red.bold"; "printf one" |]
  in
  assert_array_equal
    [|
      "conc";
      "--prefix=raw";
      "--names=api";
      "--prefix-colors=red.bold";
      "printf one";
    |]
    normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "-x=value"; "-p=raw"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "--prefix=raw"; "printf one" |]
    normalized.Cli_argv.argv

let test_cli_options_override_env_defaults () =
  let normalized =
    Cli_argv.normalize_with_env
      ~env:
        (env
           [
             ("CONCURRENTLY_RAW", "true");
             ("CONCURRENTLY_PREFIX", "name");
             ("CONCURRENTLY_NAMES", "api");
           ])
      [| "conc"; "--raw=false"; "--prefix"; "index"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "--names=api"; "--prefix"; "index"; "printf one" |]
    normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize_with_env
      ~env:(env [ ("CONCURRENTLY_M", "1") ])
      [| "conc"; "-m2"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--max-processes=2"; "printf one"; "printf two" |]
    normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize_with_env
      ~env:(env [ ("CONCURRENTLY_L", "2") ])
      [| "conc"; "-l4"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--prefix-length=4"; "printf one"; "printf two" |]
    normalized.Cli_argv.argv

let test_negated_boolean_options_use_last_value () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--raw"; "--no-raw"; "--group"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--group"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--no-group"; "--group"; "--raw=false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--group"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--raw"; "--no-raw=false"; "--group"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "--group"; "--raw"; "printf one" |]
    normalized.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--group"; "--no-group=false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--group"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize_with_env
      ~env:(env [ ("CONCURRENTLY_RAW", "true") ])
      [| "conc"; "--no-raw=false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--raw"; "printf one" |] normalized.argv

let test_help_false_does_not_request_help () =
  assert (
    not
      (Cli_argv.requests_help_before_separator
         [| "conc"; "--help=false"; "printf one" |]));
  let normalized =
    Cli_argv.normalize [| "conc"; "--help=false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "printf one" |] normalized.argv

let test_short_boolean_groups_before_attached_values_preserve_commands () =
  let normalized =
    Cli_argv.normalize [| "conc"; "-rm2"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--raw"; "--max-processes=2"; "printf one"; "printf two" |]
    normalized.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "-kgm2"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [|
      "conc";
      "--group";
      "--kill-others";
      "--max-processes=2";
      "printf one";
      "printf two";
    |]
    normalized.argv

let test_compact_short_value_options_match_yargs_numeric_rules () =
  let normalized =
    Cli_argv.normalize [| "conc"; "-praw"; "printf one"; "printf two" |]
  in
  assert_array_equal [| "conc"; "--raw"; "printf two" |] normalized.argv;
	  let normalized =
	    Cli_argv.normalize [| "conc"; "-napi,web"; "printf one"; "printf two" |]
	  in
	  assert_array_equal
	    [| "conc"; "printf one"; "printf two" |]
	    normalized.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "-m50%"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--max-processes=50%"; "printf one"; "printf two" |]
    normalized.argv

let () =
  test_requests_help_before_separator ();
  test_normalized_builtin_help_value ();
  test_requests_default_help ();
  test_extracts_passthrough_arguments ();
  test_tracks_deprecated_name_separator ();
  test_normalizes_negative_option_values ();
  test_drops_dangling_value_options_before_unknown_options ();
  test_drops_dangling_value_options_before_boolean_options ();
  test_drops_unknown_short_inline_option_without_consuming_command ();
  test_normalizes_short_inline_value_options ();
  test_preserves_single_dash_string_option_values ();
  test_cli_options_override_env_defaults ();
  test_negated_boolean_options_use_last_value ();
  test_help_false_does_not_request_help ();
  test_short_boolean_groups_before_attached_values_preserve_commands ();
  test_compact_short_value_options_match_yargs_numeric_rules ()
