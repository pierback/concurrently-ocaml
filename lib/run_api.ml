type command_input = {
  text : string;
  name : string option;
  cwd : string option;
  env : (string * string) list;
  prefix_color : string option;
  raw : bool option;
  hidden : bool;
  ipc : bool;
}

type t = {
  spec : Run_spec.t;
  input : Input_router.t option;
  formatter_options : Output_formatter.options;
}

type create_error =
  [ `Command_error of int * Command.create_error
  | `Input_router_error of Input_router.create_error
  | `Run_spec_error of Run_spec.create_error ]

let command ?name ?cwd ?(env = []) ?prefix_color ?raw ?(hidden = false)
    ?(ipc = false) text =
  { text; name; cwd; env; prefix_color; raw; hidden; ipc }

let command_cwd ~cwd input =
  match input.cwd with Some _ as cwd -> cwd | None -> cwd

let command_raw ~global_raw input =
  match input.raw with Some raw -> raw | None -> global_raw

let create_command ~cwd ~global_raw index input =
  match
    Command.create ?name:input.name ?cwd:(command_cwd ~cwd input) ~env:input.env
      ?prefix_color:input.prefix_color
      ~raw:(command_raw ~global_raw input)
      ~hidden:input.hidden ~ipc:input.ipc ~index input.text
  with
  | Ok command -> Ok command
  | Error error -> Error (`Command_error (index, error))

let create_commands ~cwd ~global_raw inputs =
  let rec loop index commands = function
    | [] -> Ok (List.rev commands)
    | input :: rest -> (
        match create_command ~cwd ~global_raw index input with
        | Ok command -> loop (index + 1) (command :: commands) rest
        | Error _ as error -> error)
  in
  loop 0 [] inputs

let create_input_router ~handle_input ~commands ~default_input_target =
  if not handle_input then Ok None
  else
    match Input_router.create ~commands ~default_input_target with
    | Ok router -> Ok (Some router)
    | Error error -> Error (`Input_router_error error)

let create ?cwd ?(policy = Run_policy.default) ?labels ?prefix
    ?(prefix_length = 10.0) ?(pad_prefix = false)
    ?(timestamp_format = "yyyy-MM-dd HH:mm:ss.SSS") ?(spacious = false)
    ?(timings = false) ?(group = false) ?(raw = false)
    ?(color_mode = Output_formatter.Always) ?(handle_input = false)
    ?(default_input_target = "0") inputs =
  match create_commands ~cwd ~global_raw:raw inputs with
  | Error _ as error -> error
  | Ok commands -> (
      match
        create_input_router ~handle_input ~commands ~default_input_target
      with
      | Error _ as error -> error
      | Ok input -> (
          match Run_spec.create ~commands ~policy with
          | Error error -> Error (`Run_spec_error error)
          | Ok spec ->
              Ok
                {
                  spec;
                  input;
                  formatter_options =
                    {
                      labels;
                      prefix;
                      prefix_length;
                      pad_prefix;
                      timestamp_format;
                      spacious;
                      timings;
                      group;
                      raw;
                      color_mode;
                    };
                }))

let run t ~input_source ~backend ~now ~sleep ~on_output_event =
  Runner.run ~input:t.input ~input_source ~backend ~now ~sleep ~spec:t.spec
    ~on_output_event

let spec t = t.spec
let commands t = Run_spec.commands t.spec
let policy t = Run_spec.policy t.spec
let input t = t.input
let formatter_options t = t.formatter_options

let command_error_message = function
  | `Empty_command -> "command text must not be empty"
  | `Empty_cwd -> "command cwd must not be empty"
  | `Negative_index -> "command index must not be negative"

let run_spec_error_message = function
  | `Close_event_capacity_overflow -> "close event capacity overflow"
  | `Command_index_mismatch (expected, actual) ->
      Printf.sprintf "command index mismatch: expected %d but got %d" expected
        actual
  | `Empty_command_list -> "at least one command is required"

let error_message = function
  | `Command_error (index, error) ->
      Printf.sprintf "command %d is invalid: %s" index
        (command_error_message error)
  | `Input_router_error error -> Input_router.error_message error
  | `Run_spec_error error -> run_spec_error_message error
