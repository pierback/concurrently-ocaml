type style = { open_codes : int list; close_codes : int list }

let lowercase_trim value = value |> String.trim |> String.lowercase_ascii

let hex_digit = function
  | '0' .. '9' as digit -> Some (Char.code digit - Char.code '0')
  | 'a' .. 'f' as digit -> Some (10 + Char.code digit - Char.code 'a')
  | 'A' .. 'F' as digit -> Some (10 + Char.code digit - Char.code 'A')
  | _ -> None

let hex_byte value offset =
  match (hex_digit value.[offset], hex_digit value.[offset + 1]) with
  | Some high, Some low -> Some ((high * 16) + low)
  | _ -> None

let hex_nibble_byte value offset =
  match hex_digit value.[offset] with
  | Some nibble -> Some ((nibble * 16) + nibble)
  | None -> None

let round_positive value =
  assert (value >= 0.0);
  int_of_float (floor (value +. 0.5))

let rec ansi16_code red green blue =
  let ansi256 = ansi256_code red green blue in
  if ansi256 < 8 then 30 + ansi256
  else if ansi256 < 16 then 90 + ansi256 - 8
  else if ansi256 >= 232 then if ansi256 < 244 then 30 else 37
  else
    let value = ansi256 - 16 in
    let red_level = value / 36 in
    let green_level = value / 6 mod 6 in
    let blue_level = value mod 6 in
    let bit level = if level > 2 then 1 else 0 in
    let code =
      30
      + ((bit blue_level lsl 2) lor (bit green_level lsl 1)
        lor bit red_level)
    in
    if max red_level (max green_level blue_level) = 5 then code + 60 else code

and ansi256_code red green blue =
  if red = green && green = blue then
    if red < 8 then 16
    else if red > 248 then 231
    else round_positive ((float_of_int (red - 8) /. 247.0) *. 24.0) + 232
  else
    16
    + (36 * round_positive ((float_of_int red /. 255.0) *. 5.0))
    + (6 * round_positive ((float_of_int green /. 255.0) *. 5.0))
    + round_positive ((float_of_int blue /. 255.0) *. 5.0)

let foreground_color_codes ~color_level red green blue =
  assert (color_level >= 1);
  assert (color_level <= 3);
  match color_level with
  | 1 -> [ ansi16_code red green blue ]
  | 2 -> [ 38; 5; ansi256_code red green blue ]
  | _ -> [ 38; 2; red; green; blue ]

let bounded_int ~min_value ~max_value value =
  match int_of_string_opt (String.trim value) with
  | Some number when number >= min_value && number <= max_value -> Some number
  | _ -> None

let strip_call ~name value =
  let prefix = name ^ "(" in
  let prefix_length = String.length prefix in
  let value_length = String.length value in
  if
    value_length > prefix_length
    && String.sub value 0 prefix_length = prefix
    && value.[value_length - 1] = ')'
  then Some (String.sub value prefix_length (value_length - prefix_length - 1))
  else None

let rgb_function_codes ~color_level value =
  match strip_call ~name:"rgb" value with
  | None -> None
  | Some arguments -> (
      match String.split_on_char ',' arguments with
      | [ red; green; blue ] -> (
          match
            ( bounded_int ~min_value:0 ~max_value:255 red,
              bounded_int ~min_value:0 ~max_value:255 green,
              bounded_int ~min_value:0 ~max_value:255 blue )
          with
          | Some red, Some green, Some blue ->
              Some (foreground_color_codes ~color_level red green blue)
          | _ -> None)
      | _ -> None)

let ansi256_function_codes value =
  match strip_call ~name:"ansi256" value with
  | None -> None
  | Some argument -> (
      match bounded_int ~min_value:0 ~max_value:255 argument with
      | Some code -> Some [ 38; 5; code ]
      | None -> None)

let hex_color_codes ~color_level value =
  match String.length value with
  | 4 when value.[0] = '#' -> (
      match
        ( hex_nibble_byte value 1,
          hex_nibble_byte value 2,
          hex_nibble_byte value 3 )
      with
      | Some red, Some green, Some blue ->
          Some (foreground_color_codes ~color_level red green blue)
      | _ -> None)
  | 7 when value.[0] = '#' -> (
      match (hex_byte value 1, hex_byte value 3, hex_byte value 5) with
      | Some red, Some green, Some blue ->
          Some (foreground_color_codes ~color_level red green blue)
      | _ -> None)
  | _ -> None

let function_color_codes ~color_level value =
  match rgb_function_codes ~color_level value with
  | Some codes -> Some codes
  | None -> ansi256_function_codes value

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
  assert (command_index >= 0);
  let palette = [| 36; 35; 32; 33; 34 |] in
  [ palette.(command_index mod Array.length palette) ]

let foreground_style codes = { open_codes = codes; close_codes = [ 39 ] }
let background_style codes = { open_codes = codes; close_codes = [ 49 ] }
let reset_style = { open_codes = [ 0 ]; close_codes = [ 0 ] }

let prefix_part_styles ~color_level ~command_index part =
  let part = lowercase_trim part in
  if part = "" || part = "reset" then Ok [ reset_style ]
  else if part = "auto" then
    Ok [ foreground_style (auto_color_code command_index) ]
  else
    match foreground_color_code part with
    | Some codes -> Ok [ foreground_style codes ]
    | None -> (
        match bright_foreground_color_code part with
        | Some codes -> Ok [ foreground_style codes ]
        | None -> (
            match background_color_code part with
            | Some codes -> Ok [ background_style codes ]
            | None -> (
                match modifier_style part with
                | Some style -> Ok [ style ]
                | None -> (
                    match hex_color_codes ~color_level part with
                    | Some codes -> Ok [ foreground_style codes ]
                    | None -> (
                        match function_color_codes ~color_level part with
                        | Some codes -> Ok [ foreground_style codes ]
                        | None -> Error part)))))

let prefix_styles ~color_level ~command_index prefix_color =
  assert (color_level >= 1);
  assert (color_level <= 3);
  assert (command_index >= 0);
  prefix_color |> String.split_on_char '.'
  |> List.fold_left
       (fun result part ->
         match result with
         | Error _ as error -> error
         | Ok styles -> (
             match prefix_part_styles ~color_level ~command_index part with
             | Ok part_styles -> Ok (styles @ part_styles)
             | Error _ as error -> error))
       (Ok [])
