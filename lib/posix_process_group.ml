[@@@alert "-unstable"]

let signal_group ~pid signal =
  try
    Unix.kill (-pid) signal;
    Ok true
  with
  | Unix.Unix_error (Unix.ESRCH, _function_name, _argument) ->
    Ok false
  | Unix.Unix_error (error, function_name, argument) ->
    Error (Unix.error_message error ^ ": " ^ function_name ^ " " ^ argument)
