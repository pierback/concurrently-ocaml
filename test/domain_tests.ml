let () =
  Domain_contract_tests.run ();
  Output_formatter_integration_tests.run ();
  Run_result_contract_tests.run ();
  Cli_config_contract_tests.run ();
  Runner_fault_tests.run_backend_boundary ();
  Runner_teardown_tests.run_lifecycle_and_signal_races ();
  Runner_fault_tests.run_spawn_failures ();
  Runner_teardown_tests.run_failure_paths ();
  Runner_fault_tests.run_output_failures ();
  Runner_termination_tests.run_parent_signal_contracts ();
  Runner_execution_tests.run_execution_and_restart_contracts ();
  Runner_termination_tests.run_shutdown_contracts ();
  Runner_execution_tests.run_shell_contract ();
  print_endline "domain tests ok"
