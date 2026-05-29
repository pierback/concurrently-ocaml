module Command = Concurrentlyocaml.Command
module Output_prefix = Concurrentlyocaml.Output_prefix

let ok = function Ok value -> value | Error _ -> assert false

let test_labels_prefix_modes () =
  let command = ok (Command.create ~index:2 ~name:"api" "abcdefghij") in
  let options =
    {
      Output_prefix.prefix_length = 6.0;
      index_labels = None;
      pad_prefix = false;
      timestamp_format = "SSS";
    }
  in
  let label mode =
    Output_prefix.label_for_command ~wall_time:0.123 ~process_id:(Some "pid")
      ~options ~mode ~labels:[| "0"; "1"; "two" |] ~width:None command
  in
  assert (label Output_prefix.Default = "api");
  assert (label Output_prefix.Index = "2");
  assert (label Output_prefix.Pid = "pid");
  assert (label Output_prefix.Name = "two");
  assert (label Output_prefix.Command = "ab..ij");
  assert (label Output_prefix.No_prefix = "");
  assert (label Output_prefix.Time = "123");
  assert (label (Output_prefix.Template "{pid}:{index}") = "pid:2");
  assert (label (Output_prefix.Template "{index}:{command}") = "2:ab..ij")

let test_process_id_display_key () =
  assert (
    Output_prefix.displayed_process_id Output_prefix.Pid (Some "42") = Some "42");
  assert (
    Output_prefix.displayed_process_id (Output_prefix.Template "{pid}:{name}")
      (Some "42")
    = Some "42");
  assert (
    Output_prefix.displayed_process_id Output_prefix.Default (Some "42") = None)

let () =
  test_labels_prefix_modes ();
  test_process_id_display_key ()
