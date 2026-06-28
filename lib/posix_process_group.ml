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

let group_exists ~pid =
  try
    Unix.kill (-pid) 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _function_name, _argument) -> false
  | Unix.Unix_error (Unix.EPERM, _function_name, _argument) -> true
  | Unix.Unix_error (_error, _function_name, _argument) -> true
