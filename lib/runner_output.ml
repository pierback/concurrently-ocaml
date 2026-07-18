type warning = Restart_delay | Kill_timeout

type t = {
  on_output_event : Output_event.t -> unit;
  invalid_event : string -> Output_event.create_error -> exn;
  mutex : Eio.Mutex.t;
  count : int ref;
  restart_delay_warning_emitted : bool ref;
  kill_timeout_warning_emitted : bool ref;
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
    restart_delay_warning_emitted = ref false;
    kill_timeout_warning_emitted = ref false;
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

let warning_message = function
  | Run_policy.Timeout_nan ->
      Printf.sprintf
        "(node:%d) TimeoutNaNWarning: NaN is not a number.\n\
         Timeout duration was set to 1.\n\
         (Use `node --trace-warnings ...` to show where the warning was \
         created)\n"
        (Unix.getpid ())
  | Run_policy.Timeout_negative value ->
      Printf.sprintf
        "(node:%d) TimeoutNegativeWarning: %s is a negative number.\n\
         Timeout duration was set to 1.\n\
         (Use `node --trace-warnings ...` to show where the warning was \
         created)\n"
        (Unix.getpid ()) value

let emitted_ref t = function
  | Restart_delay -> t.restart_delay_warning_emitted
  | Kill_timeout -> t.kill_timeout_warning_emitted

let warn_once t category warning =
  let emitted = emitted_ref t category in
  if not !emitted then (
    emitted := true;
    Output_event.runtime_warning ~stream:Output_event.Stderr
      ~chunk:(warning_message warning)
    |> emit_best_effort t)

let count t = !(t.count)
