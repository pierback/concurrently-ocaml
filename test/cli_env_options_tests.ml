module Cli_env_options = Concurrentlyocaml.Cli_env_options

let assert_array_equal expected actual =
  assert (Array.to_list actual = Array.to_list expected)

let env values name = List.assoc_opt name values

let option_was_provided provided_names option_names =
  List.exists
    (fun provided_name -> List.mem provided_name option_names)
    provided_names

let add ?(provided_names = []) env_values argv =
  Cli_env_options.add_arguments ~env:(env env_values)
    ~option_was_provided:(option_was_provided provided_names)
    argv

let test_adds_missing_env_arguments_after_program_name () =
  let actual =
    add
      [ ("CONCURRENTLY_MAX_PROCESSES", "2"); ("CONCURRENTLY_NAMES", "api,web") ]
      [| "conc"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "--max-processes=2"; "--names=api,web"; "printf one" |]
    actual

let test_cli_options_override_env_arguments () =
  let actual =
    add ~provided_names:[ "--prefix"; "-r" ]
      [
        ("CONCURRENTLY_RAW", "true");
        ("CONCURRENTLY_PREFIX", "name");
        ("CONCURRENTLY_NAMES", "api");
      ]
      [| "conc"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--names=api"; "printf one" |] actual

let test_env_aliases_match_yargs_aliases () =
  let actual =
    add
      [
        ("CONCURRENTLY_K", "true");
        ("CONCURRENTLY_L", "2");
        ("CONCURRENTLY_C", "red.bold");
      ]
      [| "conc"; "printf one" |]
  in
  assert_array_equal
    [|
      "conc";
      "--prefix-colors=red.bold";
      "--prefix-length=2";
      "--kill-others";
      "printf one";
    |]
    actual

let test_env_boolean_values_match_yargs_true_only_coercion () =
  let actual =
    add
      [
        ("CONCURRENTLY_GROUP", "1");
        ("CONCURRENTLY_RAW", "TRUE");
        ("CONCURRENTLY_TIMINGS", "true");
      ]
      [| "conc"; "printf one" |]
  in
  assert_array_equal [| "conc"; "--timings"; "printf one" |] actual

let test_empty_argv_receives_env_arguments () =
  let actual =
    add
      [ ("CONCURRENTLY_MAX_PROCESSES", "2"); ("CONCURRENTLY_RAW", "true") ]
      [||]
  in
  assert_array_equal [| "--max-processes=2"; "--raw" |] actual

let () =
  test_adds_missing_env_arguments_after_program_name ();
  test_cli_options_override_env_arguments ();
  test_env_aliases_match_yargs_aliases ();
  test_env_boolean_values_match_yargs_true_only_coercion ();
  test_empty_argv_receives_env_arguments ()
