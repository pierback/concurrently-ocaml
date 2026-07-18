type delivery = Succeeded | Failed

type action = Do_nothing | Kill_now | Kill_after of float

val after_signal :
  Run_policy.t -> delivery -> signal:int -> action
