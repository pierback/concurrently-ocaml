let first_env_value env names =
  let rec loop = function
    | [] -> None
    | name :: rest -> (
        match env name with Some value -> Some value | None -> loop rest)
  in
  loop names

let env_flag_enabled value = String.trim value = "true"

let env_argument (env_option : Cli_options.env_option) value =
  match env_option.kind with
  | Cli_options.Env_flag ->
      if env_flag_enabled value then Some env_option.emitted_option else None
  | Cli_options.Env_value -> Some (env_option.emitted_option ^ "=" ^ value)

let env_arguments ~env ~option_was_provided =
  Cli_options.env_options
  |> List.filter_map (fun (env_option : Cli_options.env_option) ->
      if option_was_provided env_option.option_names then None
      else
        match first_env_value env env_option.env_names with
        | None -> None
        | Some value -> env_argument env_option value)

let add_arguments ~env ~option_was_provided argv =
  let env_args = env_arguments ~env ~option_was_provided in
  match (env_args, Array.length argv) with
  | [], _ -> argv
  | _, 0 -> Array.of_list env_args
  | _, length ->
      Array.concat
        [
          Array.sub argv 0 1;
          Array.of_list env_args;
          Array.sub argv 1 (length - 1);
        ]
