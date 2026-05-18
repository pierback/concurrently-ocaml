[@@@alert "-unstable"]

module Fork_action = Eio_unix.Private.Fork_action

external action_setsid : unit -> Fork_action.fork_fn
  = "concurrently_fork_action_setsid"

let action_setsid = action_setsid ()

let start_new_session =
  { Fork_action.run = (fun k -> k (Obj.repr (action_setsid, ()))) }

let signal_group ~pid signal =
  try
    Unix.kill (-pid) signal;
    Ok true
  with
  | Unix.Unix_error (Unix.ESRCH, _function_name, _argument) ->
    Ok false
  | Unix.Unix_error (error, function_name, argument) ->
    Error (Unix.error_message error ^ ": " ^ function_name ^ " " ^ argument)
