(*
 * This file has been generated by the OCamlClientCodegen generator for openapi-generator.
 *
 * Generated by: https://openapi-generator.tech
 *
 * Schema Account_balance_response.t : An AccountBalanceResponse is returned on the /account/balance endpoint. If an account has a balance for each AccountIdentifier describing it (ex: an ERC-20 token balance on a few smart contracts), an account balance request must be made with each AccountIdentifier. The `coins` field was removed and replaced by by `/account/coins` in `v1.4.7`.
 *)

type t =
  { block_identifier: Block_identifier.t
  ; (* A single account may have a balance in multiple currencies. *)
    balances: Amount.t list
  ; (* Account-based blockchains that utilize a nonce or sequence number should include that number in the metadata. This number could be unique to the identifier or global across the account address. *)
    metadata: Yojson.Safe.t option [@default None] }
[@@deriving yojson {strict= false}, show]

(** An AccountBalanceResponse is returned on the /account/balance endpoint. If an account has a balance for each AccountIdentifier describing it (ex: an ERC-20 token balance on a few smart contracts), an account balance request must be made with each AccountIdentifier. The `coins` field was removed and replaced by by `/account/coins` in `v1.4.7`. *)
let create (block_identifier : Block_identifier.t) (balances : Amount.t list) :
    t =
  {block_identifier; balances; metadata= None}
