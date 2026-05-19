let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | contents -> Some contents
  | exception _ -> None

let strip_jsonc_comments text =
  let length = String.length text in
  let buffer = Buffer.create length in
  let rec string_literal index =
    if index = length then ()
    else (
      Buffer.add_char buffer text.[index];
      match text.[index] with
      | '\\' when index + 1 < length ->
        Buffer.add_char buffer text.[index + 1];
        string_literal (index + 2)
      | '"' -> loop (index + 1)
      | _ -> string_literal (index + 1))
  and line_comment index =
    if index = length then ()
    else
      match text.[index] with
      | '\n' ->
        Buffer.add_char buffer '\n';
        loop (index + 1)
      | _ -> line_comment (index + 1)
  and block_comment index =
    if index + 1 >= length then ()
    else if text.[index] = '*' && text.[index + 1] = '/' then loop (index + 2)
    else block_comment (index + 1)
  and loop index =
    if index = length then ()
    else
      match text.[index] with
      | '"' ->
        Buffer.add_char buffer '"';
        string_literal (index + 1)
      | '/' when index + 1 < length && text.[index + 1] = '/' ->
        line_comment (index + 2)
      | '/' when index + 1 < length && text.[index + 1] = '*' ->
        block_comment (index + 2)
      | character ->
        Buffer.add_char buffer character;
        loop (index + 1)
  in
  loop 0;
  Buffer.contents buffer

let skip_whitespace text index =
  let length = String.length text in
  let rec loop index =
    if index = length then index
    else
      match text.[index] with
      | ' ' | '\t' | '\n' | '\r' -> loop (index + 1)
      | _ -> index
  in
  loop index

let hex_digit_value = function
  | '0' .. '9' as digit -> Some (Char.code digit - Char.code '0')
  | 'a' .. 'f' as digit -> Some (10 + Char.code digit - Char.code 'a')
  | 'A' .. 'F' as digit -> Some (10 + Char.code digit - Char.code 'A')
  | _ -> None

let decode_hex4 text index =
  let length = String.length text in
  if index + 4 > length then None
  else
    let rec loop offset code =
      if offset = 4 then Some (index + 4, code)
      else
        match hex_digit_value text.[index + offset] with
        | None -> None
        | Some value -> loop (offset + 1) ((code lsl 4) + value)
    in
    loop 0 0

let high_surrogate code = code >= 0xD800 && code <= 0xDBFF
let low_surrogate code = code >= 0xDC00 && code <= 0xDFFF

let unicode_replacement_character = 0xFFFD

let scalar_of_unicode_escape text index =
  match decode_hex4 text index with
  | None -> None
  | Some (after_high, high) ->
      if high_surrogate high then
        let length = String.length text in
        if
          after_high + 6 <= length
          && text.[after_high] = '\\'
          && text.[after_high + 1] = 'u'
        then
          match decode_hex4 text (after_high + 2) with
          | Some (after_low, low) when low_surrogate low ->
              let code =
                0x10000 + ((high - 0xD800) lsl 10) + (low - 0xDC00)
              in
              Some (after_low, code)
          | Some _ | None -> Some (after_high, unicode_replacement_character)
        else Some (after_high, unicode_replacement_character)
      else if low_surrogate high then
        Some (after_high, unicode_replacement_character)
      else Some (after_high, high)

let add_utf8_scalar buffer code =
  assert (code >= 0);
  assert (code <= 0x10FFFF);
  if code <= 0x7F then Buffer.add_char buffer (Char.chr code)
  else if code <= 0x7FF then (
    Buffer.add_char buffer (Char.chr (0xC0 lor (code lsr 6)));
    Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F))))
  else if code <= 0xFFFF then (
    Buffer.add_char buffer (Char.chr (0xE0 lor (code lsr 12)));
    Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
    Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F))))
  else (
    Buffer.add_char buffer (Char.chr (0xF0 lor (code lsr 18)));
    Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 12) land 0x3F)));
    Buffer.add_char buffer (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
    Buffer.add_char buffer (Char.chr (0x80 lor (code land 0x3F))))

let decode_json_string text start =
  let length = String.length text in
  assert (start >= 0);
  assert (start < length);
  assert (text.[start] = '"');
  let buffer = Buffer.create 16 in
  let rec loop index =
    if index = length then None
    else
      match text.[index] with
      | '"' -> Some (index + 1, Buffer.contents buffer)
      | '\\' when index + 1 < length ->
        let escaped = text.[index + 1] in
        (match escaped with
         | '"' | '\\' | '/' ->
             Buffer.add_char buffer escaped;
             loop (index + 2)
         | 'b' ->
             Buffer.add_char buffer '\b';
             loop (index + 2)
         | 'f' ->
             Buffer.add_char buffer '\012';
             loop (index + 2)
         | 'n' ->
             Buffer.add_char buffer '\n';
             loop (index + 2)
         | 'r' ->
             Buffer.add_char buffer '\r';
             loop (index + 2)
         | 't' ->
             Buffer.add_char buffer '\t';
             loop (index + 2)
         | 'u' -> (
             match scalar_of_unicode_escape text (index + 2) with
             | None -> None
             | Some (after_escape, code) ->
                 add_utf8_scalar buffer code;
                 loop after_escape)
         | _ ->
             Buffer.add_char buffer escaped;
             loop (index + 2))
      | character ->
        Buffer.add_char buffer character;
        loop (index + 1)
  in
  loop (start + 1)

let skip_json_value text index =
  let length = String.length text in
  let rec loop depth index =
    if index = length then length
    else
      match text.[index] with
      | '"' ->
        (match decode_json_string text index with
         | None -> length
         | Some (after_string, _) -> loop depth after_string)
      | '{' | '[' -> loop (depth + 1) (index + 1)
      | '}' | ']' when depth > 0 -> loop (depth - 1) (index + 1)
      | ',' when depth = 0 -> index
      | '}' when depth = 0 -> index
      | _ -> loop depth (index + 1)
  in
  loop 0 index

let find_top_level_object_field text field_name =
  let length = String.length text in
  let root_start = skip_whitespace text 0 in
  if root_start >= length || text.[root_start] <> '{' then None
  else
    let rec loop index =
      let index = skip_whitespace text index in
      if index >= length || text.[index] = '}' then None
      else if text.[index] <> '"' then None
      else
        match decode_json_string text index with
        | None -> None
        | Some (after_key, key) ->
          let after_key = skip_whitespace text after_key in
          if after_key >= length || text.[after_key] <> ':' then None
          else
          let value_start = skip_whitespace text (after_key + 1) in
          if String.equal key field_name then
            if value_start < length && text.[value_start] = '{' then
              Some value_start
            else None
          else
            let after_value = skip_json_value text value_start in
            let next_index =
              if after_value < length && text.[after_value] = ',' then
                after_value + 1
              else after_value
            in
            loop next_index
    in
    loop (root_start + 1)

let object_keys text object_start =
  let length = String.length text in
  assert (object_start >= 0);
  assert (object_start < length);
  assert (text.[object_start] = '{');
  let rec loop index keys =
    let index = skip_whitespace text index in
    if index >= length || text.[index] = '}' then List.rev keys
    else if text.[index] <> '"' then List.rev keys
    else
      match decode_json_string text index with
      | None -> List.rev keys
      | Some (after_key, key) ->
        let after_key = skip_whitespace text after_key in
        if after_key >= length || text.[after_key] <> ':' then List.rev keys
        else
          let after_value =
            skip_json_value text (skip_whitespace text (after_key + 1))
          in
          let next_index =
            if after_value < length && text.[after_value] = ',' then after_value + 1
            else after_value
          in
          loop next_index (key :: keys)
  in
  loop (object_start + 1) []

let object_field_keys field_name text =
  match find_top_level_object_field text field_name with
  | None -> []
  | Some object_start -> object_keys text object_start

let package_scripts ~cwd =
  match read_file (Filename.concat cwd "package.json") with
  | None -> []
  | Some text -> object_field_keys "scripts" text

let deno_tasks ~cwd =
  let deno_text =
    match read_file (Filename.concat cwd "deno.json") with
    | Some text -> Some text
    | None -> read_file (Filename.concat cwd "deno.jsonc")
  in
  match deno_text with
  | None -> []
  | Some text -> object_field_keys "tasks" (strip_jsonc_comments text)
