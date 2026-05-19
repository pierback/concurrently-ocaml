module Close_event = Concurrentlyocaml.Close_event
module Process_signal = Concurrentlyocaml.Process_signal
module Run_policy = Concurrentlyocaml.Run_policy

let test_known_signal_numbers_and_labels () =
  assert (Process_signal.number Run_policy.Sigterm = Ok Sys.sigterm);
  assert (Process_signal.number Run_policy.Sigkill = Ok Sys.sigkill);
  assert (
    Process_signal.number (Run_policy.Named_signal "hup")
    = Error (`Unsupported_kill_signal "hup"));
  assert (
    Process_signal.number (Run_policy.Named_signal "SIGQUIT")
    = Ok Sys.sigquit);
  assert (
    Process_signal.number (Run_policy.Named_signal "iOt")
    = Error (`Unsupported_kill_signal "iOt"));
  assert (
    Process_signal.number (Run_policy.Named_signal "SIGUSR1") = Ok Sys.sigusr1);
  assert (
    Process_signal.number (Run_policy.Named_signal "sigusr1")
    = Error (`Unsupported_kill_signal "sigusr1"));
  assert (
    Process_signal.number (Run_policy.Named_signal "unsupported")
    = Error (`Unsupported_kill_signal "unsupported"));
  assert (Process_signal.kill_label Run_policy.Sigterm = "SIGTERM");
  assert (Process_signal.kill_label (Run_policy.Named_signal "term") = "term")

let test_exit_status_labels () =
  assert (Process_signal.exit_status_label (Close_event.Exited 3) = "3");
  assert (
    Process_signal.exit_status_label
      (Close_event.Signaled (string_of_int Sys.sigterm))
    = "SIGTERM");
  assert (
    Process_signal.exit_status_label (Close_event.Signaled "sigusr2")
    = "SIGUSR2");
  assert (
    Process_signal.exit_status_label
      (Close_event.Signaled (string_of_int Sys.sigquit))
    = "SIGQUIT");
  assert (Process_signal.exit_status_label (Close_event.Signaled "3") = "SIGQUIT");
  assert (
    Process_signal.exit_status_label (Close_event.Spawn_error "missing")
    = "missing")

let () =
  test_known_signal_numbers_and_labels ();
  test_exit_status_labels ()
