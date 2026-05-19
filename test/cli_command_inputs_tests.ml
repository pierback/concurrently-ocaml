module Cli_command_inputs = Concurrentlyocaml.Cli_command_inputs

let command_texts inputs = List.map Cli_command_inputs.command_text inputs
let command_names inputs = List.map Cli_command_inputs.command_name inputs

let expand ~cwd ~passthrough_arguments ~command_texts ~names =
  match
    Cli_command_inputs.expand ~cwd ~passthrough_arguments ~command_texts ~names
  with
  | Ok inputs -> inputs
  | Error _ -> assert false

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

let test_expands_passthrough_after_shortcuts () =
  let inputs =
    expand ~cwd:None
      ~passthrough_arguments:(Some [ "client build" ])
      ~command_texts:[ "npm:{1}" ] ~names:None
  in
  assert (command_texts inputs = [ "npm run 'client build'" ]);
  assert (command_names inputs = [ "{1}" ])

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
  let cwd = Filename.concat (Filename.get_temp_dir_name ()) "concurrently-ocaml-wildcard-test" in
  let package_json = Filename.concat cwd "package.json" in
  let cleanup () =
    match Sys.remove package_json with
    | () -> Sys.rmdir cwd
    | exception _ -> ()
  in
  cleanup ();
  Unix.mkdir cwd 0o700;
  Out_channel.with_open_text package_json (fun channel ->
    output_string channel
      {|{"scripts":{"client build":"printf spaced","build-js":"printf js"}}|});
  let inputs =
    expand ~cwd:(Some cwd) ~passthrough_arguments:None
      ~command_texts:[ "npm:*" ] ~names:None
  in
  cleanup ();
  assert (command_texts inputs = [ "npm run client build"; "npm run build-js" ]);
  assert (command_names inputs = [ "client build"; "build-js" ])

let test_wildcard_omission_matches_full_script_name () =
  let cwd = Filename.concat (Filename.get_temp_dir_name ()) "concurrently-ocaml-omission-test" in
  let package_json = Filename.concat cwd "package.json" in
  let cleanup () =
    match Sys.remove package_json with
    | () -> Sys.rmdir cwd
    | exception _ -> ()
  in
  cleanup ();
  Unix.mkdir cwd 0o700;
  Out_channel.with_open_text package_json (fun channel ->
    output_string channel
      {|{"scripts":{"build-css":"printf css","test-js":"printf js"}}|});
  let inputs =
    expand ~cwd:(Some cwd) ~passthrough_arguments:None
      ~command_texts:[ "npm:build-*(!build)" ] ~names:None
  in
  cleanup ();
  assert (inputs = [])

let test_invalid_wildcard_omission_is_error () =
  let cwd =
    Filename.concat (Filename.get_temp_dir_name ())
      "concurrently-ocaml-invalid-omission-test"
  in
  let package_json = Filename.concat cwd "package.json" in
  let cleanup () =
    match Sys.remove package_json with
    | () -> Sys.rmdir cwd
    | exception _ -> ()
  in
  cleanup ();
  Unix.mkdir cwd 0o700;
  Out_channel.with_open_text package_json (fun channel ->
    output_string channel {|{"scripts":{"build-js":"printf js"}}|});
  let result =
    Cli_command_inputs.expand ~cwd:(Some cwd) ~passthrough_arguments:None
      ~command_texts:[ "npm:build-*(![)" ] ~names:None
  in
  cleanup ();
  assert (result = Error (`Invalid_wildcard_omission "["))

let () =
  test_expands_shortcuts_and_effective_names ();
  test_preserves_explicit_shortcut_name ();
  test_expands_passthrough_after_shortcuts ();
  test_expands_non_npm_shortcuts ();
  test_wildcard_scripts_are_not_shell_quoted ();
  test_wildcard_omission_matches_full_script_name ();
  test_invalid_wildcard_omission_is_error ()
