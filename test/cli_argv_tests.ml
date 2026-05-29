module Cli_argv = Concurrentlyocaml.Cli_argv

let assert_array_equal expected actual =
  assert (Array.to_list actual = Array.to_list expected)

let env values name = List.assoc_opt name values

let test_requests_help_before_separator () =
  assert (Cli_argv.requests_help_before_separator [| "conc"; "-h" |]);
  assert (
    not
      (Cli_argv.requests_help_before_separator
         [| "conc"; "-h"; "false"; "printf ok" |]));
  assert (
    Cli_argv.requests_help_before_separator
      [| "conc"; "-h"; "true"; "printf ok" |]);
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
  let normalized = Cli_argv.normalize [| "conc"; "--version"; "false" |] in
  assert (Cli_argv.requests_default_help normalized.argv);
  assert (not (Cli_argv.requests_default_help [| "conc"; "printf ok" |]));
  assert (
    not (Cli_argv.requests_default_help [| "conc"; "--api-empty-expansion" |]));
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

let test_passthrough_separator_before_commands_leaves_no_commands () =
  let normalized = Cli_argv.normalize [| "conc"; "-P"; "--"; "--watch" |] in
  assert_array_equal
    [| "conc"; "--passthrough-arguments" |]
    normalized.Cli_argv.argv;
  assert (normalized.Cli_argv.passthrough_arguments = [ "--watch" ]);
  assert (Cli_argv.requests_default_help normalized.Cli_argv.argv);
  let normalized =
    Cli_argv.normalize
      [| "conc"; "-P"; "--"; "echo {1}"; "--"; "--watch" |]
  in
  assert_array_equal
    [| "conc"; "--passthrough-arguments" |]
    normalized.Cli_argv.argv;
  assert (
    normalized.Cli_argv.passthrough_arguments
    = [ "echo {1}"; "--"; "--watch" ]);
  assert (Cli_argv.requests_default_help normalized.Cli_argv.argv)

let test_treats_removed_name_separator_as_unknown () =
  let normalized =
    Cli_argv.normalize [| "conc"; "--name-separator"; "|"; "echo ok" |]
  in
  assert (not normalized.Cli_argv.deprecated_name_separator_used);
  assert_array_equal [| "conc"; "echo ok" |] normalized.Cli_argv.argv;
  let normalized =
    Cli_argv.normalize
      [|
        "conc";
        "--names";
        "a,b";
        "--name-separator";
        "";
        "printf one";
        "printf two";
      |]
  in
  assert_array_equal
    [| "conc"; "--names"; "a,b"; "printf one"; "printf two" |]
    normalized.Cli_argv.argv;
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

let test_api_ignore_env_options_flag_removes_env_defaults () =
  let normalized =
    Cli_argv.normalize_with_env
      ~env:
        (env
           [
             ("CONCURRENTLY_SUCCESS", "first");
             ("CONCURRENTLY_RAW", "true");
           ])
      [| "conc"; "--api-ignore-env-options"; "printf one"; "printf two" |]
  in
  assert_array_equal [| "conc"; "printf one"; "printf two" |] normalized.argv;
  let normalized =
    Cli_argv.normalize_with_env
      ~env:(env [ ("CONCURRENTLY_SUCCESS", "first") ])
      [| "conc"; "--"; "--api-ignore-env-options" |]
  in
  assert_array_equal
    [| "conc"; "--success=first"; "--"; "--api-ignore-env-options" |]
    normalized.argv

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

let test_positive_boolean_options_consume_separate_true_false_values () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--raw"; "false"; "--group"; "true"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--group"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--raw"; "true"; "--group"; "false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--raw"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "-P"; "false"; "printf {1}"; "--"; "arg" |]
  in
  assert_array_equal
    [| "conc"; "printf {1}"; "--"; "arg" |]
    normalized.argv;
  assert (normalized.passthrough_arguments = []);
  let normalized =
    Cli_argv.normalize [| "conc"; "-P"; "true"; "printf {1}"; "--"; "arg" |]
  in
  assert_array_equal
    [| "conc"; "--passthrough-arguments"; "printf {1}" |]
    normalized.argv;
  assert (normalized.passthrough_arguments = [ "arg" ])

let test_no_color_preserves_separate_true_false_commands () =
  let normalized =
    Cli_argv.normalize [| "conc"; "--no-color"; "false"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "--no-color"; "false"; "printf one" |]
    normalized.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "--no-color"; "true"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "--no-color"; "true"; "printf one" |]
    normalized.argv

let test_negated_boolean_options_do_not_consume_separate_true_false_values () =
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--raw"; "--no-raw"; "false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "false"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize
      [| "conc"; "--group"; "--no-group"; "true"; "printf one" |]
  in
  assert_array_equal [| "conc"; "true"; "printf one" |] normalized.argv

let test_help_false_does_not_request_help () =
  assert (
    not
      (Cli_argv.requests_help_before_separator
         [| "conc"; "--help=false"; "printf one" |]));
  let normalized =
    Cli_argv.normalize [| "conc"; "--help=false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "--help"; "false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "-h"; "false"; "printf one" |]
  in
  assert_array_equal [| "conc"; "printf one" |] normalized.argv;
  let normalized =
    Cli_argv.normalize [| "conc"; "--version"; "false"; "printf one" |]
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
  test_passthrough_separator_before_commands_leaves_no_commands ();
  test_treats_removed_name_separator_as_unknown ();
  test_normalizes_negative_option_values ();
  test_drops_dangling_value_options_before_unknown_options ();
  test_drops_dangling_value_options_before_boolean_options ();
  test_drops_unknown_short_inline_option_without_consuming_command ();
  test_normalizes_short_inline_value_options ();
  test_preserves_single_dash_string_option_values ();
  test_cli_options_override_env_defaults ();
  test_api_ignore_env_options_flag_removes_env_defaults ();
  test_negated_boolean_options_use_last_value ();
  test_positive_boolean_options_consume_separate_true_false_values ();
  test_no_color_preserves_separate_true_false_commands ();
  test_negated_boolean_options_do_not_consume_separate_true_false_values ();
  test_help_false_does_not_request_help ();
  test_short_boolean_groups_before_attached_values_preserve_commands ();
  test_compact_short_value_options_match_yargs_numeric_rules ()
