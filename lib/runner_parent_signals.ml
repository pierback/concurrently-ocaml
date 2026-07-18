type signal = { generation : int; number : int }

type t = {
  current : signal option ref;
  first_signal : int option ref;
  serializer : (unit -> unit) Reentrant_serializer.t;
}

type 'a outcome = [ `Completed of 'a | `Interrupted of int * 'a ]

let current t = !(t.current)
let serialize t callback = Reentrant_serializer.submit t.serializer callback

let protect ~on_signal run =
  let t =
    {
      current = ref None;
      first_signal = ref None;
      serializer =
        Reentrant_serializer.create ~handle:(fun callback -> callback ());
    }
  in
  let previous_handlers = ref [] in
  let restore_handlers () =
    List.iter
      (fun (signal, previous_handler) -> Sys.set_signal signal previous_handler)
      !previous_handlers
  in
  let handle number =
    if Option.is_none !(t.first_signal) then t.first_signal := Some number;
    let generation =
      match !(t.current) with
      | Some current -> current.generation + 1
      | None -> 1
    in
    let signal = { generation; number } in
    t.current := Some signal;
    on_signal signal
  in
  let install_signal_handler signal =
    let handle_signal () = handle signal in
    match
      Sys.signal signal
        (Sys.Signal_handle (fun _ -> serialize t handle_signal))
    with
    | previous_handler -> Some (signal, previous_handler)
    | exception Invalid_argument _ -> None
  in
  previous_handlers :=
    List.filter_map install_signal_handler
      [ Sys.sighup; Sys.sigint; Sys.sigterm ];
  let result = Fun.protect ~finally:restore_handlers (fun () -> run t) in
  match !(t.first_signal) with
  | None -> `Completed result
  | Some signal -> `Interrupted (signal, result)
