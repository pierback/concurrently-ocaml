let is_safe_shell_char = function
  | 'A' .. 'Z'
  | 'a' .. 'z'
  | '0' .. '9'
  | '_'
  | '@'
  | '%'
  | '+'
  | '='
  | ':'
  | ','
  | '.'
  | '/'
  | '-' ->
    true
  | _ -> false

let posix_shell_quote argument =
  if argument = "" then "''"
  else if String.for_all is_safe_shell_char argument then argument
  else
    let buffer = Buffer.create (String.length argument + 2) in
    Buffer.add_char buffer '\'';
    String.iter
      (function
        | '\'' -> Buffer.add_string buffer "'\\''"
        | character -> Buffer.add_char buffer character)
      argument;
    Buffer.add_char buffer '\'';
    Buffer.contents buffer

(* Passthrough placeholders intentionally use the npm package's shell-quote
   behavior on every platform; Windows process-launch quoting is handled later. *)
let shell_quote argument = posix_shell_quote argument

let quote_arguments arguments =
  arguments |> List.map shell_quote |> String.concat " "

let valid_number_target target =
  let length = String.length target in
  length > 0
  && target.[0] <> '0'
  &&
  let rec loop index =
    index = length
    ||
    match target.[index] with
    | '0' .. '9' -> loop (index + 1)
    | _ -> false
  in
  loop 0

let valid_target = function
  | "@" | "*" -> true
  | target -> valid_number_target target

let placeholder_at command open_index =
  assert (open_index >= 0);
  assert (open_index < String.length command);
  assert (command.[open_index] = '{');
  match String.index_from_opt command open_index '}' with
  | None -> None
  | Some close_index ->
    let target =
      String.sub command (open_index + 1) (close_index - open_index - 1)
    in
    if valid_target target then Some (close_index + 1, target) else None

let replacement ~additional_arguments = function
  | "@" -> quote_arguments additional_arguments
  | "*" -> shell_quote (String.concat " " additional_arguments)
  | target ->
    (match int_of_string_opt target with
     | Some position when position >= 1 ->
       (match List.nth_opt additional_arguments (position - 1) with
        | Some argument -> shell_quote argument
        | None -> "")
     | Some _ | None ->
       invalid_arg
         ("Argument_expander.replacement: invalid placeholder target " ^ target))

let expand ~additional_arguments command =
  let length = String.length command in
  let buffer = Buffer.create length in
  let rec loop index =
    if index = length then Buffer.contents buffer
    else
      match command.[index] with
      | '\\' when index + 1 < length && command.[index + 1] = '{' ->
        (match placeholder_at command (index + 1) with
         | Some (after_placeholder, _) ->
           Buffer.add_substring
             buffer
             command
             (index + 1)
             (after_placeholder - index - 1);
           loop after_placeholder
         | None ->
           Buffer.add_char buffer command.[index];
           loop (index + 1))
      | '{' ->
        (match placeholder_at command index with
         | Some (after_placeholder, target) ->
           Buffer.add_string
             buffer
             (replacement ~additional_arguments target);
           loop after_placeholder
         | None ->
           Buffer.add_char buffer command.[index];
           loop (index + 1))
      | character ->
        Buffer.add_char buffer character;
        loop (index + 1)
  in
  loop 0
