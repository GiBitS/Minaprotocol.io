(* poseidon_hash.ml *)

[%%import
"/src/config.mlh"]

[%%ifdef
consensus_mechanism]

[%%error
"Client SDK cannot be built if \"consensus_mechanism\" is defined"]

[%%endif]

open Js_of_ocaml
module Hash = Random_oracle_nonconsensus.Random_oracle

let nybble_bits = function
  | 0x0 ->
      [false; false; false; false]
  | 0x1 ->
      [false; false; false; true]
  | 0x2 ->
      [false; false; true; false]
  | 0x3 ->
      [false; false; true; true]
  | 0x4 ->
      [false; true; false; false]
  | 0x5 ->
      [false; true; false; true]
  | 0x6 ->
      [false; true; true; false]
  | 0x7 ->
      [false; true; true; true]
  | 0x8 ->
      [true; false; false; false]
  | 0x9 ->
      [true; false; false; true]
  | 0xA ->
      [true; false; true; false]
  | 0xB ->
      [true; false; true; true]
  | 0xC ->
      [true; true; false; false]
  | 0xD ->
      [true; true; false; true]
  | 0xE ->
      [true; true; true; false]
  | 0xF ->
      [true; true; true; true]
  | _ ->
      failwith "nybble_bits: expected value from 0 to 0xF"

let char_bits c =
  let open Core_kernel in
  let n = Char.to_int c in
  let hi = Int.(shift_right (bit_and n 0xF0) 4) in
  let lo = Int.bit_and n 0x0F in
  List.concat_map [hi; lo] ~f:nybble_bits

let _ =
  Js.export "poseidon_hash"
    (object%js (_self)
       method hash input =
         let string_to_input s =
           let x =
             Stdlib.(Array.of_seq (Seq.map char_bits (String.to_seq s)))
           in
           Hash.Input.bitstrings x
         in
         let init = Hash.initial_state in
         let input =
           Js.to_string input |> string_to_input |> Hash.pack_input
         in
         let digest = Hash.hash ~init input in
         let open Snark_params_nonconsensus in
         Field.to_string digest |> Js.string
    end)
