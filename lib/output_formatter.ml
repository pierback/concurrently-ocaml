type color_mode =
  | Ansi16
  | Ansi256
  | Truecolor
  | Never

type options = {
  labels : string list option;
  prefix : string option;
  prefix_length : float;
  pad_prefix : bool;
  timestamp_format : string;
  spacious : bool;
  timings : bool;
  group : bool;
  raw : bool;
  color_mode : color_mode;
}

let prefix_options (options : options) =
  {
    Output_prefix.prefix_length = options.prefix_length;
    pad_prefix = options.pad_prefix;
    timestamp_format = options.timestamp_format;
  }

type output = {
  stream : Output_event.stream;
  text : string;
  trailing_newline : bool;
}

type create_error =
  [ `Label_count_mismatch of int * int | `Non_positive_command_count ]

type pending_status_message = { command_index : int; output : output }

type t = {
  now : unit -> float;
  wall_now : unit -> float;
  options : options;
  commands : Command.t array;
  labels : string array;
  prefix_mode : Output_prefix.mode;
  prefix_width : int option;
  started_at_by_command : (int, float) Hashtbl.t;
  wall_started_at_by_command : (int, float) Hashtbl.t;
  elapsed_by_command : (int, float) Hashtbl.t;
  timing_summary_entries : Output_timing.entry list ref;
  output_buffers : Output_buffer.t;
  pending_status_messages : pending_status_message list ref;
  group_stopped : bool array;
  retry_pending : bool array;
  restart_message_pending : bool array;
  mutable next_group_command_index : int;
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

let create ~now ~wall_now ~commands (options : options) =
  let command_count = List.length commands in
  let labels_result =
    match options.labels with
    | Some labels -> (
        match validate_labels ~command_count labels with
        | Ok () -> Ok labels
        | Error error -> Error error)
    | None -> default_labels command_count
  in
  match labels_result with
  | Error error -> Error error
  | Ok labels ->
      let prefix_mode = Output_prefix.mode options.prefix in
      let prefix_options = prefix_options options in
      Ok
        {
          now;
          wall_now;
          options;
          commands = Array.of_list commands;
          labels = Array.of_list labels;
          prefix_mode;
          prefix_width =
            Output_prefix.label_width ~wall_now ~options:prefix_options
              ~mode:prefix_mode ~labels commands;
          started_at_by_command = Hashtbl.create command_count;
          wall_started_at_by_command = Hashtbl.create command_count;
          elapsed_by_command = Hashtbl.create command_count;
          timing_summary_entries = ref [];
          output_buffers = Output_buffer.create command_count;
          pending_status_messages = ref [];
          group_stopped = Array.make command_count false;
          retry_pending = Array.make command_count false;
          restart_message_pending = Array.make command_count false;
          next_group_command_index = 0;
        }

let label_for_command t ~wall_time ~process_id command =
  Output_prefix.label_for_command ~wall_time ~process_id
    ~options:(prefix_options t.options) ~mode:t.prefix_mode ~labels:t.labels
    ~width:t.prefix_width command

let prefix_mentions_time t = Output_prefix.mentions_time t.prefix_mode

let displayed_process_id t process_id =
  Output_prefix.displayed_process_id t.prefix_mode process_id

let block_format t = t.options.spacious

let grouped_waiting_for_prior_command t command_index =
  t.options.group
  && (block_format t || command_index > t.next_group_command_index)

let buffered_format t command_index =
  block_format t || grouped_waiting_for_prior_command t command_index

let elapsed_time t command_index =
  match Hashtbl.find_opt t.elapsed_by_command command_index with
  | Some elapsed -> elapsed
  | None -> (
      match Hashtbl.find_opt t.started_at_by_command command_index with
      | Some started_at -> t.now () -. started_at
      | None -> 0.0)

let record_elapsed_time t command_index =
  let elapsed =
    match Hashtbl.find_opt t.started_at_by_command command_index with
    | Some started_at -> t.now () -. started_at
    | None -> 0.0
  in
  Hashtbl.replace t.elapsed_by_command command_index elapsed

let ansi_code_text codes = codes |> List.map string_of_int |> String.concat ";"
let ansi_sequence codes = "\027[" ^ ansi_code_text codes ^ "m"

let ansi_colorize t (styles : Output_color.style list) text =
  match (t.options.color_mode, styles) with
  | Never, _ | _, [] -> text
  | Ansi16, _ | Ansi256, _ | Truecolor, _ ->
      let opens =
        styles
        |> List.map (fun style -> ansi_sequence style.Output_color.open_codes)
        |> String.concat ""
      in
      let closes =
        styles |> List.rev
        |> List.map (fun style -> ansi_sequence style.Output_color.close_codes)
        |> String.concat ""
      in
      opens ^ text ^ closes

let reset_colorize t text = ansi_colorize t [ Output_color.reset_style ] text

let color_level = function
  | Ansi16 -> 1
  | Ansi256 -> 2
  | Truecolor -> 3
  | Never -> 0

let prefix_label t command tag =
  let plain_label =
    if Output_prefix.brackets_label t.prefix_mode then Printf.sprintf "[%s]" tag
    else tag
  in
  match (t.options.color_mode, Command.prefix_color command) with
  | Never, _ -> plain_label
  | _, Some prefix_color -> (
      let command_index = Command.index command in
      match
        Output_color.prefix_styles
          ~color_level:(color_level t.options.color_mode)
          ~command_index prefix_color
      with
      | Ok styles -> ansi_colorize t styles plain_label
      | Error _ -> reset_colorize t plain_label)
  | _, None -> reset_colorize t plain_label

let format_lines t ~wall_time ~command ~process_id ~chunks =
  match chunks with
  | [] -> None
  | first_line :: rest_lines ->
      let tag = label_for_command t ~wall_time ~process_id command in
      let prefix_label =
        match t.prefix_mode with
        | Output_prefix.No_prefix -> ""
        | _ -> prefix_label t command tag
      in
      let prefix = if prefix_label = "" then "" else prefix_label ^ " " in
      let first_formatted_line =
        match t.prefix_mode with
        | Output_prefix.No_prefix ->
            if t.options.spacious || rest_lines <> [] then
              Printf.sprintf "\n%s" first_line
            else first_line
        | _ ->
            if t.options.spacious || rest_lines <> [] then
              Printf.sprintf "\n%s:\n%s%s" prefix_label prefix first_line
            else Printf.sprintf "%s%s" prefix first_line
      in
      let rest_formatted_lines =
        if t.prefix_mode = Output_prefix.No_prefix then rest_lines
        else if t.options.spacious || rest_lines <> [] then
          List.map (fun line -> Printf.sprintf "%s%s" prefix line) rest_lines
        else rest_lines
      in
      let newline = if rest_formatted_lines = [] then "" else "\n" in
      Some
        (first_formatted_line ^ newline
        ^ String.concat "\n" rest_formatted_lines)

let formatted_output t ~wall_time ~command ~process_id ~stream ~chunks =
  if Command.raw command then
    List.map
      (fun chunk -> { stream; text = chunk; trailing_newline = false })
      chunks
  else
    let stream = Output_event.Stdout in
    if block_format t then
      match format_lines t ~wall_time ~command ~process_id ~chunks with
      | None -> []
      | Some text -> [ { stream; text; trailing_newline = true } ]
    else
      chunks
      |> List.filter_map (fun chunk ->
          match
            format_lines t ~wall_time ~command ~process_id ~chunks:[ chunk ]
          with
          | None -> None
          | Some text -> Some { stream; text; trailing_newline = true })

let formatted_buffered_output t ~command runs =
  runs
  |> List.concat_map (fun run ->
      formatted_output t ~wall_time:run.Output_buffer.wall_time ~command
        ~process_id:run.process_id ~stream:run.stream ~chunks:run.chunks)

let close_message command status =
  Printf.sprintf "%s exited with code %s" (Command.text command)
    (Process_signal.exit_status_label status)

let timing_started_message t command command_index =
  let wall_started_at =
    match Hashtbl.find_opt t.wall_started_at_by_command command_index with
    | Some wall_started_at -> wall_started_at
    | None -> t.wall_now ()
  in
  Printf.sprintf "%s started at %s" (Command.text command)
    (Output_prefix.format_timestamp t.options.timestamp_format wall_started_at)

let timing_stopped_message t command command_index =
  let elapsed = elapsed_time t command_index in
  Printf.sprintf "%s stopped at %s after %sms" (Command.text command)
    (Output_prefix.format_timestamp t.options.timestamp_format (t.wall_now ()))
    (Output_timing.format_integer_with_separators
       (Output_timing.duration_ms elapsed))

let timing_summary_entry t command command_index status killed =
  let elapsed = elapsed_time t command_index in
  {
    Output_timing.command_index;
    name = Output_prefix.name_label command;
    duration_ms = Output_timing.duration_ms elapsed;
    exit_code = Process_signal.exit_status_label status;
    killed;
    command_text = Command.text command;
  }

let remember_timing_summary_entry t entry =
  t.timing_summary_entries := entry :: !(t.timing_summary_entries)

let timing_summary_table_outputs t =
  if (not t.options.timings) || t.options.raw then []
  else
    Output_timing.summary_lines ~command_count:(Array.length t.commands)
      !(t.timing_summary_entries)
    |> List.map (fun line ->
        {
          stream = Output_event.Stdout;
          text = "--> " ^ line;
          trailing_newline = true;
        })

let flush_command_output t command =
  let command_index = Command.index command in
  Output_buffer.drain_runs t.output_buffers ~command_index
    ~displayed_process_id:(displayed_process_id t)
    ~split_chunks:(prefix_mentions_time t && not (block_format t))
  |> formatted_buffered_output t ~command

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
    if t.next_group_command_index >= Array.length t.commands then
      List.rev outputs
    else if not t.group_stopped.(t.next_group_command_index) then
      let outputs =
        if block_format t then outputs
        else
          let command = t.commands.(t.next_group_command_index) in
          List.rev_append (flush_command_output t command) outputs
      in
      List.rev outputs
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
          t.options.group && command_in_range
          && command_index > t.next_group_command_index
        then (
          Output_buffer.append t.output_buffers ~command_index
            { process_id; stream; wall_time; text = chunk };
          [])
        else
          flush_command_output t command
          @ formatted_output t ~wall_time ~command ~process_id ~stream
              ~chunks:[ chunk ]
      else if not command_in_range then
        formatted_output t ~wall_time ~command ~process_id ~stream
          ~chunks:[ chunk ]
      else if buffered_format t command_index then (
        Output_buffer.append t.output_buffers ~command_index
          { process_id; stream; wall_time; text = chunk };
        [])
      else
        formatted_output t ~wall_time ~command ~process_id ~stream
          ~chunks:[ chunk ]

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
      if
        (not t.options.timings) || Command.raw command || Command.hidden command
      then []
      else
        handle_output_chunk t event
          (Output_event.process_id event)
          Output_event.Stdout message

let handle_stopped_status t event status =
  match Output_event.command event with
  | None -> []
  | Some command ->
      if Command.raw command || Command.hidden command then []
      else
        let chunk = close_message command status |> reset_colorize t in
        handle_output_chunk t event
          (Output_event.process_id event)
          Output_event.Stdout chunk

let handle_restart_message t event =
  match Output_event.command event with
  | None -> []
  | Some command ->
      if Command.raw command || Command.hidden command then []
      else
        let chunk = Printf.sprintf "%s restarted" (Command.text command) in
        handle_output_chunk t event
          (Output_event.process_id event)
          Output_event.Stdout chunk

let command_in_range t command_index =
  command_index >= 0 && command_index < Array.length t.group_stopped

let handle_started t event command command_index =
  Hashtbl.replace t.started_at_by_command command_index (t.now ());
  Hashtbl.replace t.wall_started_at_by_command command_index (t.wall_now ());
  Hashtbl.remove t.elapsed_by_command command_index;
  handle_timing_command_event t event
    (timing_started_message t command command_index)

let restart_outputs_after_stop t event command_index =
  if t.restart_message_pending.(command_index) then (
    t.restart_message_pending.(command_index) <- false;
    handle_restart_message t event)
  else []

let final_stop_outputs t command command_index ~retrying ~lifecycle_outputs
    ~status_outputs =
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

let handle_stopped t event command command_index status =
  record_elapsed_time t command_index;
  let retrying = t.retry_pending.(command_index) in
  let timing_stopped_outputs =
    match status with
    | None -> []
    | Some _ ->
        handle_timing_command_event t event
          (timing_stopped_message t command command_index)
  in
  (match status with
  | Some (status, killed) when (not retrying) && t.options.timings ->
      remember_timing_summary_entry t
        (timing_summary_entry t command command_index status killed)
  | Some _ | None -> ());
  let stopped_outputs =
    match status with
    | None -> []
    | Some (status, _) -> handle_stopped_status t event status
  in
  let status_outputs =
    if t.options.group then []
    else flush_status_messages_after_command t command_index
  in
  let lifecycle_outputs =
    timing_stopped_outputs @ stopped_outputs
    @ restart_outputs_after_stop t event command_index
  in
  final_stop_outputs t command command_index ~retrying ~lifecycle_outputs
    ~status_outputs
  @ timing_summary_table_outputs t

let handle_restarting t command_index =
  t.retry_pending.(command_index) <- true;
  t.restart_message_pending.(command_index) <- true;
  []

let handle_lifecycle t event lifecycle =
  match Output_event.command event with
  | None -> []
  | Some command -> (
      let command_index = Command.index command in
      if not (command_in_range t command_index) then []
      else
        match lifecycle with
        | Output_event.Started -> handle_started t event command command_index
        | Output_event.Stopped ->
            handle_stopped t event command command_index None
        | Output_event.Stopped_with_status { status; killed } ->
            handle_stopped t event command command_index (Some (status, killed))
        | Output_event.Restarting _ -> handle_restarting t command_index
        | Output_event.Stopping -> [])

let handle_event t event =
  match Output_event.payload event with
  | Output_event.Output_chunk_payload { process_id; stream; chunk } ->
      handle_output_chunk t event process_id stream chunk
  | Output_event.Lifecycle_payload lifecycle ->
      handle_lifecycle t event lifecycle
  | Output_event.Status_message_payload { stream; chunk; after_command } ->
      handle_status_message t ~stream ~chunk ~after_command
  | Output_event.Runtime_warning_payload { stream; chunk } ->
      [ { stream; text = chunk; trailing_newline = false } ]

let error_message = function
  | `Label_count_mismatch (label_count, command_count) ->
      Printf.sprintf "number of labels (%d) must match number of commands (%d)"
        label_count command_count
  | `Non_positive_command_count -> "command count must be positive"
