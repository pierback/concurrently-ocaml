module Cli_command_inputs = Concurrentlyocaml.Cli_command_inputs

let command_texts inputs = List.map Cli_command_inputs.command_text inputs
let command_names inputs = List.map Cli_command_inputs.command_name inputs

let expand ~cwd ~passthrough_arguments ~command_texts ~names =
  match
    Cli_command_inputs.expand ~cwd ~passthrough_arguments ~command_texts ~names
  with
  | Ok inputs -> inputs
  | Error _ -> assert false

let with_temp_dir suffix f =
  let cwd =
    Filename.concat (Filename.get_temp_dir_name ())
      ("concurrently-ocaml-" ^ suffix)
  in
  let cleanup () =
    let remove_files () =
      Array.iter
        (fun name -> (try Sys.remove (Filename.concat cwd name) with _ -> ()))
        (try Sys.readdir cwd with _ -> [||])
    in
    remove_files ();
    (try Sys.rmdir cwd with _ -> ())
  in
  cleanup ();
  Unix.mkdir cwd 0o700;
  Fun.protect ~finally:cleanup (fun () -> f cwd)

let test_expands_shortcuts_and_effective_names () =
  let inputs =
    expand ~cwd:None ~passthrough_arguments:None
      ~command_texts:[ "npm:print -- --flag"; "printf normal" ]
      ~names:None
  in
  assert (command_texts inputs = [ "npm run print -- --flag"; "printf normal" ]);
  assert (command_names inputs = [ "print"; "" ]);
  assert (Cli_command_inputs.effective_names inputs = Some [ "print"; "" ])

let test_preserves_explicit_shortcut_name () =
  let inputs =
    expand ~cwd:None ~passthrough_arguments:None
      ~command_texts:[ "npm:print" ] ~names:(Some [ "custom" ])
  in
  assert (command_texts inputs = [ "npm run print" ]);
  assert (command_names inputs = [ "custom" ])

let test_does_not_expand_shortcut_without_script () =
  let inputs =
    expand ~cwd:None ~passthrough_arguments:None
      ~command_texts:[ "npm:"; "npm: print" ] ~names:None
  in
  assert (command_texts inputs = [ "npm:"; "npm: print" ]);
  assert (command_names inputs = [ ""; "" ])

let test_strips_empty_quoted_commands () =
  let inputs =
    expand ~cwd:None ~passthrough_arguments:None
      ~command_texts:[ "\"\""; "''"; "\" \"" ] ~names:None
  in
  assert (command_texts inputs = [ ""; ""; " " ]);
  assert (command_names inputs = [ ""; ""; "" ])

let test_expands_passthrough_after_shortcuts () =
  let inputs =
    expand ~cwd:None
      ~passthrough_arguments:(Some [ "client build" ])
      ~command_texts:[ "npm:{1}" ] ~names:None
  in
  assert (command_texts inputs = [ "npm run 'client build'" ]);
  assert (command_names inputs = [ "{1}" ])

let test_expands_passthrough_with_upstream_shell_quote () =
  let inputs =
    expand ~cwd:None
      ~passthrough_arguments:(Some [ "alpha"; "beta" ])
      ~command_texts:
        [ "node -e \"process.stdout.write(process.argv.join('|'))\" {1} {@} {*}" ]
      ~names:None
  in
  assert (
    command_texts inputs
    = [
        "node -e \"process.stdout.write(process.argv.join('|'))\" alpha alpha beta 'alpha beta'";
      ])

let test_expands_non_npm_shortcuts () =
  let inputs =
    expand ~cwd:None ~passthrough_arguments:None
      ~command_texts:
        [
          "yarn:print";
          "pnpm:print";
          "bun:print";
          "node:print";
          "deno:print";
        ]
      ~names:None
  in
  assert (
    command_texts inputs
    = [
        "yarn run print";
        "pnpm run print";
        "bun run print";
        "node --run print";
        "deno task print";
      ]);
  assert (command_names inputs = [ "print"; "print"; "print"; "print"; "print" ])

let test_wildcard_scripts_are_not_shell_quoted () =
  with_temp_dir "wildcard-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel
        {|{"scripts":{"client build":"printf spaced","build-js":"printf js"}}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "npm:*" ] ~names:None
    in
    assert (command_texts inputs = [ "npm run client build"; "npm run build-js" ]);
    assert (command_names inputs = [ "client build"; "build-js" ]))

let test_wildcard_omission_matches_full_script_name () =
  with_temp_dir "omission-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel
        {|{"scripts":{"build-css":"printf css","test-js":"printf js"}}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "npm:build-*(!build)" ] ~names:None
    in
    assert (inputs = []))

let test_wildcard_args_stop_at_ampersand () =
  with_temp_dir "wildcard-ampersand-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel
        {|{"scripts":{"build-css":"printf css","build-js":"printf js"}}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "npm:build-* && printf after" ] ~names:None
    in
    assert (command_texts inputs = [ "npm run build-css "; "npm run build-js " ]);
    assert (command_names inputs = [ "css"; "js" ]))

let test_wildcard_finds_embedded_runner_like_upstream () =
  with_temp_dir "embedded-wildcard-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel
        {|{"scripts":{"build-css":"printf css","build-js":"printf js"}}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "printf pre && npm run build-* -- --flag" ] ~names:None
    in
    assert (
      command_texts inputs
      = [ "npm run build-css -- --flag"; "npm run build-js -- --flag" ]);
    assert (command_names inputs = [ "css"; "js" ]))

let test_wildcard_decodes_json_unicode_script_keys () =
  with_temp_dir "unicode-script-key-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel
        {|{"scripts":{"build-\u0061":"printf a","emoji-\uD83D\uDE00":"printf emoji"}}|});
    let emoji = "\xF0\x9F\x98\x80" in
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "npm:*" ] ~names:None
    in
    assert (command_texts inputs = [ "npm run build-a"; "npm run emoji-" ^ emoji ]);
    assert (command_names inputs = [ "build-a"; "emoji-" ^ emoji ]))

let test_wildcard_ignores_invalid_package_json () =
  with_temp_dir "invalid-package-json-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel {|{"scripts":{"build-js":"printf js",}}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "npm:build-*" ] ~names:None
    in
    assert (inputs = []))

let test_wildcard_uses_javascript_object_keys_for_package_scripts () =
  with_temp_dir "package-object-keys-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel {|{"scripts":"ab"}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:*" ] ~names:None
    in
    assert (command_texts inputs = [ "deno task 0"; "deno task 1" ]);
    assert (command_names inputs = [ "0"; "1" ]))

let test_wildcard_uses_last_duplicate_package_scripts_field () =
  with_temp_dir "duplicate-package-scripts-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel
        {|{"scripts":{"task-old":"printf old"},"scripts":["printf new"]}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:*" ] ~names:None
    in
    assert (command_texts inputs = [ "deno task 0" ]);
    assert (command_names inputs = [ "0" ]))

let test_wildcard_uses_javascript_object_key_order_for_package_scripts () =
  with_temp_dir "object-key-order-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel
        {|{"scripts":{"b":"printf b","2":"printf two","1":"printf one","a":"printf a","2":"printf overwrite","01":"printf leading"}}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None ~command_texts:[ "npm:*" ]
        ~names:None
    in
    assert (
      command_texts inputs
      = [
          "npm run 1";
          "npm run 2";
          "npm run b";
          "npm run a";
          "npm run 01";
        ]);
    assert (command_names inputs = [ "1"; "2"; "b"; "a"; "01" ]))

let test_deno_wildcard_accepts_jsonc_comments_and_trailing_commas () =
  with_temp_dir "deno-jsonc-test" (fun cwd ->
    let deno_jsonc = Filename.concat cwd "deno.jsonc" in
    Out_channel.with_open_text deno_jsonc (fun channel ->
      output_string channel
        {|{// comment
"tasks":{"task-api":"printf api",},}
|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:task-*" ] ~names:None
    in
    assert (command_texts inputs = [ "deno task task-api" ]);
    assert (command_names inputs = [ "api" ]))

let test_deno_wildcard_accepts_jsonc_carriage_return_line_comment () =
  with_temp_dir "deno-jsonc-cr-test" (fun cwd ->
    let deno_jsonc = Filename.concat cwd "deno.jsonc" in
    Out_channel.with_open_text deno_jsonc (fun channel ->
      output_string channel
        ("{// comment\r" ^ {|"tasks":{"task-api":"printf api"}}|}));
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:task-*" ] ~names:None
    in
    assert (command_texts inputs = [ "deno task task-api" ]);
    assert (command_names inputs = [ "api" ]))

let test_deno_wildcard_ignores_invalid_jsonc () =
  with_temp_dir "invalid-deno-jsonc-test" (fun cwd ->
    let deno_json = Filename.concat cwd "deno.json" in
    Out_channel.with_open_text deno_json (fun channel ->
      output_string channel {|{"tasks":{"task-api":"printf api"}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:task-*" ] ~names:None
    in
    assert (inputs = []))

let test_deno_wildcard_ignores_unterminated_jsonc_block_comment () =
  with_temp_dir "unterminated-deno-jsonc-test" (fun cwd ->
    let deno_jsonc = Filename.concat cwd "deno.jsonc" in
    Out_channel.with_open_text deno_jsonc (fun channel ->
      output_string channel {|{"tasks":{"task-api":"printf api"}}/*|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:task-*" ] ~names:None
    in
    assert (inputs = []))

let test_deno_wildcard_uses_last_duplicate_tasks_field () =
  with_temp_dir "duplicate-deno-tasks-test" (fun cwd ->
    let deno_json = Filename.concat cwd "deno.json" in
    Out_channel.with_open_text deno_json (fun channel ->
      output_string channel
        {|{"tasks":{"task-old":"printf old"},"tasks":{"task-new":"printf new"}}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:task-*" ] ~names:None
    in
    assert (command_texts inputs = [ "deno task task-new" ]);
    assert (command_names inputs = [ "new" ]))

let test_deno_wildcard_uses_javascript_object_keys_for_task_values () =
  with_temp_dir "deno-object-keys-test" (fun cwd ->
    let deno_json = Filename.concat cwd "deno.json" in
    Out_channel.with_open_text deno_json (fun channel ->
      output_string channel {|{"tasks":["printf old","printf new"]}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:*" ] ~names:None
    in
    assert (command_texts inputs = [ "deno task 0"; "deno task 1" ]);
    assert (command_names inputs = [ "0"; "1" ]))

let test_deno_wildcard_uses_utf16_indices_for_string_tasks () =
  with_temp_dir "deno-string-task-indices-test" (fun cwd ->
    let deno_json = Filename.concat cwd "deno.json" in
    Out_channel.with_open_text deno_json (fun channel ->
      output_string channel {|{"tasks":"a\uD83D\uDE00"}|});
    let inputs =
      expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "deno:*" ] ~names:None
    in
    assert (command_texts inputs = [ "deno task 0"; "deno task 1"; "deno task 2" ]);
    assert (command_names inputs = [ "0"; "1"; "2" ]))

let test_invalid_wildcard_omission_is_error () =
  with_temp_dir "invalid-omission-test" (fun cwd ->
    let package_json = Filename.concat cwd "package.json" in
    Out_channel.with_open_text package_json (fun channel ->
      output_string channel {|{"scripts":{"build-js":"printf js"}}|});
    let result =
      Cli_command_inputs.expand ~cwd:(Some cwd) ~passthrough_arguments:None
        ~command_texts:[ "npm:build-*(![)" ] ~names:None
    in
    assert (result = Error (`Invalid_wildcard_omission "[")))

let () =
  test_expands_shortcuts_and_effective_names ();
  test_preserves_explicit_shortcut_name ();
  test_does_not_expand_shortcut_without_script ();
  test_strips_empty_quoted_commands ();
  test_expands_passthrough_after_shortcuts ();
  test_expands_passthrough_with_upstream_shell_quote ();
  test_expands_non_npm_shortcuts ();
  test_wildcard_scripts_are_not_shell_quoted ();
  test_wildcard_omission_matches_full_script_name ();
  test_wildcard_args_stop_at_ampersand ();
  test_wildcard_finds_embedded_runner_like_upstream ();
  test_wildcard_decodes_json_unicode_script_keys ();
  test_wildcard_ignores_invalid_package_json ();
  test_wildcard_uses_javascript_object_keys_for_package_scripts ();
  test_wildcard_uses_last_duplicate_package_scripts_field ();
  test_wildcard_uses_javascript_object_key_order_for_package_scripts ();
  test_deno_wildcard_accepts_jsonc_comments_and_trailing_commas ();
  test_deno_wildcard_accepts_jsonc_carriage_return_line_comment ();
  test_deno_wildcard_ignores_invalid_jsonc ();
  test_deno_wildcard_ignores_unterminated_jsonc_block_comment ();
  test_deno_wildcard_uses_last_duplicate_tasks_field ();
  test_deno_wildcard_uses_javascript_object_keys_for_task_values ();
  test_deno_wildcard_uses_utf16_indices_for_string_tasks ();
  test_invalid_wildcard_omission_is_error ()
