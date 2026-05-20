type chunk = {
  process_id : string option;
  stream : Output_event.stream;
  wall_time : float;
  text : string;
  line_terminated : bool;
}

type output_chunk = { text : string; line_terminated : bool }

type run = {
  process_id : string option;
  stream : Output_event.stream;
  wall_time : float;
  chunks : output_chunk list;
}

type command_buffer = { mutable chunks : chunk list }
type t = (int, command_buffer) Hashtbl.t

let create command_count =
  assert (command_count >= 0);
  Hashtbl.create command_count

let command_buffer t command_index =
  match Hashtbl.find_opt t command_index with
  | Some buffer -> buffer
  | None ->
      let buffer = { chunks = [] } in
      Hashtbl.add t command_index buffer;
      buffer

let append t ~command_index chunk =
  assert (command_index >= 0);
  let buffer = command_buffer t command_index in
  buffer.chunks <- chunk :: buffer.chunks

let last_chunk t ~command_index =
  assert (command_index >= 0);
  match Hashtbl.find_opt t command_index with
  | None -> None
  | Some buffer -> (
      match buffer.chunks with [] -> None | chunk :: _ -> Some chunk)

let same_run ~displayed_process_id (left : chunk) (right : chunk) =
  displayed_process_id left.process_id = displayed_process_id right.process_id
  && left.stream = right.stream

let run_of_chunks (chunks : chunk list) =
  match chunks with
  | [] -> invalid_arg "Output_buffer.run_of_chunks: empty chunk list"
  | first :: _ ->
      ({
         process_id = first.process_id;
         stream = first.stream;
         wall_time = first.wall_time;
         chunks =
           List.map
             (fun (chunk : chunk) ->
               ({
                  text = chunk.text;
                  line_terminated = chunk.line_terminated;
                }
                 : output_chunk))
             chunks;
       }
        : run)

let one_chunk_runs (chunks : chunk list) =
  List.map (fun chunk -> run_of_chunks [ chunk ]) chunks

let grouped_runs ~displayed_process_id (chunks : chunk list) =
  let flush current runs =
    match current with
    | [] -> runs
    | _ :: _ -> run_of_chunks (List.rev current) :: runs
  in
  let rec loop current runs = function
    | [] -> flush current runs |> List.rev
    | chunk :: rest -> (
        match current with
        | previous :: _ when same_run ~displayed_process_id previous chunk ->
            loop (chunk :: current) runs rest
        | _ :: _ ->
            let runs = flush current runs in
            loop [ chunk ] runs rest
        | [] -> loop [ chunk ] runs rest)
  in
  loop [] [] chunks

let drain_runs t ~command_index ~displayed_process_id ~split_chunks =
  assert (command_index >= 0);
  match Hashtbl.find_opt t command_index with
  | None -> []
  | Some buffer ->
      Hashtbl.remove t command_index;
      let chunks = List.rev buffer.chunks in
      if split_chunks then one_chunk_runs chunks
      else grouped_runs ~displayed_process_id chunks
