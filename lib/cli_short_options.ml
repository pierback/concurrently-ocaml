let expand_clusters argv =
  let is_cluster argument =
    let length = String.length argument in
    length > 2
    && argument.[0] = '-'
    && argument.[1] <> '-'
    && not (String.contains argument '=')
  in
  let short_option argument index = "-" ^ String.make 1 argument.[index] in
  let suffix argument index =
    String.sub argument index (String.length argument - index)
  in
  let attached_value argument index emitted_value_option =
    let suffix_start = index + 1 in
    if suffix_start = String.length argument then short_option argument index
    else emitted_value_option ^ "=" ^ suffix argument suffix_start
  in
  let is_option_character = function
    | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' -> true
    | _ -> false
  in
  let numeric_suffix text =
    let text =
      if String.length text > 0 && text.[String.length text - 1] = '%' then
        String.sub text 0 (String.length text - 1)
      else text
    in
    String.length text > 0 && Option.is_some (float_of_string_opt text)
  in
  let attached_short_value_option argument index =
    let option_char = argument.[index] in
    let suffix_start = index + 1 in
    if suffix_start = String.length argument then None
    else
      let suffix = suffix argument suffix_start in
      if not (numeric_suffix suffix) then None
      else
        match option_char with
        | 'm' -> Some "--max-processes"
        | 'l' -> Some "--prefix-length"
        | _ -> None
  in
  let expand_cluster argument =
    assert (is_cluster argument);
    let rec loop index emitted =
      if index = String.length argument then
        match emitted with [] -> [ argument ] | _ -> List.rev emitted
      else
        match attached_short_value_option argument index with
        | Some emitted_value_option ->
            List.rev
              (attached_value argument index emitted_value_option :: emitted)
	        | None when List.mem argument.[index] Cli_options.short_boolean_flags ->
	            loop (index + 1) (short_option argument index :: emitted)
	        | None
	          when index = 1
	               && emitted = []
	               && String.equal (short_option argument index) "-n" ->
	            []
	        | None -> (
            match emitted with
            | [] -> loop (index + 1) emitted
            | _ when not (is_option_character argument.[index]) ->
                List.rev emitted
            | _ -> List.rev (("-" ^ suffix argument index) :: emitted))
    in
    loop 1 []
  in
  let rec loop index arguments =
    if index >= Array.length argv then Array.of_list (List.rev arguments)
    else if argv.(index) = "--" then
      let tail_count = Array.length argv - index in
      let tail = List.init tail_count (fun offset -> argv.(index + offset)) in
      Array.of_list (List.rev_append arguments tail)
    else
      let argument = argv.(index) in
      if is_cluster argument then
        loop (index + 1) (List.rev_append (expand_cluster argument) arguments)
      else loop (index + 1) (argument :: arguments)
  in
  match Array.length argv with 0 -> argv | _ -> loop 1 [ argv.(0) ]
