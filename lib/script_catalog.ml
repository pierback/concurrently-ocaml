module StringSet = Set.Make (String)

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | contents -> Some contents
  | exception _ -> None

let strip_jsonc_comments text =
  let length = String.length text in
  let buffer = Buffer.create length in
  let failed = ref false in
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
      | '\r' ->
        Buffer.add_char buffer '\r';
        loop (index + 1)
      | _ -> line_comment (index + 1)
  and block_comment index =
    if index + 1 >= length then failed := true
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
  if !failed then None else Some (Buffer.contents buffer)

let strip_jsonc_trailing_commas text =
  let length = String.length text in
  let buffer = Buffer.create length in
  let rec next_non_whitespace index =
    if index = length then index
    else
      match text.[index] with
      | ' ' | '\t' | '\n' | '\r' -> next_non_whitespace (index + 1)
      | _ -> index
  in
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
  and loop index =
    if index = length then ()
    else
      match text.[index] with
      | '"' ->
          Buffer.add_char buffer '"';
          string_literal (index + 1)
      | ',' ->
          let next = next_non_whitespace (index + 1) in
          if next < length && (text.[next] = '}' || text.[next] = ']') then
            loop (index + 1)
          else (
            Buffer.add_char buffer ',';
            loop (index + 1))
      | character ->
          Buffer.add_char buffer character;
          loop (index + 1)
  in
  loop 0;
  Buffer.contents buffer

let normalize_jsonc text =
  match strip_jsonc_comments text with
  | None -> None
  | Some text -> Some (strip_jsonc_trailing_commas text)

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

let skip_json_string_strict text start =
  let length = String.length text in
  assert (start >= 0);
  assert (start < length);
  assert (text.[start] = '"');
  let rec loop index =
    if index = length then None
    else
      match text.[index] with
      | '"' -> Some (index + 1)
      | character when Char.code character < 0x20 -> None
      | '\\' when index + 1 < length -> (
          match text.[index + 1] with
          | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' -> loop (index + 2)
          | 'u' -> (
              match decode_hex4 text (index + 2) with
              | None -> None
              | Some (after_escape, _) -> loop after_escape)
          | _ -> None)
      | '\\' -> None
      | _ -> loop (index + 1)
  in
  loop (start + 1)

let skip_json_number_strict text start =
  let length = String.length text in
  assert (start >= 0);
  assert (start < length);
  let digit index =
    index < length
    &&
    match text.[index] with
    | '0' .. '9' -> true
    | _ -> false
  in
  let nonzero_digit index =
    index < length
    &&
    match text.[index] with
    | '1' .. '9' -> true
    | _ -> false
  in
  let rec digits index =
    if digit index then digits (index + 1) else index
  in
  let index = if text.[start] = '-' then start + 1 else start in
  if index >= length then None
  else
    let after_integer =
      if text.[index] = '0' then Some (index + 1)
      else if nonzero_digit index then Some (digits (index + 1))
      else None
    in
    match after_integer with
    | None -> None
    | Some index ->
        let after_fraction =
          if index < length && text.[index] = '.' then
            if digit (index + 1) then Some (digits (index + 2)) else None
          else Some index
        in
        (match after_fraction with
         | None -> None
         | Some index ->
             if
               index < length && (text.[index] = 'e' || text.[index] = 'E')
             then
               let exponent_start =
                 if
                   index + 1 < length
                   && (text.[index + 1] = '+' || text.[index + 1] = '-')
                 then index + 2
                 else index + 1
               in
               if digit exponent_start then Some (digits (exponent_start + 1))
               else None
             else Some index)

let skip_json_literal text index literal =
  let length = String.length text in
  let literal_length = String.length literal in
  if index + literal_length > length then None
  else if String.sub text index literal_length = literal then
    Some (index + literal_length)
  else None

let json_nesting_limit = 1024

let rec skip_json_value_strict text depth index =
  assert (depth >= 0);
  let index = skip_whitespace text index in
  let length = String.length text in
  if index >= length then None
  else
    match text.[index] with
    | '"' -> skip_json_string_strict text index
    | '{' -> skip_json_object_strict text depth index
    | '[' -> skip_json_array_strict text depth index
    | 't' -> skip_json_literal text index "true"
    | 'f' -> skip_json_literal text index "false"
    | 'n' -> skip_json_literal text index "null"
    | '-' | '0' .. '9' -> skip_json_number_strict text index
    | _ -> None

and skip_json_object_strict text depth start =
  let length = String.length text in
  assert (start >= 0);
  assert (start < length);
  assert (text.[start] = '{');
  if depth >= json_nesting_limit then None
  else
    let value_depth = depth + 1 in
    let rec fields index =
      let index = skip_whitespace text index in
      if index >= length then None
      else if text.[index] = '}' then Some (index + 1)
      else if text.[index] <> '"' then None
      else
        match skip_json_string_strict text index with
        | None -> None
        | Some after_key ->
            let after_key = skip_whitespace text after_key in
            if after_key >= length || text.[after_key] <> ':' then None
            else
              (match skip_json_value_strict text value_depth (after_key + 1) with
               | None -> None
               | Some after_value ->
                   let after_value = skip_whitespace text after_value in
                   if after_value >= length then None
                   else if text.[after_value] = '}' then Some (after_value + 1)
                   else if text.[after_value] = ',' then
                     let next = skip_whitespace text (after_value + 1) in
                     if next < length && text.[next] = '}' then None
                     else fields next
                   else None)
    in
    fields (start + 1)

and skip_json_array_strict text depth start =
  let length = String.length text in
  assert (start >= 0);
  assert (start < length);
  assert (text.[start] = '[');
  if depth >= json_nesting_limit then None
  else
    let value_depth = depth + 1 in
    let rec values index =
      let index = skip_whitespace text index in
      if index >= length then None
      else if text.[index] = ']' then Some (index + 1)
      else
        match skip_json_value_strict text value_depth index with
        | None -> None
        | Some after_value ->
            let after_value = skip_whitespace text after_value in
            if after_value >= length then None
            else if text.[after_value] = ']' then Some (after_value + 1)
            else if text.[after_value] = ',' then
              let next = skip_whitespace text (after_value + 1) in
              if next < length && text.[next] = ']' then None else values next
            else None
    in
    values (start + 1)

let valid_json text =
  match skip_json_value_strict text 0 0 with
  | None -> false
  | Some after_value -> skip_whitespace text after_value = String.length text

let skip_json_value text index =
  let length = String.length text in
  let rec loop depth index =
    if index = length then length
    else if depth > json_nesting_limit then length
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
      | ']' when depth = 0 -> index
      | _ -> loop depth (index + 1)
  in
  loop 0 index

let json_string_utf16_length text start =
  let length = String.length text in
  if start < 0 || start >= length || text.[start] <> '"' then None
  else
  let utf8_advance_and_width index =
    let byte = Char.code text.[index] in
    if byte < 0x80 then (index + 1, 1)
    else if byte land 0xE0 = 0xC0 && index + 1 < length then (index + 2, 1)
    else if byte land 0xF0 = 0xE0 && index + 2 < length then (index + 3, 1)
    else if byte land 0xF8 = 0xF0 && index + 3 < length then (index + 4, 2)
    else (index + 1, 1)
  in
  let rec loop index units =
    if index = length then None
    else
      match text.[index] with
      | '"' -> Some units
      | '\\' when index + 1 < length && text.[index + 1] = 'u' -> (
          match decode_hex4 text (index + 2) with
          | Some (after_high, high)
            when high_surrogate high
                 && after_high + 6 <= length
                 && text.[after_high] = '\\'
                 && text.[after_high + 1] = 'u' -> (
              match decode_hex4 text (after_high + 2) with
              | Some (after_low, low) when low_surrogate low ->
                  loop after_low (units + 2)
              | Some _ | None -> loop after_high (units + 1))
          | Some (after_escape, _) -> loop after_escape (units + 1)
          | None -> None)
      | '\\' when index + 1 < length -> loop (index + 2) (units + 1)
      | '\\' -> None
      | _ ->
          let index, width = utf8_advance_and_width index in
          loop index (units + width)
  in
  loop (start + 1) 0

let decimal_indices count =
  assert (count >= 0);
  List.init count string_of_int

let array_indices text array_start =
  let length = String.length text in
  if array_start < 0 || array_start >= length || text.[array_start] <> '[' then []
  else
  let rec loop index count =
    let index = skip_whitespace text index in
    if index >= length || text.[index] = ']' then decimal_indices count
    else
      let after_value = skip_json_value text index in
      let next_index =
        if after_value < length && text.[after_value] = ',' then after_value + 1
        else after_value
      in
      loop next_index (count + 1)
  in
  loop (array_start + 1) 0

let find_top_level_object_field text field_name =
  let length = String.length text in
  let root_start = skip_whitespace text 0 in
  if root_start >= length || text.[root_start] <> '{' then None
  else
    let rec loop index found =
      let index = skip_whitespace text index in
      if index >= length then None
      else if text.[index] = '}' then found
      else if text.[index] <> '"' then None
      else
        match decode_json_string text index with
        | None -> None
        | Some (after_key, key) ->
          let after_key = skip_whitespace text after_key in
          if after_key >= length || text.[after_key] <> ':' then None
          else
          let value_start = skip_whitespace text (after_key + 1) in
          let after_value = skip_json_value text value_start in
          let next_index =
            if after_value < length && text.[after_value] = ',' then
              after_value + 1
            else after_value
          in
          let found =
            if String.equal key field_name then
              Some value_start
            else found
          in
          loop next_index found
    in
    loop (root_start + 1) None

let javascript_array_index_max = 4_294_967_294

let javascript_array_index key =
  let length = String.length key in
  if length = 0 then None
  else if String.equal key "0" then Some 0
  else if key.[0] = '0' then None
  else
    let rec loop index value =
      if index = length then Some value
      else
        let character = key.[index] in
        if character < '0' || character > '9' then None
        else
          let digit = Char.code character - Char.code '0' in
          let limit = javascript_array_index_max in
          if value > (limit - digit) / 10 then None
          else loop (index + 1) ((value * 10) + digit)
    in
    loop 0 0

type object_key = {
  name : string;
  array_index : int option;
  insertion_index : int;
}

let compare_object_keys left right =
  match (left.array_index, right.array_index) with
  | Some left_index, Some right_index -> compare left_index right_index
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare left.insertion_index right.insertion_index

let object_key_names keys =
  keys |> List.sort compare_object_keys |> List.map (fun key -> key.name)

let object_keys text object_start =
  let length = String.length text in
  if object_start < 0 || object_start >= length || text.[object_start] <> '{' then []
  else
  let rec loop index seen insertion_index keys =
    let index = skip_whitespace text index in
    if index >= length || text.[index] = '}' then object_key_names keys
    else if text.[index] <> '"' then object_key_names keys
    else
      match decode_json_string text index with
      | None -> object_key_names keys
      | Some (after_key, key) ->
        let after_key = skip_whitespace text after_key in
        if after_key >= length || text.[after_key] <> ':' then object_key_names keys
        else
          let after_value =
            skip_json_value text (skip_whitespace text (after_key + 1))
          in
          let next_index =
            if after_value < length && text.[after_value] = ',' then after_value + 1
            else after_value
          in
          if StringSet.mem key seen then loop next_index seen insertion_index keys
          else
            let object_key =
              {
                name = key;
                array_index = javascript_array_index key;
                insertion_index;
              }
            in
            loop next_index (StringSet.add key seen) (insertion_index + 1)
              (object_key :: keys)
  in
  loop (object_start + 1) StringSet.empty 0 []

let object_field_keys field_name text =
  match find_top_level_object_field text field_name with
  | None -> []
  | Some value_start -> (
      match text.[value_start] with
      | '{' -> object_keys text value_start
      | '[' -> array_indices text value_start
      | '"' -> (
          match json_string_utf16_length text value_start with
          | None -> []
          | Some 0 -> []
          | Some length -> decimal_indices length)
      | _ -> [])

let package_scripts ~cwd =
  match read_file (Filename.concat cwd "package.json") with
  | None -> []
  | Some text ->
      if valid_json text then object_field_keys "scripts" text else []

let deno_tasks ~cwd =
  let deno_text =
    match read_file (Filename.concat cwd "deno.json") with
    | Some text -> Some text
    | None -> read_file (Filename.concat cwd "deno.jsonc")
  in
  match deno_text with
  | None -> []
  | Some text ->
      (match normalize_jsonc text with
       | None -> []
       | Some text ->
           if valid_json text then object_field_keys "tasks" text else [])
