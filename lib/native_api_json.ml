let json_escape value =
  let buffer = Buffer.create (String.length value + 8) in
  String.iter
    (fun character ->
      match character with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\012' -> Buffer.add_string buffer "\\f"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | character ->
        let code = Char.code character in
        if code < 0x20 then Buffer.add_string buffer (Printf.sprintf "\\u%04x" code)
        else Buffer.add_char buffer character)
    value;
  "\"" ^ Buffer.contents buffer ^ "\""

let json_option_string = function
  | None -> "null"
  | Some value -> json_escape value

let json_float value = Printf.sprintf "%.17g" value

let hex_digit value =
  if value < 10 then Char.chr (Char.code '0' + value)
  else Char.chr (Char.code 'a' + value - 10)

let hex_encode value =
  let buffer = Bytes.create (String.length value * 2) in
  String.iteri
    (fun index character ->
      let code = Char.code character in
      Bytes.set buffer (index * 2) (hex_digit (code lsr 4));
      Bytes.set buffer ((index * 2) + 1) (hex_digit (code land 0x0f)))
    value;
  Bytes.unsafe_to_string buffer

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

let close_event_exit_code_json close_event =
  match Close_event.status close_event with
  | Close_event.Exited code -> string_of_int code
  | Close_event.Signaled signal -> json_escape (signal_label signal)
  | Close_event.Spawn_error message -> json_escape message

let close_event_json close_event =
  let command = Close_event.command close_event in
  let timings = Close_event.timings close_event in
  Printf.sprintf
    {|{"index":%d,"command":%s,"name":%s,"attempt":%d,"killed":%s,"exitCode":%s,"timings":{"startedAt":%s,"endedAt":%s,"durationSeconds":%s}}|}
    (Command.index command)
    (json_escape (Command.text command))
    (json_option_string (Command.name command))
    (Close_event.attempt close_event)
    (if Close_event.killed close_event then "true" else "false")
    (close_event_exit_code_json close_event)
    (json_float timings.Close_event.started_at)
    (json_float timings.Close_event.ended_at)
    (json_float timings.Close_event.duration_seconds)

let close_events_json close_events =
  let sorted_events =
    List.sort
      (fun left right ->
        let left_command = Close_event.command left in
        let right_command = Close_event.command right in
        match Int.compare (Command.index left_command) (Command.index right_command) with
        | 0 -> Int.compare (Close_event.attempt left) (Close_event.attempt right)
        | comparison -> comparison)
      close_events
  in
  let buffer = Buffer.create 128 in
  Buffer.add_char buffer '[';
  List.iteri
    (fun index close_event ->
      if index > 0 then Buffer.add_char buffer ',';
      Buffer.add_string buffer (close_event_json close_event))
    sorted_events;
  Buffer.add_string buffer "]\n";
  Buffer.contents buffer

let output_stream_json = function
  | Output_event.Stdout -> "stdout"
  | Output_event.Stderr -> "stderr"

let command_prefix_json command attempt =
  Printf.sprintf
    {|"index":%d,"attempt":%d|}
    (Command.index command)
    attempt

let output_chunk_json ~command ~attempt ~stream ~chunk =
  Printf.sprintf
    {|{"type":"output",%s,"stream":%s,"chunkHex":%s}|}
    (command_prefix_json command attempt)
    (json_escape (output_stream_json stream))
    (json_escape (hex_encode chunk))

let lifecycle_json ~observed_at ~command ~attempt = function
  | Output_event.Started ->
    Printf.sprintf
      {|{"type":"lifecycle",%s,"state":"started","at":%s}|}
      (command_prefix_json command attempt)
      (json_float observed_at)
  | Output_event.Stopped_with_status { status; killed } ->
    let status_json =
      match status with
      | Close_event.Exited code -> string_of_int code
      | Close_event.Signaled signal -> json_escape (signal_label signal)
      | Close_event.Spawn_error message -> json_escape message
    in
    Printf.sprintf
      {|{"type":"lifecycle",%s,"state":"exited","killed":%s,"exitCode":%s,"at":%s}|}
      (command_prefix_json command attempt)
      (if killed then "true" else "false")
      status_json
      (json_float observed_at)
  | Output_event.Restarting _ | Output_event.Stopping | Output_event.Stopped -> ""

let output_event_json ~observed_at event =
  match Output_event.payload event, Output_event.command event with
  | ( Output_event.Output_chunk_payload { stream; chunk; _ }
    , Some command ) ->
    Some
      (output_chunk_json
         ~command
         ~attempt:(Output_event.attempt event)
         ~stream
         ~chunk)
  | Output_event.Lifecycle_payload lifecycle, Some command ->
    (match lifecycle_json ~observed_at ~command ~attempt:(Output_event.attempt event) lifecycle with
     | "" -> None
     | json -> Some json)
  | Output_event.Status_message_payload _, _
  | Output_event.Output_chunk_payload _, None
  | Output_event.Lifecycle_payload _, None ->
    None
