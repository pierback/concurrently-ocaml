module Output_timing = Concurrentlyocaml.Output_timing

let starts_with ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let test_duration_rounds_to_milliseconds () =
  assert (Output_timing.duration_ms 1.2344 = 1234);
  assert (Output_timing.duration_ms 1.2345 = 1235)

let test_summary_lines_sort_by_duration () =
  let lines =
    Output_timing.summary_lines ~command_count:2
      [
        {
          Output_timing.command_index = 0;
          name = "api";
          duration_ms = 10;
          exit_code = "0";
          killed = false;
          command_text = "npm run api";
        };
        {
          Output_timing.command_index = 1;
          name = "worker";
          duration_ms = 20;
          exit_code = "1";
          killed = true;
          command_text = "npm run worker";
        };
      ]
  in
  assert (List.hd lines = "Timings:");
  assert (List.exists (starts_with ~prefix:"┌") lines);
  assert (
    List.exists
      (fun line -> String.contains line 'w' && String.contains line '2')
      lines)

let test_summary_waits_for_all_commands () =
  let lines =
    Output_timing.summary_lines ~command_count:2
      [
        {
          Output_timing.command_index = 0;
          name = "api";
          duration_ms = 10;
          exit_code = "0";
          killed = false;
          command_text = "npm run api";
        };
      ]
  in
  assert (lines = [])

let () =
  test_duration_rounds_to_milliseconds ();
  test_summary_lines_sort_by_duration ();
  test_summary_waits_for_all_commands ()
