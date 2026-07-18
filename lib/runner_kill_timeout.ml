type delivery = Succeeded | Failed

type action = Do_nothing | Kill_now | Kill_after of float

let after_signal policy delivery ~signal =
  if signal = Sys.sigkill then
    match delivery with
    | Succeeded -> Do_nothing
    | Failed -> Kill_now
  else
    match Run_policy.kill_timeout_ms policy with
    | Some 0 | None -> (
        match delivery with
        | Succeeded -> Do_nothing
        | Failed -> Kill_now)
    | Some timeout_ms ->
        Kill_after (float_of_int (max 1 timeout_ms) /. 1000.0)
