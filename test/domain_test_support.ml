module Command = Concurrentlyocaml.Command
module Close_event = Concurrentlyocaml.Close_event

let ok = function Ok value -> value | Error _ -> assert false

let expect_error expected = function
  | Ok _ -> assert false
  | Error actual -> assert (actual = expected)

let command index text = ok (Command.create ~index text)

let close_event ?(attempt = 0) ?(killed = false)
    ?(status = Close_event.Exited 0) ?(started_at = 10.0) ?(ended_at = 12.5)
    command =
  ok
    (Close_event.create ~command ~attempt ~killed ~status ~started_at ~ended_at)
