val quote_arg : string -> string
(** Quote one argument using the Windows command-line escaping rules used by
    [CommandLineToArgvW]. *)

val shell_command_line : shell_path:string -> command_text:string -> string
(** Command line for running [command_text] through [cmd.exe]. *)
