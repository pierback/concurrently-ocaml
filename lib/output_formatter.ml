type color_mode =
  | Always
  | Never

type prefix_mode =
  | Prefix_index
  | Prefix_pid
  | Prefix_name
  | Prefix_command
  | Prefix_none
  | Prefix_time
  | Prefix_template of string

type options =
  { labels : string list option
  ; prefix : string option
  ; prefix_length : int
  ; pad_prefix : bool
  ; timestamp_format : string
  ; spacious : bool
  ; timings : bool
  ; color_mode : color_mode
  }

type output =
  { stream : Output_event.stream
  ; text : string
  ; trailing_newline : bool
  }

type create_error =
  [ `Label_count_mismatch of int * int
  | `Negative_prefix_length
  | `Non_positive_command_count
  | `Unsupported_prefix_color of int * string
  ]

type output_buffer =
  { mutable process_id : string option
  ; mutable stdout : string list
  ; mutable stderr : string list
  }

type t =
  { now : unit -> float
  ; wall_now : unit -> float
  ; options : options
  ; labels : string array
  ; prefix_mode : prefix_mode
  ; prefix_width : int option
  ; started_at_by_command : (int, float) Hashtbl.t
  ; output_buffers : (int, output_buffer) Hashtbl.t
  }

let default_labels command_count =
  if command_count <= 0 then Error `Non_positive_command_count
  else
    let rec build index labels =
      if index = command_count then Ok (List.rev labels)
      else build (index + 1) (string_of_int index :: labels)
    in
    build 0 []

let validate_labels ~command_count labels =
  let label_count = List.length labels in
  if label_count = command_count then Ok ()
  else Error (`Label_count_mismatch (label_count, command_count))

let prefix_mode ~labels = function
  | None ->
    (match labels with
     | Some _ -> Prefix_name
     | None -> Prefix_index)
  | Some value ->
    (match String.lowercase_ascii value with
     | "index" -> Prefix_index
     | "pid" -> Prefix_pid
     | "name" -> Prefix_name
     | "command" -> Prefix_command
     | "none" -> Prefix_none
     | "time" -> Prefix_time
     | _ -> Prefix_template value)

let padded_int width value = Printf.sprintf "%0*d" width value

let format_timestamp format timestamp =
  let seconds = floor timestamp in
  let milliseconds =
    int_of_float (floor ((timestamp -. seconds) *. 1000.0))
  in
  let time = Unix.localtime seconds in
  let buffer = Buffer.create (String.length format + 8) in
  let tokens =
    [ "yyyy", padded_int 4 (time.Unix.tm_year + 1900)
    ; "SSS", padded_int 3 milliseconds
    ; "MM", padded_int 2 (time.Unix.tm_mon + 1)
    ; "dd", padded_int 2 time.Unix.tm_mday
    ; "HH", padded_int 2 time.Unix.tm_hour
    ; "mm", padded_int 2 time.Unix.tm_min
    ; "ss", padded_int 2 time.Unix.tm_sec
    ]
  in
  let token_at index (token, replacement) =
    let token_length = String.length token in
    if
      index + token_length <= String.length format
      && String.sub format index token_length = token
    then Some (token_length, replacement)
    else None
  in
  let rec loop index =
    if index = String.length format then Buffer.contents buffer
    else
      match List.find_map (token_at index) tokens with
      | Some (token_length, replacement) ->
        Buffer.add_string buffer replacement;
        loop (index + token_length)
      | None ->
        Buffer.add_char buffer format.[index];
        loop (index + 1)
  in
  loop 0

let truncate_command ~prefix_length text =
  if prefix_length <= 0 || String.length text <= prefix_length then text
  else if prefix_length <= 3 then String.sub text 0 prefix_length
  else
    let side_length = (prefix_length - 2) / 2 in
    let right_length = prefix_length - 2 - side_length in
    String.sub text 0 side_length
    ^ ".."
    ^ String.sub text (String.length text - right_length) right_length

let name_label command =
  match Command.name command with
  | Some name -> name
  | None -> ""

let index_label command = string_of_int (Command.index command)

let template_label ~now ~options ~process_id command template =
  let replacements =
    [ "{index}", index_label command
    ; "{pid}", Option.value ~default:"" process_id
    ; "{name}", name_label command
    ; "{command}", Command.text command
    ; "{time}", format_timestamp options.timestamp_format (now ())
    ]
  in
  let template_length = String.length template in
  let buffer = Buffer.create template_length in
  let replacement_at index (pattern, replacement) =
    let pattern_length = String.length pattern in
    if
      index + pattern_length <= template_length
      && String.sub template index pattern_length = pattern
    then Some (pattern_length, replacement)
    else None
  in
  let rec loop index =
    if index = template_length then Buffer.contents buffer
    else
      match List.find_map (replacement_at index) replacements with
      | Some (pattern_length, replacement) ->
        Buffer.add_string buffer replacement;
        loop (index + pattern_length)
      | None ->
        Buffer.add_char buffer template.[index];
        loop (index + 1)
  in
  loop 0

let raw_label ~now ~options ~process_id ~prefix_mode command =
  match prefix_mode with
  | Prefix_index -> index_label command
  | Prefix_pid -> Option.value ~default:"" process_id
  | Prefix_name -> name_label command
  | Prefix_command ->
    truncate_command ~prefix_length:options.prefix_length (Command.text command)
  | Prefix_none -> ""
  | Prefix_time -> format_timestamp options.timestamp_format (now ())
  | Prefix_template template ->
    template_label ~now ~options ~process_id command template

let label_width ~wall_now ~options ~prefix_mode commands =
  match prefix_mode, options.pad_prefix with
  | Prefix_none, _ | Prefix_pid, _ | Prefix_template _, _ | _, false -> None
  | _ ->
    commands
    |> List.map (raw_label ~now:wall_now ~options ~process_id:None ~prefix_mode)
    |> List.fold_left (fun width label -> max width (String.length label)) 0
    |> Option.some

let lowercase_trim value = value |> String.trim |> String.lowercase_ascii

let hex_digit = function
  | '0' .. '9' as digit -> Some (Char.code digit - Char.code '0')
  | 'a' .. 'f' as digit -> Some (10 + Char.code digit - Char.code 'a')
  | 'A' .. 'F' as digit -> Some (10 + Char.code digit - Char.code 'A')
  | _ -> None

let hex_byte value offset =
  match hex_digit value.[offset], hex_digit value.[offset + 1] with
  | Some high, Some low -> Some ((high * 16) + low)
  | _ -> None

let foreground_color_code = function
  | "black" -> Some [ 30 ]
  | "red" -> Some [ 31 ]
  | "green" -> Some [ 32 ]
  | "yellow" -> Some [ 33 ]
  | "blue" -> Some [ 34 ]
  | "magenta" -> Some [ 35 ]
  | "cyan" -> Some [ 36 ]
  | "white" -> Some [ 37 ]
  | "gray" | "grey" -> Some [ 90 ]
  | _ -> None

let background_color_code = function
  | "bgblack" -> Some [ 40 ]
  | "bgred" -> Some [ 41 ]
  | "bggreen" -> Some [ 42 ]
  | "bgyellow" -> Some [ 43 ]
  | "bgblue" -> Some [ 44 ]
  | "bgmagenta" -> Some [ 45 ]
  | "bgcyan" -> Some [ 46 ]
  | "bgwhite" -> Some [ 47 ]
  | _ -> None

let modifier_code = function
  | "bold" -> Some [ 1 ]
  | "dim" -> Some [ 2 ]
  | "italic" -> Some [ 3 ]
  | "underline" -> Some [ 4 ]
  | "inverse" -> Some [ 7 ]
  | "hidden" -> Some [ 8 ]
  | "strikethrough" -> Some [ 9 ]
  | _ -> None

let auto_color_code command_index =
  let palette = [| 32; 36; 33; 35; 34; 31 |] in
  [ palette.(command_index mod Array.length palette) ]

let prefix_color_part_codes ~command_index part =
  let part = lowercase_trim part in
  if part = "" || part = "reset" then Ok []
  else if part = "auto" then Ok (auto_color_code command_index)
  else
    match foreground_color_code part with
    | Some codes -> Ok codes
    | None ->
      (match background_color_code part with
       | Some codes -> Ok codes
       | None ->
         (match modifier_code part with
          | Some codes -> Ok codes
          | None ->
            if String.length part = 7 && part.[0] = '#' then
              match hex_byte part 1, hex_byte part 3, hex_byte part 5 with
              | Some red, Some green, Some blue -> Ok [ 38; 2; red; green; blue ]
              | _ -> Error part
            else Error part))

let prefix_color_codes ~command_index prefix_color =
  prefix_color
  |> String.split_on_char '.'
  |> List.fold_left
       (fun result part ->
         match result with
         | Error _ as error -> error
         | Ok codes ->
           (match prefix_color_part_codes ~command_index part with
            | Ok part_codes -> Ok (codes @ part_codes)
            | Error _ as error -> error))
       (Ok [])

let validate_prefix_colors commands =
  let rec validate = function
    | [] -> Ok ()
    | command :: rest ->
      let command_index = Command.index command in
      (match Command.prefix_color command with
       | None -> validate rest
       | Some prefix_color ->
         (match prefix_color_codes ~command_index prefix_color with
          | Ok _ -> validate rest
          | Error unsupported ->
            Error (`Unsupported_prefix_color (command_index, unsupported))))
  in
  validate commands

let create ~now ~wall_now ~commands (options : options) =
  let command_count = List.length commands in
  if command_count <= 0 then Error `Non_positive_command_count
  else if options.prefix_length < 0 then Error `Negative_prefix_length
  else
    let labels_result =
      match options.labels with
      | Some labels ->
        (match validate_labels ~command_count labels with
         | Ok () -> Ok labels
         | Error error -> Error error)
      | None -> default_labels command_count
    in
    match labels_result with
    | Error error -> Error error
    | Ok labels ->
      (match validate_prefix_colors commands with
       | Error error -> Error error
       | Ok () ->
         let prefix_mode = prefix_mode ~labels:options.labels options.prefix in
         Ok
           { now
           ; wall_now
           ; options
           ; labels = Array.of_list labels
           ; prefix_mode
           ; prefix_width = label_width ~wall_now ~options ~prefix_mode commands
           ; started_at_by_command = Hashtbl.create command_count
           ; output_buffers = Hashtbl.create command_count
           })

let colorize t styles format =
  match t.options.color_mode with
  | Never -> Printf.sprintf format
  | Always -> ANSITerminal.sprintf styles format

let format_elapsed elapsed_time =
  if elapsed_time >= 1.0 then
    let seconds = int_of_float elapsed_time in
    let milliseconds =
      int_of_float ((elapsed_time -. float_of_int seconds) *. 1000.0)
    in
    Printf.sprintf "%d,%d sec" seconds milliseconds
  else
    let milliseconds = int_of_float (elapsed_time *. 1000.0) in
    let nanoseconds =
      int_of_float
        ((elapsed_time *. 1000.0 *. 1000.0)
         -. (float_of_int milliseconds *. 1000.0))
    in
    let rounded_nanoseconds = (nanoseconds + 5) / 10 in
    let milliseconds =
      if rounded_nanoseconds >= 100 then milliseconds + 1 else milliseconds
    in
    Printf.sprintf "%d,%02d ms" milliseconds rounded_nanoseconds

let timings_tag t elapsed_time =
  colorize t [ ANSITerminal.Foreground ANSITerminal.Black ] "%s"
    (format_elapsed elapsed_time)

let label_for_command t ~process_id command =
  let label =
    match t.prefix_mode with
    | Prefix_index
    | Prefix_pid
    | Prefix_command
    | Prefix_none
    | Prefix_time
    | Prefix_template _ ->
      raw_label
        ~now:t.wall_now
        ~options:t.options
        ~process_id
        ~prefix_mode:t.prefix_mode
        command
    | Prefix_name ->
      let index = Command.index command in
      if index < Array.length t.labels then t.labels.(index) else name_label command
  in
  match t.prefix_width with
  | None -> label
  | Some width ->
    let padding = width - String.length label in
    if padding <= 0 then label else label ^ String.make padding ' '

let buffered_format t = t.options.spacious || t.options.timings

let output_buffer t command_index =
  match Hashtbl.find_opt t.output_buffers command_index with
  | Some buffer -> buffer
  | None ->
    let buffer = { process_id = None; stdout = []; stderr = [] } in
    Hashtbl.add t.output_buffers command_index buffer;
    buffer

let elapsed_time t command_index =
  match Hashtbl.find_opt t.started_at_by_command command_index with
  | Some started_at -> t.now () -. started_at
  | None -> 0.0

let stream_color = function
  | Output_event.Stdout -> ANSITerminal.Green
  | Output_event.Stderr -> ANSITerminal.Red

let ansi_colorize t codes text =
  match t.options.color_mode, codes with
  | Never, _ | _, [] -> text
  | Always, _ ->
    let code_text = codes |> List.map string_of_int |> String.concat ";" in
    "\027[" ^ code_text ^ "m" ^ text ^ "\027[0m"

let prefix_label t command stream tag =
  let plain_label = Printf.sprintf "[%s]" tag in
  match Command.prefix_color command with
  | Some prefix_color ->
    let command_index = Command.index command in
    (match prefix_color_codes ~command_index prefix_color with
     | Ok codes -> ansi_colorize t codes plain_label
     | Error _ -> assert false)
  | None ->
    colorize
      t
      [ ANSITerminal.Foreground (stream_color stream) ]
      "%s"
      plain_label

let format_lines t ~command ~process_id ~stream ~chunks =
  match chunks with
  | [] -> None
  | first_line :: rest_lines ->
    let tag = label_for_command t ~process_id command in
    let prefix_label =
      match t.prefix_mode with
      | Prefix_none -> ""
      | _ -> prefix_label t command stream tag
    in
    let prefix = if prefix_label = "" then "" else prefix_label ^ " " in
    let elapsed = elapsed_time t (Command.index command) in
    let first_formatted_line =
      match t.prefix_mode with
      | Prefix_none ->
        if t.options.timings then
          Printf.sprintf "\n%s:\n%s" (timings_tag t elapsed) first_line
        else if t.options.spacious || rest_lines <> [] then
          Printf.sprintf "\n%s" first_line
        else first_line
      | _ ->
        if t.options.timings then
          Printf.sprintf
            "\n%s %s:\n%s%s"
            prefix_label
            (timings_tag t elapsed)
            prefix
            first_line
        else if t.options.spacious || rest_lines <> [] then
          Printf.sprintf "\n%s:\n%s%s" prefix_label prefix first_line
        else Printf.sprintf "%s%s" prefix first_line
    in
    let rest_formatted_lines =
      if t.prefix_mode = Prefix_none then rest_lines
      else if t.options.spacious || t.options.timings || rest_lines <> [] then
        List.map (fun line -> Printf.sprintf "%s%s" prefix line) rest_lines
      else rest_lines
    in
    let newline = if rest_formatted_lines = [] then "" else "\n" in
    Some (first_formatted_line ^ newline ^ String.concat "\n" rest_formatted_lines)

let formatted_output t ~command ~process_id ~stream ~chunks =
  match format_lines t ~command ~process_id ~stream ~chunks with
  | None -> []
  | Some text -> [ { stream; text; trailing_newline = true } ]

let flush_command_output t command =
  let command_index = Command.index command in
  match Hashtbl.find_opt t.output_buffers command_index with
  | None -> []
  | Some buffer ->
    Hashtbl.remove t.output_buffers command_index;
    formatted_output
      t
      ~command
      ~process_id:buffer.process_id
      ~stream:Output_event.Stdout
      ~chunks:(List.rev buffer.stdout)
    @ formatted_output
        t
        ~command
        ~process_id:buffer.process_id
        ~stream:Output_event.Stderr
        ~chunks:(List.rev buffer.stderr)

let handle_output_chunk t event process_id stream chunk =
  let command = Output_event.command event in
  let command_index = Command.index command in
  if Command.hidden command then []
  else if Command.raw command then [ { stream; text = chunk; trailing_newline = false } ]
  else if buffered_format t then (
    let buffer = output_buffer t command_index in
    if Option.is_some process_id then buffer.process_id <- process_id;
    (match stream with
     | Output_event.Stdout -> buffer.stdout <- chunk :: buffer.stdout
     | Output_event.Stderr -> buffer.stderr <- chunk :: buffer.stderr);
    [])
  else formatted_output t ~command ~process_id ~stream ~chunks:[ chunk ]

let handle_lifecycle t event lifecycle =
  let command = Output_event.command event in
  let command_index = Command.index command in
  match lifecycle with
  | Output_event.Started ->
    Hashtbl.replace t.started_at_by_command command_index (t.now ());
    []
  | Output_event.Stopped ->
    if buffered_format t then flush_command_output t command else []
  | Output_event.Restarting _ | Output_event.Stopping -> []

let handle_event t event =
  match Output_event.payload event with
  | Output_event.Output_chunk_payload { process_id; stream; chunk } ->
    handle_output_chunk t event process_id stream chunk
  | Output_event.Lifecycle_payload lifecycle -> handle_lifecycle t event lifecycle

let error_message = function
  | `Label_count_mismatch (label_count, command_count) ->
    Printf.sprintf
      "number of labels (%d) must match number of commands (%d)"
      label_count
      command_count
  | `Negative_prefix_length -> "prefix length must not be negative"
  | `Non_positive_command_count -> "command count must be positive"
  | `Unsupported_prefix_color (command_index, prefix_color) ->
    Printf.sprintf
      "command %d prefix color is unsupported: %s"
      command_index
      prefix_color
