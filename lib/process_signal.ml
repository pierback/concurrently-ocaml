type lookup_error = [ `Unsupported_kill_signal of string ]

type supported_signal = { aliases : string list; signal : int }

let supported_signals =
  [
    { aliases = [ "ABRT"; "SIGABRT"; "IOT"; "SIGIOT" ]; signal = Sys.sigabrt };
    { aliases = [ "ALRM"; "SIGALRM" ]; signal = Sys.sigalrm };
    { aliases = [ "BUS"; "SIGBUS" ]; signal = Sys.sigbus };
    { aliases = [ "CHLD"; "SIGCHLD" ]; signal = Sys.sigchld };
    { aliases = [ "CONT"; "SIGCONT" ]; signal = Sys.sigcont };
    { aliases = [ "FPE"; "SIGFPE" ]; signal = Sys.sigfpe };
    { aliases = [ "HUP"; "SIGHUP" ]; signal = Sys.sighup };
    { aliases = [ "ILL"; "SIGILL" ]; signal = Sys.sigill };
    { aliases = [ "INT"; "SIGINT" ]; signal = Sys.sigint };
    { aliases = [ "IO"; "SIGIO" ]; signal = Sys.sigio };
    { aliases = [ "KILL"; "SIGKILL" ]; signal = Sys.sigkill };
    { aliases = [ "PIPE"; "SIGPIPE" ]; signal = Sys.sigpipe };
    { aliases = [ "PROF"; "SIGPROF" ]; signal = Sys.sigprof };
    { aliases = [ "QUIT"; "SIGQUIT" ]; signal = Sys.sigquit };
    { aliases = [ "SEGV"; "SIGSEGV" ]; signal = Sys.sigsegv };
    { aliases = [ "STOP"; "SIGSTOP" ]; signal = Sys.sigstop };
    { aliases = [ "SYS"; "SIGSYS" ]; signal = Sys.sigsys };
    { aliases = [ "TERM"; "SIGTERM" ]; signal = Sys.sigterm };
    { aliases = [ "TRAP"; "SIGTRAP" ]; signal = Sys.sigtrap };
    { aliases = [ "TSTP"; "SIGTSTP" ]; signal = Sys.sigtstp };
    { aliases = [ "TTIN"; "SIGTTIN" ]; signal = Sys.sigttin };
    { aliases = [ "TTOU"; "SIGTTOU" ]; signal = Sys.sigttou };
    { aliases = [ "URG"; "SIGURG" ]; signal = Sys.sigurg };
    { aliases = [ "USR1"; "SIGUSR1" ]; signal = Sys.sigusr1 };
    { aliases = [ "USR2"; "SIGUSR2" ]; signal = Sys.sigusr2 };
    { aliases = [ "VTALRM"; "SIGVTALRM" ]; signal = Sys.sigvtalrm };
    { aliases = [ "WINCH"; "SIGWINCH" ]; signal = Sys.sigwinch };
    { aliases = [ "XCPU"; "SIGXCPU" ]; signal = Sys.sigxcpu };
    { aliases = [ "XFSZ"; "SIGXFSZ" ]; signal = Sys.sigxfsz };
  ]

let normalize_signal_name signal = String.uppercase_ascii (String.trim signal)

let signal_name_matches signal supported_signal =
  List.mem signal supported_signal.aliases

let signal_name_is_full signal =
  String.length signal >= 3 && String.sub signal 0 3 = "SIG"

let signal_number_matches signal_number supported_signal =
  supported_signal.signal = signal_number
  ||
  let host_signal_number = Sys.signal_to_int supported_signal.signal in
  host_signal_number > 0 && host_signal_number = signal_number

let signal_label signal =
  supported_signals
  |> List.find_opt (signal_number_matches signal)
  |> Option.map (fun supported_signal ->
         Sys.signal_to_string supported_signal.signal)

let number = function
  | Run_policy.Sigterm -> Ok Sys.sigterm
  | Run_policy.Sigkill -> Ok Sys.sigkill
  | Run_policy.Named_signal signal -> (
      let signal = String.trim signal in
      if not (signal_name_is_full signal) then
        Error (`Unsupported_kill_signal signal)
      else
        match List.find_opt (signal_name_matches signal) supported_signals with
        | Some supported_signal -> Ok supported_signal.signal
        | None -> Error (`Unsupported_kill_signal signal))

let unknown_signal_error_message signal =
  Printf.sprintf "TypeError [ERR_UNKNOWN_SIGNAL]: Unknown signal: %s" signal

let kill_label = function
  | Run_policy.Sigterm -> "SIGTERM"
  | Run_policy.Sigkill -> "SIGKILL"
  | Run_policy.Named_signal signal ->
      let signal = String.trim signal in
      assert (signal <> "");
      signal

let label signal =
  match int_of_string_opt (String.trim signal) with
  | Some signal_number -> (
      match signal_label signal_number with
      | Some label -> label
      | None -> signal)
  | None ->
      let signal = normalize_signal_name signal in
      if String.length signal >= 3 && String.sub signal 0 3 = "SIG" then signal
      else signal

let exit_status_label = function
  | Close_event.Exited code -> string_of_int code
  | Close_event.Signaled signal -> label signal
  | Close_event.Spawn_error message -> message
