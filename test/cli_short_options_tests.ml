module Cli_short_options = Concurrentlyocaml.Cli_short_options

let assert_array_equal expected actual =
  assert (Array.to_list actual = Array.to_list expected)

let test_expands_short_boolean_groups () =
  let actual =
    Cli_short_options.expand_clusters [| "conc"; "-kg"; "printf one" |]
  in
  assert_array_equal [| "conc"; "-k"; "-g"; "printf one" |] actual;
  let actual =
    Cli_short_options.expand_clusters [| "conc"; "-rg"; "printf one" |]
  in
  assert_array_equal [| "conc"; "-r"; "-g"; "printf one" |] actual

let test_expands_known_booleans_in_mixed_short_groups () =
  let actual =
    Cli_short_options.expand_clusters
      [| "conc"; "-xg"; "printf one"; "printf two" |]
  in
  assert_array_equal [| "conc"; "-g"; "printf one"; "printf two" |] actual;
  let actual =
    Cli_short_options.expand_clusters
      [| "conc"; "-xr"; "printf one"; "printf two" |]
  in
  assert_array_equal [| "conc"; "-r"; "printf one"; "printf two" |] actual;
  let actual =
    Cli_short_options.expand_clusters
      [| "conc"; "-rx"; "printf one"; "printf two" |]
  in
  assert_array_equal [| "conc"; "-r"; "-x"; "printf one"; "printf two" |] actual

let test_expands_numeric_compact_short_values () =
  let actual =
    Cli_short_options.expand_clusters
      [| "conc"; "-m1.5"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--max-processes=1.5"; "printf one"; "printf two" |]
    actual;
  let actual =
    Cli_short_options.expand_clusters
      [| "conc"; "-l-1"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--prefix-length=-1"; "printf one"; "printf two" |]
    actual;
  let actual =
    Cli_short_options.expand_clusters
      [| "conc"; "-m50%"; "printf one"; "printf two" |]
  in
  assert_array_equal
    [| "conc"; "--max-processes=50%"; "printf one"; "printf two" |]
    actual

let test_expands_boolean_groups_before_attached_values () =
  let actual =
    Cli_short_options.expand_clusters [| "conc"; "-rm2"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "-r"; "--max-processes=2"; "printf one" |]
    actual;
  let actual =
    Cli_short_options.expand_clusters [| "conc"; "-kgm2"; "printf one" |]
  in
  assert_array_equal
    [| "conc"; "-k"; "-g"; "--max-processes=2"; "printf one" |]
    actual

let test_string_value_options_do_not_bind_compact_suffixes () =
  let actual =
    Cli_short_options.expand_clusters [| "conc"; "-praw"; "printf one" |]
  in
  assert_array_equal [| "conc"; "-r"; "-aw"; "printf one" |] actual;
	  let actual =
	    Cli_short_options.expand_clusters [| "conc"; "-napi,web"; "printf one" |]
	  in
	  assert_array_equal [| "conc"; "printf one" |] actual

let test_preserves_arguments_after_separator () =
  let actual =
    Cli_short_options.expand_clusters
      [| "conc"; "-r"; "--"; "-kg"; "printf one" |]
  in
  assert_array_equal [| "conc"; "-r"; "--"; "-kg"; "printf one" |] actual

let test_preserves_dash_prefixed_program_name () =
  let actual =
    Cli_short_options.expand_clusters [| "-m1"; "-kg"; "printf one" |]
  in
  assert_array_equal [| "-m1"; "-k"; "-g"; "printf one" |] actual

let () =
  test_expands_short_boolean_groups ();
  test_expands_known_booleans_in_mixed_short_groups ();
  test_expands_numeric_compact_short_values ();
  test_expands_boolean_groups_before_attached_values ();
  test_string_value_options_do_not_bind_compact_suffixes ();
  test_preserves_arguments_after_separator ();
  test_preserves_dash_prefixed_program_name ()
