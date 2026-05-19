type t = {
  command_text : string;
  command_name : string;
  has_command_name : bool;
}

type script_catalog = {
  package_scripts : string list;
  deno_tasks : string list;
}

type expand_error = [ `Invalid_wildcard_omission of string ]

let command_text t = t.command_text
let command_name t = t.command_name
let has_command_name t = t.has_command_name

let shortcut_runner = function
  | "npm" -> Some "npm run"
  | "yarn" -> Some "yarn run"
  | "pnpm" -> Some "pnpm run"
  | "bun" -> Some "bun run"
  | "node" -> Some "node --run"
  | "deno" -> Some "deno task"
  | _ -> None

let is_whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

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

let input ?(command_name = "") ?(has_command_name = false) command_text =
  { command_text; command_name; has_command_name }

let name_at names index =
  match names with None -> None | Some values -> List.nth_opt values index

let strip_quotes command_input =
  let command_text = command_input.command_text in
  let length = String.length command_text in
  if
    length > 2
    && ((command_text.[0] = '"' && command_text.[length - 1] = '"')
       || (command_text.[0] = '\'' && command_text.[length - 1] = '\''))
  then
    { command_input with command_text = String.sub command_text 1 (length - 2) }
  else command_input

let expand_shortcut_text command_text =
  match String.index_opt command_text ':' with
  | None -> input command_text
  | Some separator_index -> (
      let prefix = String.sub command_text 0 separator_index in
      match shortcut_runner prefix with
      | None -> input command_text
      | Some runner ->
          let script_start = separator_index + 1 in
          let command_length = String.length command_text in
          if script_start = command_length then input command_text
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
            input ~command_name:script ~has_command_name:true
              (runner ^ " " ^ script ^ suffix))

let expand_shortcut command_input =
  match expand_shortcut_text command_input.command_text with
  | { has_command_name = false; command_text; _ } ->
      { command_input with command_text }
  | expanded ->
      let command_name =
        if
          command_input.has_command_name
          && not (String.equal command_input.command_name "")
        then command_input.command_name
        else expanded.command_name
      in
      { expanded with command_name; has_command_name = true }

let command_prefixes =
  [ "npm run"; "yarn run"; "pnpm run"; "bun run"; "node --run"; "deno task" ]

let wildcard_args command_text script_end =
  let command_length = String.length command_text in
  let args_end =
    match String.index_from_opt command_text script_end '&' with
    | None -> command_length
    | Some index -> index
  in
  assert (args_end >= script_end);
  String.sub command_text script_end (args_end - script_end)

let starts_with_at value start prefix =
  let value_length = String.length value in
  let prefix_length = String.length prefix in
  assert (start >= 0);
  assert (start <= value_length);
  if start + prefix_length > value_length then false
  else
    let rec loop offset =
      if offset = prefix_length then true
      else if value.[start + offset] <> prefix.[offset] then false
      else loop (offset + 1)
    in
    loop 0

let command_script_and_args_at command_text command match_start =
  let prefix = command ^ " " in
  let prefix_length = String.length prefix in
  if not (starts_with_at command_text match_start prefix) then None
  else
    let script_start = match_start + prefix_length in
    let command_length = String.length command_text in
    if script_start = command_length || is_whitespace command_text.[script_start]
    then None
    else
      let script_end =
        match find_first_whitespace_from command_text script_start with
        | None -> command_length
        | Some index -> index
      in
      let script_glob =
        String.sub command_text script_start (script_end - script_start)
      in
      let args = wildcard_args command_text script_end in
      Some (command, script_glob, args)

let wildcard_command command_text =
  let command_length = String.length command_text in
  let rec loop index =
    if index = command_length then None
    else
      match
        List.find_map
          (fun command -> command_script_and_args_at command_text command index)
          command_prefixes
      with
      | Some _ as result -> result
      | None -> loop (index + 1)
  in
  loop 0

let omission script_glob =
  match String.index_opt script_glob '(' with
  | None -> None
  | Some open_index -> (
      if
        open_index + 1 >= String.length script_glob
        || script_glob.[open_index + 1] <> '!'
      then None
      else
        match String.index_from_opt script_glob (open_index + 2) ')' with
        | None -> None
        | Some close_index ->
            let omitted =
              String.sub script_glob (open_index + 2)
                (close_index - open_index - 2)
            in
            let without =
              String.sub script_glob 0 open_index
              ^ String.sub script_glob (close_index + 1)
                  (String.length script_glob - close_index - 1)
            in
            Some (omitted, without))

let omitted_by_pattern omission_regexp script =
  match Str.search_forward omission_regexp script 0 with
  | _ -> true
  | exception _ -> false

let omission_regexp value =
  match Str.regexp value with
  | regexp -> Ok regexp
  | exception _ -> Error (`Invalid_wildcard_omission value)

let wildcard_match ~pattern ~wildcard_position script =
  let pattern_length = String.length pattern in
  let prefix = String.sub pattern 0 (min wildcard_position pattern_length) in
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
  else
    Some
      (String.sub script prefix_length
         (script_length - prefix_length - suffix_length))

let script_catalog ~cwd =
  {
    package_scripts = Script_catalog.package_scripts ~cwd;
    deno_tasks = Script_catalog.deno_tasks ~cwd;
  }

let relevant_scripts script_catalog command =
  if String.equal command "deno task" then
    script_catalog.deno_tasks @ script_catalog.package_scripts
  else script_catalog.package_scripts

let expand_wildcard ~script_catalog command_input =
  match wildcard_command command_input.command_text with
  | None -> Ok [ command_input ]
  | Some (command, script_glob, args) -> (
      match String.index_opt script_glob '*' with
      | None -> Ok [ command_input ]
      | Some wildcard_position -> (
          let omission_config =
            match omission script_glob with
            | None -> Ok (None, script_glob)
            | Some (omission, pattern) ->
                omission_regexp omission
                |> Result.map (fun regexp -> (Some regexp, pattern))
          in
          match omission_config with
          | Error error -> Error error
          | Ok (omission_regexp, pattern) ->
              let name_prefix =
                if String.equal command_input.command_name script_glob then ""
                else command_input.command_name
              in
              relevant_scripts script_catalog command
              |> List.filter_map (fun script ->
                     match wildcard_match ~pattern ~wildcard_position script with
                     | None -> None
                     | Some match_text ->
                         (* Published concurrently@9.2.1 applies omissions to the
                            full script name and appends that name verbatim to the
                            shell command, including spaces and metacharacters. *)
                         if
                           match omission_regexp with
                           | Some omission_regexp ->
                               omitted_by_pattern omission_regexp script
                           | None -> false
                         then None
                         else
                           let command_name = name_prefix ^ match_text in
                           Some
                             {
                               command_text = command ^ " " ^ script ^ args;
                               command_name;
                               has_command_name = true;
                             })
              |> fun command_inputs -> Ok command_inputs))

let expand_arguments ~additional_arguments command_input =
  {
    command_input with
    command_text =
      Argument_expander.expand ~additional_arguments command_input.command_text;
  }

let effective_names command_inputs =
  if
    List.exists
      (fun command_input -> command_input.has_command_name)
      command_inputs
  then
    Some
      (List.map
         (fun command_input -> command_input.command_name)
         command_inputs)
  else None

let result_concat_map f values =
  let rec loop mapped = function
    | [] -> Ok (List.rev mapped)
    | value :: remaining -> (
        match f value with
        | Error error -> Error error
        | Ok values -> loop (List.rev_append values mapped) remaining)
  in
  loop [] values

let expand ~cwd ~passthrough_arguments ~command_texts ~names =
  let expansion_cwd =
    match cwd with None -> Sys.getcwd () | Some cwd -> cwd
  in
  let script_catalog = script_catalog ~cwd:expansion_cwd in
  let command_inputs =
    command_texts
    |> List.mapi (fun index command_text ->
      let command_input = input command_text in
      match name_at names index with
      | Some command_name ->
          { command_input with command_name; has_command_name = true }
      | None -> command_input)
    |> List.map strip_quotes |> List.map expand_shortcut
  in
  match result_concat_map (expand_wildcard ~script_catalog) command_inputs with
  | Error error -> Error error
  | Ok command_inputs -> (
      match passthrough_arguments with
      | None -> Ok command_inputs
      | Some additional_arguments ->
          Ok (List.map (expand_arguments ~additional_arguments) command_inputs))
