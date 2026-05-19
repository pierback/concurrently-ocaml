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

let hex_color_codes value =
  match String.length value with
  | 4 when value.[0] = '#' -> (
      match
        ( hex_nibble_byte value 1,
          hex_nibble_byte value 2,
          hex_nibble_byte value 3 )
      with
      | Some red, Some green, Some blue -> Some [ 38; 2; red; green; blue ]
      | _ -> None)
  | 7 when value.[0] = '#' -> (
      match (hex_byte value 1, hex_byte value 3, hex_byte value 5) with
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
  let palette = [| 36; 33; 92; 94; 95; 37; 90; 31 |] in
  [ palette.(command_index mod Array.length palette) ]

let foreground_style codes = { open_codes = codes; close_codes = [ 39 ] }
let background_style codes = { open_codes = codes; close_codes = [ 49 ] }
let reset_style = { open_codes = [ 0 ]; close_codes = [ 0 ] }

let prefix_part_styles ~command_index part =
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
                    match hex_color_codes part with
                    | Some codes -> Ok [ foreground_style codes ]
                    | None -> Error part))))

let prefix_styles ~command_index prefix_color =
  assert (command_index >= 0);
  prefix_color |> String.split_on_char '.'
  |> List.fold_left
       (fun result part ->
         match result with
         | Error _ as error -> error
         | Ok styles -> (
             match prefix_part_styles ~command_index part with
             | Ok part_styles -> Ok (styles @ part_styles)
             | Error _ as error -> error))
       (Ok [])
