val read :
  source:Runner_backend.source ->
  router:Input_router.t ->
  write_input:(Input_router.route -> unit) ->
  close_running_stdins:(unit -> unit) ->
  record_unexpected_error:(string -> unit) ->
  unit
