module Output_color = Concurrentlyocaml.Output_color

let test_prefix_styles_parse_chalk_parts () =
  match
    Output_color.prefix_styles ~color_level:3 ~command_index:2
      "red.bold.bgBlue"
  with
  | Error _ -> assert false
  | Ok styles ->
      assert (List.length styles = 3);
      assert ((List.nth styles 0).Output_color.open_codes = [ 31 ]);
      assert ((List.nth styles 1).Output_color.open_codes = [ 1 ]);
      assert ((List.nth styles 2).Output_color.open_codes = [ 44 ])

let test_prefix_styles_reject_unknown_part () =
  match Output_color.prefix_styles ~color_level:3 ~command_index:0 "red.nope" with
  | Ok _ -> assert false
  | Error part -> assert (part = "nope")

let test_auto_colors_are_bounded_by_palette () =
  match Output_color.prefix_styles ~color_level:3 ~command_index:8 "auto" with
  | Error _ -> assert false
  | Ok styles ->
      assert (List.length styles = 1);
      assert ((List.nth styles 0).Output_color.open_codes = [ 33 ]);
      assert ((List.nth styles 0).Output_color.close_codes = [ 39 ])

let test_hex_colors_follow_chalk_color_level () =
  let assert_hex color_level expected =
    match
      Output_color.prefix_styles ~color_level ~command_index:0 "#23de43"
    with
    | Error _ -> assert false
    | Ok [ style ] -> assert (style.Output_color.open_codes = expected)
    | Ok _ -> assert false
  in
  assert_hex 1 [ 32 ];
  assert_hex 2 [ 38; 5; 77 ];
  assert_hex 3 [ 38; 2; 35; 222; 67 ]

let test_function_style_colors_follow_chalk_paths () =
  (match
     Output_color.prefix_styles ~color_level:3 ~command_index:0 "rgb(1,2,3)"
   with
  | Error _ -> assert false
  | Ok [ style ] ->
      assert (style.Output_color.open_codes = [ 38; 2; 1; 2; 3 ])
  | Ok _ -> assert false);
  match
    Output_color.prefix_styles ~color_level:3 ~command_index:0 "ansi256(123)"
  with
  | Error _ -> assert false
  | Ok [ style ] -> assert (style.Output_color.open_codes = [ 38; 5; 123 ])
  | Ok _ -> assert false

let () =
  test_prefix_styles_parse_chalk_parts ();
  test_prefix_styles_reject_unknown_part ();
  test_auto_colors_are_bounded_by_palette ();
  test_hex_colors_follow_chalk_color_level ();
  test_function_style_colors_follow_chalk_paths ()
