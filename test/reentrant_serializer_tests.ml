module Reentrant_serializer = Concurrentlyocaml.Reentrant_serializer

let require condition message = if not condition then failwith message

let require_values expected actual =
  require (expected = actual)
    (Printf.sprintf "expected [%s], got [%s]"
       (String.concat "; " expected)
       (String.concat "; " actual))

let serializer_ref_submit serializer value =
  match !serializer with
  | Some serializer -> Reentrant_serializer.submit serializer value
  | None -> failwith "serializer not initialized"

let test_nested_submissions_keep_ticket_order () =
  let seen = ref [] in
  let serializer = ref None in
  let handle value =
    seen := string_of_int value :: !seen;
    if value = 1 then (
      serializer_ref_submit serializer 2;
      serializer_ref_submit serializer 3)
    else if value = 2 then serializer_ref_submit serializer 4
  in
  serializer := Some (Reentrant_serializer.create ~handle);
  serializer_ref_submit serializer 1;
  require_values [ "1"; "2"; "3"; "4" ] (List.rev !seen)

let test_callback_failure_drains_nested_work_and_remains_reusable () =
  let exception First_callback_failure in
  let exception Nested_callback_failure in
  let seen = ref [] in
  let serializer = ref None in
  let handle value =
    seen := value :: !seen;
    match value with
    | "outer" ->
        serializer_ref_submit serializer "nested";
        raise First_callback_failure
    | "nested" -> raise Nested_callback_failure
    | _ -> ()
  in
  serializer := Some (Reentrant_serializer.create ~handle);
  (match serializer_ref_submit serializer "outer" with
  | () -> failwith "expected the first callback exception"
  | exception First_callback_failure -> ()
  | exception _ -> failwith "re-raised the wrong callback exception");
  require_values [ "outer"; "nested" ] (List.rev !seen);
  serializer_ref_submit serializer "after";
  require_values [ "outer"; "nested"; "after" ] (List.rev !seen)

let wait_until ~label flag =
  let deadline = Unix.gettimeofday () +. 5. in
  let rec wait () =
    if Atomic.get flag then ()
    else if Unix.gettimeofday () >= deadline then
      failwith ("timed out: " ^ label)
    else (
      Unix.sleepf 0.0001;
      wait ())
  in
  wait ()

let with_process_timeout seconds run =
  if Sys.win32 then run ()
  else
    let previous_handler =
      Sys.signal Sys.sigalrm
        (Sys.Signal_handle
           (fun _ ->
             prerr_endline "timed out: reentrant serializer test process";
             exit 2))
    in
    ignore (Unix.alarm seconds);
    Fun.protect
      ~finally:(fun () ->
        ignore (Unix.alarm 0);
        Sys.set_signal Sys.sigalrm previous_handler)
      run

let join_once domain joined =
  if not !joined then (
    joined := true;
    Domain.join domain)

let cleanup_domain ~open_gate domain joined =
  open_gate ();
  match join_once domain joined with () -> () | exception _ -> ()

let test_out_of_order_publication_preserves_ticket_order () =
  let first_in_publication_gap = Atomic.make false in
  let allow_first_publication = Atomic.make false in
  let seen = ref [] in
  let before_publish ticket =
    if ticket = 0 then (
      Atomic.set first_in_publication_gap true;
      wait_until ~label:"first publication release" allow_first_publication)
  in
  let serializer =
    Reentrant_serializer.For_testing.create ~before_publish
      ~handle:(fun value -> seen := value :: !seen)
      ()
  in
  let first =
    Domain.spawn (fun () -> Reentrant_serializer.submit serializer "first")
  in
  let first_joined = ref false in
  Fun.protect
    ~finally:(fun () ->
      cleanup_domain
        ~open_gate:(fun () -> Atomic.set allow_first_publication true)
        first first_joined)
    (fun () ->
      wait_until ~label:"first publication gap" first_in_publication_gap;
      Reentrant_serializer.submit serializer "second";
      require_values [] (List.rev !seen);
      Atomic.set allow_first_publication true;
      join_once first first_joined;
      require_values [ "first"; "second" ] (List.rev !seen))

let test_retiring_owner_reacquires_published_work () =
  let owner_before_release = Atomic.make false in
  let allow_owner_release = Atomic.make false in
  let block_release = Atomic.make true in
  let seen = ref [] in
  let before_release () =
    if Atomic.compare_and_set block_release true false then (
      Atomic.set owner_before_release true;
      wait_until ~label:"owner release" allow_owner_release)
  in
  let serializer =
    Reentrant_serializer.For_testing.create ~before_release
      ~handle:(fun value -> seen := value :: !seen)
      ()
  in
  let first =
    Domain.spawn (fun () -> Reentrant_serializer.submit serializer "first")
  in
  let first_joined = ref false in
  Fun.protect
    ~finally:(fun () ->
      cleanup_domain
        ~open_gate:(fun () -> Atomic.set allow_owner_release true)
        first first_joined)
    (fun () ->
      wait_until ~label:"owner before release" owner_before_release;
      Reentrant_serializer.submit serializer "second";
      require_values [ "first" ] (List.rev !seen);
      Atomic.set allow_owner_release true;
      join_once first first_joined;
      require_values [ "first"; "second" ] (List.rev !seen))

let () =
  with_process_timeout 15 (fun () ->
      test_nested_submissions_keep_ticket_order ();
      test_callback_failure_drains_nested_work_and_remains_reusable ();
      test_out_of_order_publication_preserves_ticket_order ();
      test_retiring_owner_reacquires_published_work ())
