module Windows_command_line = Concurrentlyocaml.Windows_command_line

let test_quote_arg_preserves_simple_arguments () =
  assert (Windows_command_line.quote_arg "cmd.exe" = "cmd.exe")

let test_quote_arg_quotes_spaces () =
  assert (
    Windows_command_line.quote_arg "C:\\Program Files\\cmd.exe"
    = "\"C:\\Program Files\\cmd.exe\"")

let test_quote_arg_escapes_embedded_quotes () =
  assert (
    Windows_command_line.quote_arg "node -e \"console.log(1)\""
    = "\"node -e \\\"console.log(1)\\\"\"")

let test_quote_arg_doubles_trailing_backslashes () =
  assert (
    Windows_command_line.quote_arg "C:\\Program Files\\"
    = "\"C:\\Program Files\\\\\"")

let test_shell_command_line_uses_cmd_flags () =
  assert (
    Windows_command_line.shell_command_line ~shell_path:"cmd.exe"
      ~command_text:"node -e \"console.log(1)\""
    = "cmd.exe /d /s /c \"node -e \\\"console.log(1)\\\"\"")

let test_shell_command_line_preserves_quoted_program_with_arguments () =
  assert (
    Windows_command_line.shell_command_line ~shell_path:"cmd.exe"
      ~command_text:
        "\"C:\\Program Files\\tool.cmd\" \"alpha beta\" plain"
    = "cmd.exe /d /s /c \"\\\"C:\\Program Files\\tool.cmd\\\" \
       \\\"alpha beta\\\" plain\"")

let () =
  test_quote_arg_preserves_simple_arguments ();
  test_quote_arg_quotes_spaces ();
  test_quote_arg_escapes_embedded_quotes ();
  test_quote_arg_doubles_trailing_backslashes ();
  test_shell_command_line_uses_cmd_flags ();
  test_shell_command_line_preserves_quoted_program_with_arguments ()
