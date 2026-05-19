module Command = Concurrentlyocaml.Command
module Input_router = Concurrentlyocaml.Input_router
module Runner_input_reader = Concurrentlyocaml.Runner_input_reader

let ok = function Ok value -> value | Error _ -> assert false

let test_routes_read_chunks_without_line_splitting () =
  Eio_main.run @@ fun _env ->
  let commands =
    [
      ok (Command.create ~index:0 ~name:"api" "npm run api");
      ok (Command.create ~index:1 ~name:"worker" "npm run worker");
    ]
  in
  let router =
    ok (Input_router.create ~commands ~default_input_target:"worker")
  in
  let writes = ref [] in
  let closed = ref false in
  let errors = ref [] in
  Runner_input_reader.read
    ~source:(Eio.Flow.string_source "api:reload\nplain")
    ~router
    ~write_input:(fun route -> writes := route :: !writes)
    ~close_running_stdins:(fun () -> closed := true)
    ~record_unexpected_error:(fun error -> errors := error :: !errors);
  assert !closed;
  assert (!errors = []);
  assert (
    List.rev !writes
    = [
        {
          Input_router.target_index = 0;
          target_label = "api";
          payload = "reload\nplain";
        };
      ])

let () = test_routes_read_chunks_without_line_splitting ()
