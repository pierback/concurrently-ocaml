type entry = {
  command_index : int;
  name : string;
  duration_ms : int;
  exit_code : string;
  killed : bool;
  command_text : string;
}

let duration_ms elapsed_time =
  assert (classify_float elapsed_time <> FP_nan);
  assert (classify_float elapsed_time <> FP_infinite);
  assert (elapsed_time >= 0.0);
  let rounded = floor ((elapsed_time *. 1000.0) +. 0.5) in
  assert (rounded <= float_of_int max_int);
  int_of_float rounded

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

let max_string_width values =
  List.fold_left (fun width value -> max width (String.length value)) 0 values

let pad_right width value =
  let padding = width - String.length value in
  if padding <= 0 then value else value ^ String.make padding ' '

let repeat_text count text =
  assert (count >= 0);
  let buffer = Buffer.create (count * String.length text) in
  for _index = 1 to count do
    Buffer.add_string buffer text
  done;
  Buffer.contents buffer

let table_border ~left ~middle ~right widths =
  let cells = List.map (fun width -> repeat_text width "─") widths in
  left ^ "─" ^ String.concat ("─" ^ middle ^ "─") cells ^ "─" ^ right

let sorted_entries entries =
  entries |> List.rev
  |> List.sort (fun left right ->
      let by_duration = compare right.duration_ms left.duration_ms in
      if by_duration <> 0 then by_duration
      else compare left.command_index right.command_index)

let summary_lines ~command_count entries =
  assert (command_count >= 0);
  if List.length entries < command_count then []
  else
    let entries = sorted_entries entries in
    let rows =
      List.map
        (fun entry ->
          [
            entry.name;
            string_of_int entry.duration_ms;
            entry.exit_code;
            string_of_bool entry.killed;
            entry.command_text;
          ])
        entries
    in
    let headers = [ "name"; "duration"; "exit code"; "killed"; "command" ] in
    let column index = List.map (fun row -> List.nth row index) rows in
    let widths =
      List.mapi
        (fun index header -> max_string_width (header :: column index))
        headers
    in
    let format_row cells =
      "│ "
      ^ String.concat " │ "
          (List.map2 (fun width cell -> pad_right width cell) widths cells)
      ^ " │"
    in
    [
      "Timings:";
      table_border ~left:"┌" ~middle:"┬" ~right:"┐" widths;
      format_row headers;
      table_border ~left:"├" ~middle:"┼" ~right:"┤" widths;
    ]
    @ List.map format_row rows
    @ [ table_border ~left:"└" ~middle:"┴" ~right:"┘" widths ]
