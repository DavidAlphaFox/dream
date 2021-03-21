(* This file is part of Dream, released under the MIT license. See
   LICENSE.md for details, or visit https://github.com/aantron/dream.

   Copyright 2021 Anton Bachin *)



type bigstring = Lwt_bytes.t

type stream =
  (bigstring -> int -> int -> unit) ->
  (unit -> unit) ->
    unit

type body = [
  | `Empty
  | `String of string
  | `Stream of stream
]

type body_cell =
  body ref

let has_body body_cell =
  match !body_cell with
  | `Empty -> false
  | `String "" -> false
  | `String _ -> true
  | _ -> true

let buffer_body body_cell =
  match !body_cell with
  | `Empty
  | `String _ -> Lwt.return_unit

  | `Stream stream ->
    let on_finished, finished = Lwt.wait () in

    let length = ref 0 in
    let buffer = ref (Lwt_bytes.create 4096) in

    let eof () =
      if !length = 0 then
        body_cell := `Empty
      else
        body_cell :=
          `String (Lwt_bytes.to_string (Lwt_bytes.proxy !buffer 0 !length));

      Lwt.wakeup_later finished ()
    in

    let data chunk offset chunk_length =
      let new_length = !length + chunk_length in

      if new_length > Lwt_bytes.length !buffer then begin
        let new_buffer = Lwt_bytes.create (new_length * 2) in
        Lwt_bytes.blit !buffer 0 new_buffer 0 !length;
        buffer := new_buffer
      end;

      Lwt_bytes.blit chunk offset !buffer !length chunk_length;
      length := new_length
    in

    stream data eof;

    on_finished

let body body_cell =
  buffer_body body_cell
  |> Lwt.map (fun () ->
    match !body_cell with
    | `Empty -> ""
    | `String body -> body
    | `Stream _ -> assert false)

let body_stream body_cell =
  match !body_cell with
  | `Empty ->
    Lwt.return_none

  | `String body ->
    body_cell := `Empty;
    Lwt.return (Some body)

  | `Stream stream ->
    let promise, resolver = Lwt.wait () in

    stream
      (fun data offset length ->
        Some (Lwt_bytes.to_string (Lwt_bytes.proxy data offset length))
        |> Lwt.wakeup_later resolver)
      (fun () ->
        body_cell := `Empty;
        Lwt.wakeup_later resolver None);

    promise

let body_stream_bigstring data eof body_cell =
  match !body_cell with
  | `Empty ->
    eof ()

  | `String body ->
    body_cell := `Empty;
    data (Lwt_bytes.of_string body) 0 (String.length body)

  (* TODO Is it possible to avoid the allocation by relying on the underlying
     stream to return EOF multiple times? If not, try partial application as a
     way to avoid allocation for a reader. *)
  | `Stream stream ->
    stream
      data
      (fun () ->
        body_cell := `Empty;
        eof ())