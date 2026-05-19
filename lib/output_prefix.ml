type mode =
  | Default
  | Index
  | Pid
  | Name
  | Command
  | No_prefix
  | Time
  | Template of string

type options = {
  prefix_length : float;
  pad_prefix : bool;
  timestamp_format : string;
}

let mode = function
  | None -> Default
  | Some value -> (
      match String.lowercase_ascii value with
      | "index" -> Index
      | "pid" -> Pid
      | "name" -> Name
      | "command" -> Command
      | "none" -> No_prefix
      | "time" -> Time
      | _ -> Template value)

let padded_int width value = Printf.sprintf "%0*d" width value

let format_timestamp format timestamp =
  let seconds = floor timestamp in
  let milliseconds = int_of_float (floor ((timestamp -. seconds) *. 1000.0)) in
  let time = Unix.localtime seconds in
  let buffer = Buffer.create (String.length format + 8) in
  let tokens =
    [
      ("yyyy", padded_int 4 (time.Unix.tm_year + 1900));
      ("SSS", padded_int 3 milliseconds);
      ("MM", padded_int 2 (time.Unix.tm_mon + 1));
      ("dd", padded_int 2 time.Unix.tm_mday);
      ("HH", padded_int 2 time.Unix.tm_hour);
      ("mm", padded_int 2 time.Unix.tm_min);
      ("ss", padded_int 2 time.Unix.tm_sec);
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

let js_to_integer value =
  match classify_float value with
  | FP_nan -> 0
  | FP_infinite when value < 0.0 -> min_int / 2
  | FP_infinite -> max_int / 2
  | FP_normal | FP_subnormal | FP_zero -> int_of_float value

let js_slice text start_index end_index =
  let length = String.length text in
  let bounded_index index =
    let index = js_to_integer index in
    if index < 0 then max 0 (length + index) else min length index
  in
  let start_index = bounded_index start_index in
  let end_index = bounded_index end_index in
  if end_index <= start_index then ""
  else String.sub text start_index (end_index - start_index)

let truncate_command ~prefix_length text =
  let prefix_length =
    if classify_float prefix_length = FP_nan || prefix_length = 0.0 then 10.0
    else prefix_length
  in
  let text_length = String.length text in
  if text_length = 0 || float_of_int text_length <= prefix_length then text
  else
    let ellipsis_length = 2.0 in
    let content_length = prefix_length -. ellipsis_length in
    let end_length = floor (content_length /. 2.0) in
    let beginning_length = content_length -. end_length in
    js_slice text 0.0 beginning_length
    ^ ".."
    ^ js_slice text (float_of_int text_length -. end_length) (float_of_int text_length)

let name_label command =
  match Command.name command with Some name -> name | None -> ""

let index_label command = string_of_int (Command.index command)

let default_label command =
  match Command.name command with
  | Some name when not (String.equal name "") -> name
  | Some _ | None -> index_label command

let template_label ~now ~options ~process_id command template =
  let replacements =
    [
      ("{index}", index_label command);
      ("{pid}", Option.value ~default:"" process_id);
      ("{name}", name_label command);
      ("{command}", Command.text command);
      ("{time}", format_timestamp options.timestamp_format (now ()));
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

let raw_label ~now ~options ~process_id ~mode command =
  match mode with
  | Default -> default_label command
  | Index -> index_label command
  | Pid -> Option.value ~default:"" process_id
  | Name -> name_label command
  | Command ->
      truncate_command ~prefix_length:options.prefix_length
        (Command.text command)
  | No_prefix -> ""
  | Time -> format_timestamp options.timestamp_format (now ())
  | Template template ->
      template_label ~now ~options ~process_id command template

let default_label_for_width ~labels command =
  match Command.name command with
  | Some name when not (String.equal name "") -> name
  | Some _ | None -> (
      let index = Command.index command in
      match List.nth_opt labels index with
      | Some label when not (String.equal label "") -> label
      | Some _ | None -> index_label command)

let raw_label_for_width ~now ~options ~mode ~labels command =
  match mode with
  | Default -> default_label_for_width ~labels command
  | Index | Pid | Name | Command | No_prefix | Time | Template _ ->
      raw_label ~now ~options ~process_id:None ~mode command

let label_width ~wall_now ~options ~mode ~labels commands =
  match (mode, options.pad_prefix) with
  | No_prefix, _ | Pid, _ | Template _, _ | _, false -> None
  | _ ->
      commands
      |> List.map (raw_label_for_width ~now:wall_now ~options ~mode ~labels)
      |> List.fold_left (fun width label -> max width (String.length label)) 0
      |> Option.some

let label_for_command ~wall_time ~process_id ~options ~mode ~labels ~width
    command =
  let label =
    match mode with
    | Default -> (
        match Command.name command with
        | Some name when not (String.equal name "") -> name
        | Some _ | None ->
            let index = Command.index command in
            if
              index < Array.length labels
              && not (String.equal labels.(index) "")
            then labels.(index)
            else index_label command)
    | Index | Pid | Command | No_prefix | Time | Template _ ->
        raw_label ~now:(fun () -> wall_time) ~options ~process_id ~mode command
    | Name ->
        let index = Command.index command in
        if index < Array.length labels then labels.(index)
        else name_label command
  in
  match width with
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

let template_mentions_process_id template = template_mentions template "{pid}"
let template_mentions_time template = template_mentions template "{time}"

let mentions_time = function
  | Time -> true
  | Template template -> template_mentions_time template
  | Default | Index | Pid | Name | Command | No_prefix -> false

let displayed_process_id mode process_id =
  match mode with
  | Pid -> process_id
  | Template template when template_mentions_process_id template -> process_id
  | Default | Index | Name | Command | No_prefix | Time | Template _ -> None

let brackets_label = function Template _ -> false | _ -> true
