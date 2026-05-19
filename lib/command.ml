type t =
  { index : int
  ; text : string
  ; name : string option
  ; cwd : string option
  ; env : (string * string) list
  ; prefix_color : string option
  ; raw : bool
  ; hidden : bool
  ; ipc : bool
  }

type create_error =
  [ `Empty_command
  | `Empty_cwd
  | `Negative_index
  ]

let create ?name ?cwd ?(env = []) ?prefix_color ?(raw = false) ?(hidden = false)
    ?(ipc = false) ?(allow_empty = false) ~index text =
  if index < 0 then Error `Negative_index
  else if (not allow_empty) && String.trim text = "" then Error `Empty_command
  else
    (match cwd with
     | Some cwd when String.trim cwd = "" -> Error `Empty_cwd
     | Some _ | None ->
       Ok
         { index
         ; text
         ; name
         ; cwd
         ; env
         ; prefix_color
         ; raw
         ; hidden
         ; ipc
         })

let index t = t.index
let text t = t.text
let name t = t.name
let cwd t = t.cwd
let env t = t.env
let prefix_color t = t.prefix_color
let raw t = t.raw
let hidden t = t.hidden
let ipc t = t.ipc

let equal left right =
  left.index = right.index
  && String.equal left.text right.text
  && left.name = right.name
  && left.cwd = right.cwd
  && left.env = right.env
  && left.prefix_color = right.prefix_color
  && left.raw = right.raw
  && left.hidden = right.hidden
  && left.ipc = right.ipc
