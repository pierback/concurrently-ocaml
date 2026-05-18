val close_events_json : Close_event.t list -> string

val output_event_json : observed_at:float -> Output_event.t -> string option
