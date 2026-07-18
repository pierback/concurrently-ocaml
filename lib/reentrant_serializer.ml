module Ticket_map = Map.Make (Int)

type 'a t = {
  handle : 'a -> unit;
  before_publish : (int -> unit) option;
  before_release : (unit -> unit) option;
  next_ticket : int Atomic.t;
  next_to_handle : int Atomic.t;
  pending : 'a Ticket_map.t Atomic.t;
  draining : bool Atomic.t;
}

type failure = { exception_ : exn; backtrace : Printexc.raw_backtrace }

let create_with_hooks ?before_publish ?before_release ~handle () =
  {
    handle;
    before_publish;
    before_release;
    next_ticket = Atomic.make 0;
    next_to_handle = Atomic.make 0;
    pending = Atomic.make Ticket_map.empty;
    draining = Atomic.make false;
  }

let create ~handle = create_with_hooks ~handle ()

let rec publish t ticket value =
  let pending = Atomic.get t.pending in
  let published = Ticket_map.add ticket value pending in
  if not (Atomic.compare_and_set t.pending pending published) then (
    Domain.cpu_relax ();
    publish t ticket value)

let rec take_next t =
  let pending = Atomic.get t.pending in
  let expected = Atomic.get t.next_to_handle in
  match Ticket_map.find_opt expected pending with
  | None -> None
  | Some value ->
      let remaining = Ticket_map.remove expected pending in
      if Atomic.compare_and_set t.pending pending remaining then (
        Atomic.set t.next_to_handle (expected + 1);
        Some value)
      else (
        Domain.cpu_relax ();
        take_next t)

let next_is_pending t =
  Ticket_map.mem (Atomic.get t.next_to_handle) (Atomic.get t.pending)

let remember_failure first_failure exception_ =
  match !first_failure with
  | Some _ -> ()
  | None ->
      first_failure :=
        Some { exception_; backtrace = Printexc.get_raw_backtrace () }

let handle t first_failure value =
  match t.handle value with
  | () -> ()
  | exception exception_ -> remember_failure first_failure exception_

let rec drain t first_failure =
  match take_next t with
  | Some value ->
      handle t first_failure value;
      drain t first_failure
  | None ->
      Option.iter (fun hook -> hook ()) t.before_release;
      Atomic.set t.draining false;
      if next_is_pending t && Atomic.compare_and_set t.draining false true then
        drain t first_failure

let raise_failure = function
  | None -> ()
  | Some failure ->
      Printexc.raise_with_backtrace failure.exception_ failure.backtrace

let handle_pending t =
  let first_failure = ref None in
  drain t first_failure;
  raise_failure !first_failure

let submit t value =
  let ticket = Atomic.fetch_and_add t.next_ticket 1 in
  Option.iter (fun hook -> hook ticket) t.before_publish;
  publish t ticket value;
  if Atomic.compare_and_set t.draining false true then
    handle_pending t

module For_testing = struct
  let create ?before_publish ?before_release ~handle () =
    create_with_hooks ?before_publish ?before_release ~handle ()
end
