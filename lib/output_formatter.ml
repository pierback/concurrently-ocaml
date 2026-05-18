type color_mode =
  | Always
  | Never

type prefix_mode =
  | Prefix_default
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
  ; group : bool
  ; raw : bool
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
  ]

type buffered_chunk =
  { process_id : string option
  ; stream : Output_event.stream
  ; wall_time : float
  ; chunk : string
  }

type output_buffer =
  { mutable chunks : buffered_chunk list }

type pending_status_message =
  { command_index : int
  ; output : output
  }

type timing_summary_entry =
  { command_index : int
  ; name : string
  ; duration_ms : int
  ; exit_code : string
  ; killed : bool
  ; command_text : string
  }

type t =
  { now : unit -> float
  ; wall_now : unit -> float
  ; options : options
  ; commands : Command.t array
  ; labels : string array
  ; prefix_mode : prefix_mode
  ; prefix_width : int option
  ; started_at_by_command : (int, float) Hashtbl.t
  ; wall_started_at_by_command : (int, float) Hashtbl.t
  ; elapsed_by_command : (int, float) Hashtbl.t
  ; timing_summary_entries : timing_summary_entry list ref
  ; output_buffers : (int, output_buffer) Hashtbl.t
  ; pending_status_messages : pending_status_message list ref
  ; group_stopped : bool array
  ; retry_pending : bool array
  ; restart_message_pending : bool array
  ; mutable next_group_command_index : int
  }

let default_labels command_count =
  if command_count < 0 then Error `Non_positive_command_count
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

let prefix_mode ~labels:_ = function
  | None -> Prefix_default
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

let default_label command =
  match Command.name command with
  | Some name when not (String.equal name "") -> name
  | Some _ | None -> index_label command

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
  | Prefix_default -> default_label command
  | Prefix_index -> index_label command
  | Prefix_pid -> Option.value ~default:"" process_id
  | Prefix_name -> name_label command
  | Prefix_command ->
    truncate_command ~prefix_length:options.prefix_length (Command.text command)
  | Prefix_none -> ""
  | Prefix_time -> format_timestamp options.timestamp_format (now ())
  | Prefix_template template ->
    template_label ~now ~options ~process_id command template

let default_label_for_width ~labels command =
  match Command.name command with
  | Some name when not (String.equal name "") -> name
  | Some _ | None ->
    let index = Command.index command in
    (match List.nth_opt labels index with
     | Some label when not (String.equal label "") -> label
     | Some _ | None -> index_label command)

let raw_label_for_width ~now ~options ~prefix_mode ~labels command =
  match prefix_mode with
  | Prefix_default -> default_label_for_width ~labels command
  | Prefix_index
  | Prefix_pid
  | Prefix_name
  | Prefix_command
  | Prefix_none
  | Prefix_time
  | Prefix_template _ ->
    raw_label ~now ~options ~process_id:None ~prefix_mode command

let label_width ~wall_now ~options ~prefix_mode ~labels commands =
  match prefix_mode, options.pad_prefix with
  | Prefix_none, _ | Prefix_pid, _ | Prefix_template _, _ | _, false -> None
  | _ ->
    commands
    |> List.map
         (raw_label_for_width ~now:wall_now ~options ~prefix_mode ~labels)
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

let hex_nibble_byte value offset =
  match hex_digit value.[offset] with
  | Some nibble -> Some ((nibble * 16) + nibble)
  | None -> None

let hex_color_codes value =
  match String.length value with
  | 4 when value.[0] = '#' ->
    (match
       hex_nibble_byte value 1, hex_nibble_byte value 2, hex_nibble_byte value 3
     with
     | Some red, Some green, Some blue -> Some [ 38; 2; red; green; blue ]
     | _ -> None)
  | 7 when value.[0] = '#' ->
    (match hex_byte value 1, hex_byte value 3, hex_byte value 5 with
     | Some red, Some green, Some blue -> Some [ 38; 2; red; green; blue ]
     | _ -> None)
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
  | "bgblackbright" | "bggray" | "bggrey" -> Some [ 100 ]
  | "bgredbright" -> Some [ 101 ]
  | "bggreenbright" -> Some [ 102 ]
  | "bgyellowbright" -> Some [ 103 ]
  | "bgbluebright" -> Some [ 104 ]
  | "bgmagentabright" -> Some [ 105 ]
  | "bgcyanbright" -> Some [ 106 ]
  | "bgwhitebright" -> Some [ 107 ]
  | _ -> None

let bright_foreground_color_code = function
  | "blackbright" -> Some [ 90 ]
  | "redbright" -> Some [ 91 ]
  | "greenbright" -> Some [ 92 ]
  | "yellowbright" -> Some [ 93 ]
  | "bluebright" -> Some [ 94 ]
  | "magentabright" -> Some [ 95 ]
  | "cyanbright" -> Some [ 96 ]
  | "whitebright" -> Some [ 97 ]
  | _ -> None

type ansi_style =
  { open_codes : int list
  ; close_codes : int list
  }

let modifier_style = function
  | "bold" -> Some { open_codes = [ 1 ]; close_codes = [ 22 ] }
  | "dim" -> Some { open_codes = [ 2 ]; close_codes = [ 22 ] }
  | "italic" -> Some { open_codes = [ 3 ]; close_codes = [ 23 ] }
  | "underline" -> Some { open_codes = [ 4 ]; close_codes = [ 24 ] }
  | "inverse" -> Some { open_codes = [ 7 ]; close_codes = [ 27 ] }
  | "hidden" -> Some { open_codes = [ 8 ]; close_codes = [ 28 ] }
  | "strikethrough" -> Some { open_codes = [ 9 ]; close_codes = [ 29 ] }
  | _ -> None

let auto_color_code command_index =
  let palette = [| 36; 33; 92; 94; 95; 37; 90; 31 |] in
  [ palette.(command_index mod Array.length palette) ]

let foreground_style codes = { open_codes = codes; close_codes = [ 39 ] }
let background_style codes = { open_codes = codes; close_codes = [ 49 ] }
let reset_style = { open_codes = [ 0 ]; close_codes = [ 0 ] }

let prefix_color_part_codes ~command_index part =
  let part = lowercase_trim part in
  if part = "" || part = "reset" then Ok [ reset_style ]
  else if part = "auto" then
    Ok [ foreground_style (auto_color_code command_index) ]
  else
    match foreground_color_code part with
    | Some codes -> Ok [ foreground_style codes ]
    | None ->
      (match bright_foreground_color_code part with
       | Some codes -> Ok [ foreground_style codes ]
       | None ->
         (match background_color_code part with
          | Some codes -> Ok [ background_style codes ]
          | None ->
            (match modifier_style part with
             | Some style -> Ok [ style ]
             | None ->
               match hex_color_codes part with
               | Some codes -> Ok [ foreground_style codes ]
               | None -> Error part)))

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

let create ~now ~wall_now ~commands (options : options) =
  let command_count = List.length commands in
  if options.prefix_length < 0 then Error `Negative_prefix_length
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
      let prefix_mode = prefix_mode ~labels:options.labels options.prefix in
      Ok
        { now
        ; wall_now
        ; options
        ; commands = Array.of_list commands
        ; labels = Array.of_list labels
        ; prefix_mode
        ; prefix_width =
            label_width ~wall_now ~options ~prefix_mode ~labels commands
        ; started_at_by_command = Hashtbl.create command_count
        ; wall_started_at_by_command = Hashtbl.create command_count
        ; elapsed_by_command = Hashtbl.create command_count
        ; timing_summary_entries = ref []
        ; output_buffers = Hashtbl.create command_count
        ; pending_status_messages = ref []
        ; group_stopped = Array.make command_count false
        ; retry_pending = Array.make command_count false
        ; restart_message_pending = Array.make command_count false
        ; next_group_command_index = 0
        }

let colorize t styles format =
  match t.options.color_mode with
  | Never -> Printf.sprintf format
  | Always -> ANSITerminal.sprintf styles format

let duration_ms elapsed_time =
  int_of_float (floor ((elapsed_time *. 1000.0) +. 0.5))

let format_integer_with_separators value =
  let digits = string_of_int value in
  let length = String.length digits in
  let buffer = Buffer.create (length + (length / 3)) in
  String.iteri
    (fun index digit ->
      if index > 0 && (length - index) mod 3 = 0 then Buffer.add_char buffer ',';
      Buffer.add_char buffer digit)
    digits;
  Buffer.contents buffer

let label_for_command t ~wall_time ~process_id command =
  let label =
    match t.prefix_mode with
    | Prefix_default ->
      (match Command.name command with
       | Some name when not (String.equal name "") -> name
       | Some _ | None ->
         let index = Command.index command in
         if index < Array.length t.labels && not (String.equal t.labels.(index) "")
         then t.labels.(index)
         else index_label command)
    | Prefix_index
    | Prefix_pid
    | Prefix_command
    | Prefix_none
    | Prefix_time
    | Prefix_template _ ->
      raw_label
        ~now:(fun () -> wall_time)
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

let template_mentions template pattern =
  let pattern_length = String.length pattern in
  let last_start = String.length template - pattern_length in
  let rec loop index =
    index <= last_start
    && (String.sub template index pattern_length = pattern || loop (index + 1))
  in
  loop 0

let template_mentions_process_id template =
  template_mentions template "{pid}"

let template_mentions_time template =
  template_mentions template "{time}"

let prefix_mentions_time t =
  match t.prefix_mode with
  | Prefix_time -> true
  | Prefix_template template -> template_mentions_time template
  | Prefix_default
  | Prefix_index
  | Prefix_pid
  | Prefix_name
  | Prefix_command
  | Prefix_none ->
    false

let displayed_process_id t process_id =
  match t.prefix_mode with
  | Prefix_pid -> process_id
  | Prefix_template template when template_mentions_process_id template -> process_id
  | Prefix_default
  | Prefix_index
  | Prefix_name
  | Prefix_command
  | Prefix_none
  | Prefix_time
  | Prefix_template _ ->
    None

let block_format t = t.options.spacious

let grouped_waiting_for_prior_command t command_index =
  t.options.group
  && (block_format t || command_index > t.next_group_command_index)

let buffered_format t command_index =
  block_format t || grouped_waiting_for_prior_command t command_index

let output_buffer t command_index =
  match Hashtbl.find_opt t.output_buffers command_index with
  | Some buffer -> buffer
  | None ->
    let buffer = { chunks = [] } in
    Hashtbl.add t.output_buffers command_index buffer;
    buffer

let elapsed_time t command_index =
  match Hashtbl.find_opt t.elapsed_by_command command_index with
  | Some elapsed -> elapsed
  | None ->
    (match Hashtbl.find_opt t.started_at_by_command command_index with
     | Some started_at -> t.now () -. started_at
     | None -> 0.0)

let record_elapsed_time t command_index =
  let elapsed =
    match Hashtbl.find_opt t.started_at_by_command command_index with
    | Some started_at -> t.now () -. started_at
    | None -> 0.0
  in
  Hashtbl.replace t.elapsed_by_command command_index elapsed

let ansi_code_text codes =
  codes |> List.map string_of_int |> String.concat ";"

let ansi_sequence codes = "\027[" ^ ansi_code_text codes ^ "m"

let ansi_colorize t styles text =
  match t.options.color_mode, styles with
  | Never, _ | _, [] -> text
  | Always, _ ->
    let opens =
      styles |> List.map (fun style -> ansi_sequence style.open_codes)
      |> String.concat ""
    in
    let closes =
      styles |> List.rev
      |> List.map (fun style -> ansi_sequence style.close_codes)
      |> String.concat ""
    in
    opens ^ text ^ closes

let reset_colorize t text = ansi_colorize t [ reset_style ] text

let prefix_label t command stream tag =
  let plain_label =
    match t.prefix_mode with
    | Prefix_template _ -> tag
    | Prefix_default
    | Prefix_index
    | Prefix_pid
    | Prefix_name
    | Prefix_command
    | Prefix_none
    | Prefix_time ->
      Printf.sprintf "[%s]" tag
  in
  match Command.prefix_color command with
  | Some prefix_color ->
    let command_index = Command.index command in
    (match prefix_color_codes ~command_index prefix_color with
     | Ok codes -> ansi_colorize t codes plain_label
     | Error _ -> reset_colorize t plain_label)
  | None -> reset_colorize t plain_label

let format_lines t ~wall_time ~command ~process_id ~stream ~chunks =
  match chunks with
  | [] -> None
  | first_line :: rest_lines ->
    let tag = label_for_command t ~wall_time ~process_id command in
    let prefix_label =
      match t.prefix_mode with
      | Prefix_none -> ""
      | _ -> prefix_label t command stream tag
    in
    let prefix = if prefix_label = "" then "" else prefix_label ^ " " in
    let first_formatted_line =
      match t.prefix_mode with
      | Prefix_none ->
        if t.options.spacious || rest_lines <> [] then
          Printf.sprintf "\n%s" first_line
        else first_line
      | _ ->
        if t.options.spacious || rest_lines <> [] then
          Printf.sprintf "\n%s:\n%s%s" prefix_label prefix first_line
        else Printf.sprintf "%s%s" prefix first_line
    in
    let rest_formatted_lines =
      if t.prefix_mode = Prefix_none then rest_lines
      else if t.options.spacious || rest_lines <> [] then
        List.map (fun line -> Printf.sprintf "%s%s" prefix line) rest_lines
      else rest_lines
    in
    let newline = if rest_formatted_lines = [] then "" else "\n" in
    Some (first_formatted_line ^ newline ^ String.concat "\n" rest_formatted_lines)

let formatted_output t ~wall_time ~command ~process_id ~stream ~chunks =
  if Command.raw command then
    List.map
      (fun chunk -> { stream; text = chunk; trailing_newline = false })
      chunks
  else if block_format t then
    match format_lines t ~wall_time ~command ~process_id ~stream ~chunks with
    | None -> []
    | Some text -> [ { stream; text; trailing_newline = true } ]
  else
    chunks
    |> List.filter_map (fun chunk ->
      match
        format_lines t ~wall_time ~command ~process_id ~stream ~chunks:[ chunk ]
      with
      | None -> None
      | Some text -> Some { stream; text; trailing_newline = true })

let formatted_buffered_output t ~command chunks =
  let flush_current current chunks outputs =
    match current, chunks with
    | None, _ | _, [] -> outputs
    | Some (process_id, stream), _ ->
      let chunks = List.rev chunks in
      let format_chunk outputs chunk =
        formatted_output
          t
          ~wall_time:chunk.wall_time
          ~command
          ~process_id
          ~stream
          ~chunks:[ chunk.chunk ]
        |> fun formatted -> List.rev_append formatted outputs
      in
      if prefix_mentions_time t && not (block_format t) then
        List.fold_left format_chunk outputs chunks
      else
        let wall_time =
          match chunks with
          | [] -> t.wall_now ()
          | first :: _ -> first.wall_time
        in
        let formatted =
          formatted_output
            t
            ~wall_time
            ~command
            ~process_id
            ~stream
            ~chunks:(List.map (fun chunk -> chunk.chunk) chunks)
        in
        List.rev_append formatted outputs
  in
  let rec loop current current_chunks outputs = function
    | [] -> flush_current current current_chunks outputs |> List.rev
    | ({ process_id; stream; _ } as chunk) :: rest ->
      let key = displayed_process_id t process_id, stream in
      (match current with
       | Some current when current = key ->
         loop (Some current) (chunk :: current_chunks) outputs rest
       | Some _ ->
         let outputs = flush_current current current_chunks outputs in
         loop (Some key) [ chunk ] outputs rest
       | None -> loop (Some key) [ chunk ] outputs rest)
  in
  loop None [] [] chunks

let signal_label = function
  | signal when signal = string_of_int Sys.sighup -> "SIGHUP"
  | signal when signal = string_of_int Sys.sigint -> "SIGINT"
  | signal when signal = string_of_int Sys.sigkill -> "SIGKILL"
  | signal when signal = string_of_int Sys.sigterm -> "SIGTERM"
  | signal when signal = string_of_int Sys.sigusr1 -> "SIGUSR1"
  | signal when signal = string_of_int Sys.sigusr2 -> "SIGUSR2"
  | "1" -> "SIGHUP"
  | "2" -> "SIGINT"
  | "9" -> "SIGKILL"
  | "15" -> "SIGTERM"
  | "30" -> "SIGUSR1"
  | "31" -> "SIGUSR2"
  | signal ->
    let signal = String.uppercase_ascii signal in
    if String.length signal >= 3 && String.sub signal 0 3 = "SIG" then signal
    else signal

let close_status_label = function
  | Close_event.Exited code -> string_of_int code
  | Close_event.Signaled signal -> signal_label signal
  | Close_event.Spawn_error message -> message

let close_message command status =
  Printf.sprintf
    "%s exited with code %s"
    (Command.text command)
    (close_status_label status)

let timing_started_message t command command_index =
  let wall_started_at =
    match Hashtbl.find_opt t.wall_started_at_by_command command_index with
    | Some wall_started_at -> wall_started_at
    | None -> t.wall_now ()
  in
  Printf.sprintf
    "%s started at %s"
    (Command.text command)
    (format_timestamp t.options.timestamp_format wall_started_at)

let timing_stopped_message t command command_index =
  let elapsed = elapsed_time t command_index in
  Printf.sprintf
    "%s stopped at %s after %sms"
    (Command.text command)
    (format_timestamp t.options.timestamp_format (t.wall_now ()))
    (format_integer_with_separators (duration_ms elapsed))

let timing_summary_entry t command command_index status killed =
  let elapsed = elapsed_time t command_index in
  { command_index
  ; name = name_label command
  ; duration_ms = duration_ms elapsed
  ; exit_code = close_status_label status
  ; killed
  ; command_text = Command.text command
  }

let remember_timing_summary_entry t entry =
  t.timing_summary_entries := entry :: !(t.timing_summary_entries)

let timing_summary_ready t =
  List.length !(t.timing_summary_entries) >= Array.length t.commands

let max_string_width values =
  List.fold_left (fun width value -> max width (String.length value)) 0 values

let pad_right width value =
  let padding = width - String.length value in
  if padding <= 0 then value else value ^ String.make padding ' '

let repeat_text count text =
  let buffer = Buffer.create (count * String.length text) in
  for _index = 1 to count do
    Buffer.add_string buffer text
  done;
  Buffer.contents buffer

let table_border ~left ~middle ~right widths =
  let cells = List.map (fun width -> repeat_text width "─") widths in
  left ^ "─" ^ String.concat ("─" ^ middle ^ "─") cells ^ "─" ^ right

let timing_summary_table_outputs t =
  if (not t.options.timings) || t.options.raw || not (timing_summary_ready t)
  then []
  else
    let entries =
      !(t.timing_summary_entries)
      |> List.rev
      |> List.sort (fun left right ->
        let by_duration = compare right.duration_ms left.duration_ms in
        if by_duration <> 0 then by_duration
        else compare left.command_index right.command_index)
    in
    let rows =
      List.map
        (fun entry ->
          [ entry.name
          ; string_of_int entry.duration_ms
          ; entry.exit_code
          ; string_of_bool entry.killed
          ; entry.command_text
          ])
        entries
    in
    let headers = [ "name"; "duration"; "exit code"; "killed"; "command" ] in
    let column index =
      List.map (fun row -> List.nth row index) rows
    in
    let widths =
      List.mapi
        (fun index header -> max_string_width (header :: column index))
        headers
    in
    let format_row cells =
      "│ "
      ^ String.concat
          " │ "
          (List.map2 (fun width cell -> pad_right width cell) widths cells)
      ^ " │"
    in
    let lines =
      [ "Timings:"
      ; table_border ~left:"┌" ~middle:"┬" ~right:"┐" widths
      ; format_row headers
      ; table_border ~left:"├" ~middle:"┼" ~right:"┤" widths
      ]
      @ List.map format_row rows
      @ [ table_border ~left:"└" ~middle:"┴" ~right:"┘" widths ]
    in
    List.map
      (fun line ->
        { stream = Output_event.Stdout
        ; text = "--> " ^ line
        ; trailing_newline = true
        })
      lines

let flush_command_output t command =
  let command_index = Command.index command in
  match Hashtbl.find_opt t.output_buffers command_index with
  | None -> []
  | Some buffer ->
    Hashtbl.remove t.output_buffers command_index;
    formatted_buffered_output
      t
      ~command
      (List.rev buffer.chunks)

let flush_status_messages_after_command t command_index =
  let matching, remaining =
    List.partition
      (fun (pending : pending_status_message) ->
        pending.command_index = command_index)
      !(t.pending_status_messages)
  in
  t.pending_status_messages := remaining;
  matching |> List.rev |> List.map (fun pending -> pending.output)

let flush_grouped_output t =
  let rec flush_ready outputs =
    if t.next_group_command_index >= Array.length t.commands then List.rev outputs
    else if not t.group_stopped.(t.next_group_command_index) then (
      let outputs =
        if block_format t then outputs
        else
          let command = t.commands.(t.next_group_command_index) in
          List.rev_append (flush_command_output t command) outputs
      in
      List.rev outputs)
    else
      let command = t.commands.(t.next_group_command_index) in
      let command_index = t.next_group_command_index in
      t.next_group_command_index <- t.next_group_command_index + 1;
      let command_outputs =
        flush_command_output t command
        @ flush_status_messages_after_command t command_index
      in
      flush_ready (List.rev_append command_outputs outputs)
  in
  flush_ready []

let handle_output_chunk t event process_id stream chunk =
  match Output_event.command event with
  | None -> []
  | Some command ->
    let command_index = Command.index command in
    let wall_time = t.wall_now () in
    let command_in_range =
      command_index >= 0 && command_index < Array.length t.commands
    in
    if Command.hidden command then []
    else if Command.raw command then
      if
        t.options.group
        && command_in_range
        && command_index > t.next_group_command_index
      then (
        let buffer = output_buffer t command_index in
        buffer.chunks <- { process_id; stream; wall_time; chunk } :: buffer.chunks;
        [])
      else
        flush_command_output t command
        @ formatted_output t ~wall_time ~command ~process_id ~stream ~chunks:[ chunk ]
    else if not command_in_range then
      formatted_output t ~wall_time ~command ~process_id ~stream ~chunks:[ chunk ]
    else if buffered_format t command_index then (
      let buffer = output_buffer t command_index in
      buffer.chunks <- { process_id; stream; wall_time; chunk } :: buffer.chunks;
      [])
    else formatted_output t ~wall_time ~command ~process_id ~stream ~chunks:[ chunk ]

let handle_status_message t ~stream ~chunk ~after_command =
  let output = { stream; text = chunk; trailing_newline = true } in
  match after_command with
  | None -> if t.options.raw then [] else [ output ]
  | Some command ->
    if Command.raw command then []
    else (
      t.pending_status_messages :=
        { command_index = Command.index command; output }
        :: !(t.pending_status_messages);
      [])

let handle_timing_command_event t event message =
  match Output_event.command event with
  | None -> []
  | Some command ->
    if (not t.options.timings) || Command.raw command || Command.hidden command
    then []
    else
      handle_output_chunk
        t
        event
        (Output_event.process_id event)
        Output_event.Stdout
        message

let handle_stopped_status t event status =
  match Output_event.command event with
  | None -> []
  | Some command ->
    if Command.raw command || Command.hidden command then []
    else
      let chunk = close_message command status |> reset_colorize t in
      handle_output_chunk
        t
        event
        (Output_event.process_id event)
        Output_event.Stdout
        chunk

let handle_restart_message t event =
  match Output_event.command event with
  | None -> []
  | Some command ->
    if Command.raw command || Command.hidden command then []
    else
      let chunk = Printf.sprintf "%s restarted" (Command.text command) in
      handle_output_chunk
        t
        event
        (Output_event.process_id event)
        Output_event.Stdout
        chunk

let handle_lifecycle t event lifecycle =
  match Output_event.command event with
  | None -> []
  | Some command ->
    let command_index = Command.index command in
    let command_in_range =
      command_index >= 0 && command_index < Array.length t.group_stopped
    in
    match lifecycle with
    | Output_event.Started ->
      if command_in_range then (
        Hashtbl.replace t.started_at_by_command command_index (t.now ());
        Hashtbl.replace
          t.wall_started_at_by_command
          command_index
          (t.wall_now ());
        Hashtbl.remove t.elapsed_by_command command_index);
      if command_in_range then
        handle_timing_command_event
          t
          event
          (timing_started_message t command command_index)
      else []
    | Output_event.Stopped | Output_event.Stopped_with_status _ ->
      if not command_in_range then []
      else (
        record_elapsed_time t command_index;
        let retrying = t.retry_pending.(command_index) in
        let timing_stopped_outputs =
          match lifecycle with
          | Output_event.Stopped_with_status _ ->
            handle_timing_command_event
              t
              event
              (timing_stopped_message t command command_index)
          | Output_event.Stopped
          | Output_event.Started
          | Output_event.Restarting _
          | Output_event.Stopping ->
            []
        in
        (match lifecycle with
         | Output_event.Stopped_with_status { status; killed } ->
           if (not retrying) && t.options.timings then
             remember_timing_summary_entry
               t
               (timing_summary_entry t command command_index status killed)
         | Output_event.Stopped
         | Output_event.Started
         | Output_event.Restarting _
         | Output_event.Stopping ->
           ());
        let stopped_outputs =
          match lifecycle with
          | Output_event.Stopped_with_status { status; killed = _ } ->
            handle_stopped_status t event status
          | Output_event.Stopped
          | Output_event.Started
          | Output_event.Restarting _
          | Output_event.Stopping ->
            []
        in
        let status_outputs =
          if t.options.group then []
          else flush_status_messages_after_command t command_index
        in
        let restart_outputs =
          if t.restart_message_pending.(command_index) then (
            t.restart_message_pending.(command_index) <- false;
            handle_restart_message t event)
          else []
        in
        let lifecycle_outputs =
          timing_stopped_outputs
          @ stopped_outputs
          @ restart_outputs
        in
        let final_outputs =
          if retrying then (
            t.retry_pending.(command_index) <- false;
            if t.options.group then lifecycle_outputs @ status_outputs
            else if buffered_format t command_index then
              flush_command_output t command @ lifecycle_outputs @ status_outputs
            else lifecycle_outputs @ status_outputs)
          else if t.options.group then (
            t.group_stopped.(command_index) <- true;
            lifecycle_outputs @ flush_grouped_output t)
          else if buffered_format t command_index then
            flush_command_output t command @ lifecycle_outputs @ status_outputs
          else lifecycle_outputs @ status_outputs
        in
        final_outputs @ timing_summary_table_outputs t)
    | Output_event.Restarting _ ->
      if command_in_range then (
        t.retry_pending.(command_index) <- true;
        t.restart_message_pending.(command_index) <- true);
      []
    | Output_event.Stopping -> []

let handle_event t event =
  match Output_event.payload event with
  | Output_event.Output_chunk_payload { process_id; stream; chunk } ->
    handle_output_chunk t event process_id stream chunk
  | Output_event.Lifecycle_payload lifecycle -> handle_lifecycle t event lifecycle
  | Output_event.Status_message_payload { stream; chunk; after_command } ->
    handle_status_message t ~stream ~chunk ~after_command

let error_message = function
  | `Label_count_mismatch (label_count, command_count) ->
    Printf.sprintf
      "number of labels (%d) must match number of commands (%d)"
      label_count
      command_count
  | `Negative_prefix_length -> "prefix length must not be negative"
  | `Non_positive_command_count -> "command count must be positive"
