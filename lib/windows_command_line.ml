let needs_quotes value =
  value = ""
  || String.exists
       (function
         | ' ' | '\t' | '"' -> true
         | _ -> false)
       value

let quote_arg value =
  if not (needs_quotes value) then value
  else
    let quoted = Buffer.create (String.length value + 2) in
    Buffer.add_char quoted '"';
    let backslashes = ref 0 in
    String.iter
      (fun character ->
        match character with
        | '\\' -> incr backslashes
        | '"' ->
            Buffer.add_string quoted (String.make (!backslashes * 2) '\\');
            backslashes := 0;
            Buffer.add_string quoted "\\\""
        | _ ->
            Buffer.add_string quoted (String.make !backslashes '\\');
            backslashes := 0;
            Buffer.add_char quoted character)
      value;
    Buffer.add_string quoted (String.make (!backslashes * 2) '\\');
    Buffer.add_char quoted '"';
    Buffer.contents quoted

let shell_command_line ~shell_path ~command_text =
  String.concat " "
    [ quote_arg shell_path; "/d"; "/s"; "/c"; command_text ]
