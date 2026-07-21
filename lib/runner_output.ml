type t = {
  on_output_event : Output_event.t -> unit;
  invalid_event : string -> Output_event.create_error -> exn;
  mutex : Eio.Mutex.t;
  count : int ref;
}

let create_error_message = function
  | `Invalid_next_attempt (attempt, next_attempt) ->
      Printf.sprintf "invalid next attempt %d for attempt %d" next_attempt
        attempt
  | `Negative_attempt -> "negative attempt"
  | `Negative_delay_ms -> "negative delay"

let create ~on_output_event ~invalid_event =
  {
    on_output_event;
    invalid_event;
    mutex = Eio.Mutex.create ();
    count = ref 0;
  }

let emit t event =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      incr t.count;
      t.on_output_event event)

let emit_best_effort t event =
  match emit t event with () -> () | exception _ -> ()

let lifecycle t ~command ~attempt lifecycle =
  match Output_event.lifecycle ~command ~attempt ~lifecycle with
  | Ok event -> emit t event
  | Error error -> raise (t.invalid_event "create_lifecycle_event" error)

let lifecycle_best_effort t ~command ~attempt event =
  match lifecycle t ~command ~attempt event with () -> () | exception _ -> ()

let lifecycle_with_process_id t ~process_id ~command ~attempt lifecycle =
  match
    Output_event.lifecycle_with_process_id ~process_id ~command ~attempt
      ~lifecycle
  with
  | Ok event -> emit t event
  | Error error ->
      raise
        (t.invalid_event "create_lifecycle_event_with_process_id" error)

let lifecycle_with_process_id_best_effort t ~process_id ~command ~attempt event =
  match
    lifecycle_with_process_id t ~process_id ~command ~attempt event
  with
  | () -> ()
  | exception _ -> ()

let output_chunk_best_effort t ~command ~attempt ~process_id ~stream ~chunk
    ~line_terminated =
  match
    Output_event.output_chunk ~command ~attempt ~process_id ~stream ~chunk
      ~line_terminated
  with
  | Ok event -> emit_best_effort t event
  | Error error -> raise (t.invalid_event "teardown_error_event" error)

let count t = !(t.count)
