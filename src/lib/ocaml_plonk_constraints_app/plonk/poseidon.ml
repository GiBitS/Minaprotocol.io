open Core
open Snarky
open Sponge
open Zexe_backend_common.Plonk_plookup_constraint_system

module Constraints
    (Intf : Snark_intf.Run with type prover_state = unit)
    (Params : sig val params : Intf.field Params.t end)
= struct
  open Intf

  let permute (start : Field.t array) rounds : Field.t array =
    let length = Array.length start in
    let state = exists 
        (Snarky.Typ.array ~length:Int.(rounds + 1) (Snarky.Typ.array length Field.typ)) 
        ~compute:As_prover.(fun () ->
            (
              let state = Array.create Int.(rounds + 1) (Array.create length zero) in
              state.(0) <- Array.map ~f:(fun x -> read_var x) start;
              for i = 1 to rounds do
                state.(i) <- Array.map ~f:(fun x -> (let sq = square x in (square sq) * sq * x)) state.(Int.(i-1));
                state.(i) <- Array.map
                    ~f:(fun p -> Array.fold2_exn p state.(i) ~init:Field.Constant.zero ~f:(fun c a b -> a * b + c))
                    Params.params.mds;
                for j = 0 to Int.(length - 1) do
                  state.(i).(j) <- state.(i).(j) + Params.params.round_constants.(Int.(i - 1)).(j)
                done;
              done;
              state
            ))
    in
    state.(0) <- start;
    Intf.assert_
      [{
        basic= Plonk_constraint.T (Poseidon { state }) ;
        annotation= Some "plonk-poseidon"
      }];
    state.(rounds)

  let poseidon_block_cipher (start : Field.t array) : Field.t array =
    permute start 31
end

module ArithmeticSponge
    (Intf : Snark_intf.Run with type prover_state = unit)
    (Params : sig val params : Intf.field Params.t end)
= struct
  open Intf

  type sponge_state = Absorbed of int | Squeezed of int [@@deriving sexp]

  let state = Array.init 5 ~f:(fun _ -> Field.zero)

  let absorb (start : Field.t array) = ()

  let squeze (start : Field.t array) = ()
end
