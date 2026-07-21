module Close_event = Concurrentlyocaml.Close_event
module Run_policy = Concurrentlyocaml.Run_policy
module Run_result = Concurrentlyocaml.Run_result
module Run_spec = Concurrentlyocaml.Run_spec

open Domain_test_support

let test_run_result_validation () =
  let first_command = command 0 "echo ok" in
  let policy = Run_policy.default in
  let spec = ok (Run_spec.create ~commands:[ first_command ] ~policy) in
  let successful_close_event = close_event first_command in
  let result =
    ok
      (Run_result.create ~spec ~close_events:[ successful_close_event ]
         ~output_event_count:1)
  in
  assert (not (Run_result.interrupted result));
  assert (Run_result.exit_code result = 0);
  let interrupted_sigint_result =
    ok
      (Run_result.create_interrupted_by_signal ~signal:Sys.sigint ~spec
         ~close_events:[] ~output_event_count:0)
  in
  assert (Run_result.interrupted interrupted_sigint_result);
  assert (Run_result.exit_code interrupted_sigint_result = 0);
  let interrupted_sigterm_result =
    ok
      (Run_result.create_interrupted_by_signal ~signal:Sys.sigterm ~spec
         ~close_events:[] ~output_event_count:0)
  in
  assert (Run_result.exit_code interrupted_sigterm_result = 1);
  let interrupted_sigterm_success_result =
    ok
      (Run_result.create_interrupted_by_signal ~signal:Sys.sigterm ~spec
         ~close_events:[ successful_close_event ] ~output_event_count:0)
  in
  assert (Run_result.exit_code interrupted_sigterm_success_result = 0);
  expect_error `Missing_close_events
    (Run_result.create ~spec ~close_events:[] ~output_event_count:0);
  expect_error `Negative_output_event_count
    (Run_result.create ~spec ~close_events:[ successful_close_event ]
       ~output_event_count:(-1));
  expect_error `Too_many_close_events
    (Run_result.create ~spec
       ~close_events:[ successful_close_event; successful_close_event ]
       ~output_event_count:0);
  let unknown_close_event = close_event (command 1 "echo unknown") in
  expect_error (`Unknown_command_index 1)
    (Run_result.create ~spec ~close_events:[ unknown_close_event ]
       ~output_event_count:0);
  let unexpected_close_event = close_event (command 0 "echo foreign") in
  expect_error (`Unexpected_command 0)
    (Run_result.create ~spec ~close_events:[ unexpected_close_event ]
       ~output_event_count:0);
  let second_command = command 1 "echo second" in
  let two_command_spec =
    ok (Run_spec.create ~commands:[ first_command; second_command ] ~policy)
  in
  let first_retry = close_event ~attempt:1 first_command in
  expect_error `Missing_close_events
    (Run_result.create ~spec:two_command_spec
       ~close_events:[ successful_close_event ] ~output_event_count:0);
  expect_error
    (`Attempt_exceeds_restart_limit (0, 1))
    (Run_result.create ~spec:two_command_spec
       ~close_events:[ first_retry; close_event second_command ]
       ~output_event_count:0);
  let retry_policy =
    ok
      (Run_policy.create
         ~restart_limit:(Run_policy.Finite_restarts 1)
         ())
  in
  let retry_spec =
    ok (Run_spec.create ~commands:[ first_command ] ~policy:retry_policy)
  in
  let failed_first_attempt =
    close_event ~status:(Close_event.Exited 1) first_command
  in
  expect_error
    (`Incomplete_restart_attempt (0, 0))
    (Run_result.create ~spec:retry_spec ~close_events:[ failed_first_attempt ]
       ~output_event_count:0);
  let successful_retry = close_event ~attempt:1 first_command in
  expect_error
    (`Missing_close_event_attempt (0, 0))
    (Run_result.create ~spec:retry_spec ~close_events:[ successful_retry ]
       ~output_event_count:0);
  let large_retry_policy =
    ok
      (Run_policy.create
         ~restart_limit:(Run_policy.Finite_restarts 1_000_000)
         ())
  in
  let large_retry_spec =
    ok (Run_spec.create ~commands:[ first_command ] ~policy:large_retry_policy)
  in
  expect_error
    (`Missing_close_event_attempt (0, 0))
    (Run_result.create ~spec:large_retry_spec ~close_events:[ successful_retry ]
       ~output_event_count:0);
  let failed_after_success =
    close_event ~attempt:1 ~status:(Close_event.Exited 1) first_command
  in
  expect_error
    (`Attempt_after_success (0, 1))
    (Run_result.create ~spec:retry_spec
       ~close_events:[ failed_after_success; successful_close_event ]
       ~output_event_count:0);
  let retry_result =
    ok
      (Run_result.create ~spec:retry_spec
         ~close_events:[ successful_retry; failed_first_attempt ]
         ~output_event_count:0)
  in
  assert (Run_result.exit_code retry_result = 0);
  let infinite_policy =
    ok (Run_policy.create ~restart_limit:Run_policy.Infinite_restarts ())
  in
  let infinite_spec =
    ok (Run_spec.create ~commands:[ first_command ] ~policy:infinite_policy)
  in
  let late_success = close_event ~attempt:5 first_command in
  let infinite_result =
    ok
      (Run_result.create ~spec:infinite_spec ~close_events:[ late_success ]
         ~output_event_count:0)
  in
  assert (Run_result.close_events infinite_result = [ late_success ]);
  assert (Run_result.exit_code infinite_result = 0);
  let late_failure =
    close_event ~attempt:5 ~status:(Close_event.Exited 1) first_command
  in
  expect_error
    (`Incomplete_restart_attempt (0, 5))
    (Run_result.create ~spec:infinite_spec ~close_events:[ late_failure ]
       ~output_event_count:0);
  expect_error
    (`Duplicate_close_event_attempt (0, 0))
    (Run_result.create ~spec:retry_spec
       ~close_events:[ successful_close_event; successful_close_event ]
       ~output_event_count:0);
  let cancel_policy =
    ok (Run_policy.create ~kill_others_on:[ Run_policy.Success ] ())
  in
  let cancel_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:cancel_policy)
  in
  let cancelled_result =
    ok
      (Run_result.create ~spec:cancel_spec
         ~close_events:[ successful_close_event ] ~output_event_count:0)
  in
  assert (Run_result.exit_code cancelled_result = 0);
  let retry_cancel_policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~restart_limit:(Run_policy.Finite_restarts 1)
         ())
  in
  let retry_cancel_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:retry_cancel_policy)
  in
  let retryable_second_failure =
    close_event ~status:(Close_event.Exited 1) second_command
  in
  let retryable_sibling_cancelled_result =
    ok
      (Run_result.create ~spec:retry_cancel_spec
         ~close_events:[ retryable_second_failure; successful_close_event ]
         ~output_event_count:0)
  in
  assert (Run_result.exit_code retryable_sibling_cancelled_result = 0);
  let completed_second_failure =
    close_event ~attempt:1 ~status:(Close_event.Exited 1) second_command
  in
  let completed_failure_before_cancel_result =
    ok
      (Run_result.create ~spec:retry_cancel_spec
         ~close_events:
           [
             retryable_second_failure;
             completed_second_failure;
             successful_close_event;
           ]
         ~output_event_count:0)
  in
  assert (Run_result.exit_code completed_failure_before_cancel_result = 1);
  let killed_second_command =
    close_event ~killed:true ~status:(Close_event.Signaled "SIGTERM")
      second_command
  in
  let cleanly_cancelled_second_command =
    close_event ~killed:true ~status:(Close_event.Exited 0) second_command
  in
  let killed_sibling_result =
    ok
      (Run_result.create ~spec:cancel_spec
         ~close_events:[ successful_close_event; killed_second_command ]
         ~output_event_count:0)
  in
  assert (Run_result.exit_code killed_sibling_result = 1);
  let cleanly_cancelled_sibling_result =
    ok
      (Run_result.create ~spec:cancel_spec
         ~close_events:[ successful_close_event; cleanly_cancelled_second_command ]
         ~output_event_count:0)
  in
  assert (Run_result.exit_code cleanly_cancelled_sibling_result = 0);
  let require_second_after_first_cancels_policy =
    ok
      (Run_policy.create ~kill_others_on:[ Run_policy.Success ]
         ~success_condition:(Run_policy.Commands [ 1 ]) ())
  in
  let require_second_after_first_cancels_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:require_second_after_first_cancels_policy)
  in
  let required_sibling_killed_result =
    ok
      (Run_result.create ~spec:require_second_after_first_cancels_spec
         ~close_events:[ successful_close_event; killed_second_command ]
         ~output_event_count:0)
  in
  assert (Run_result.exit_code required_sibling_killed_result = 1);
  let kill_on_failure_policy =
    ok (Run_policy.create ~kill_others_on:[ Run_policy.Failure ] ())
  in
  let kill_on_failure_spec =
    ok
      (Run_spec.create
         ~commands:[ first_command; second_command ]
         ~policy:kill_on_failure_policy)
  in
  expect_error `Missing_close_events
    (Run_result.create ~spec:kill_on_failure_spec
       ~close_events:[ successful_close_event ] ~output_event_count:0);
  let failed_close_event =
    close_event ~status:(Close_event.Exited 1) first_command
  in
  let failed_cancelled_result =
    ok
      (Run_result.create ~spec:kill_on_failure_spec
         ~close_events:[ failed_close_event ] ~output_event_count:0)
  in
  assert (Run_result.exit_code failed_cancelled_result = 1);
  let killed_after_failure_result =
    ok
      (Run_result.create ~spec:kill_on_failure_spec
         ~close_events:[ failed_close_event; killed_second_command ]
         ~output_event_count:0)
  in
  assert (Run_result.exit_code killed_after_failure_result = 1)

let test_close_event_validation () =
  let command = command 0 "echo ok" in
  expect_error `Negative_exit_code
    (Close_event.create ~command ~attempt:0 ~killed:false
       ~status:(Close_event.Exited (-1)) ~started_at:0.0 ~ended_at:1.0);
  expect_error `Empty_signal
    (Close_event.create ~command ~attempt:0 ~killed:false
       ~status:(Close_event.Signaled " ") ~started_at:0.0 ~ended_at:1.0)

let run () =
  test_run_result_validation ();
  test_close_event_validation ()
