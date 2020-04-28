(* genesis_ledger_helper.ml *)

(* for consensus nodes, read download ledger, proof, and constants from file, or
     download from S3
   for nonconsensus nodes, download genesis proof only; for native code, can
     load from file or S3; for Javascript code, load only from S3
*)

[%%import
"/src/config.mlh"]

[%%ifdef
consensus_mechanism]

open Core
open Async

[%%else]

[%%if
ocaml_backend = "native"]

open Core
open Async

[%%elif
ocaml_backend = "js_of_ocaml"]

open Core_kernel
open Async_kernel

[%%else]

[%%error
"Unsupported OCaml backend"]

[%%endif]

module Coda_base = Coda_base_nonconsensus
module Cache_dir = Cache_dir_nonconsensus.Cache_dir

[%%endif]

type exn += Genesis_state_initialization_error

let s3_root = "https://s3-us-west-2.amazonaws.com/snark-keys.o1test.net/"

let proof_filename_root = "genesis_proof"

[%%if
ocaml_backend = "native"]

let copy_file ~logger ~filename ~genesis_dir ~src_dir ~extract_target =
  let source_file = src_dir ^ "/" ^ filename ^ "." ^ genesis_dir in
  let target_file = extract_target ^ "/" ^ filename in
  match%map
    Monitor.try_with_or_error (fun () ->
        let%map _result =
          Process.run_exn ~prog:"cp" ~args:[source_file; target_file] ()
        in
        () )
  with
  | Ok () ->
      Logger.info ~module_:__MODULE__ ~location:__LOC__ logger
        "Found $source_file and copied it to $target_file"
        ~metadata:
          [ ("source_file", `String source_file)
          ; ("target_file", `String target_file) ]
  | Error e ->
      Logger.debug ~module_:__MODULE__ ~location:__LOC__ logger
        "Error copying genesis $filename: $error"
        ~metadata:
          [ ("filename", `String filename)
          ; ("error", `String (Error.to_string_hum e)) ]

[%%endif]

[%%ifdef
consensus_mechanism]

open Coda_base

let constants_filename_root = "genesis_constants.json"

let load_genesis_constants (module M : Genesis_constants.Config_intf) ~path
    ~default ~logger =
  let config_res =
    Result.bind
      ( Result.try_with (fun () -> Yojson.Safe.from_file path)
      |> Result.map_error ~f:Exn.to_string )
      ~f:(fun json -> M.of_yojson json)
  in
  match config_res with
  | Ok config ->
      let new_constants =
        M.to_genesis_constants ~default:Genesis_constants.compiled config
      in
      Logger.debug ~module_:__MODULE__ ~location:__LOC__ logger
        "Overriding genesis constants $genesis_constants with the constants \
         $config_constants at $path. The new genesis constants are: \
         $new_genesis_constants"
        ~metadata:
          [ ("genesis_constants", Genesis_constants.(to_yojson default))
          ; ("new_genesis_constants", Genesis_constants.to_yojson new_constants)
          ; ("config_constants", M.to_yojson config)
          ; ("path", `String path) ] ;
      new_constants
  | Error s ->
      Logger.fatal ~module_:__MODULE__ ~location:__LOC__ logger
        "Error loading genesis constants from $path: $error. Sample data: \
         $sample_data"
        ~metadata:
          [ ("path", `String path)
          ; ("error", `String s)
          ; ( "sample_data"
            , M.of_genesis_constants Genesis_constants.compiled |> M.to_yojson
            ) ] ;
      raise Genesis_state_initialization_error

let retrieve_genesis_state dir_opt ~logger ~conf_dir ~daemon_conf :
    (Ledger.t lazy_t * Proof.t * Genesis_constants.t) Deferred.t =
  let open Cache_dir in
  let genesis_dir = Cache_dir.genesis_dir_name Genesis_constants.compiled in
  let tar_filename = genesis_dir ^ ".tar.gz" in
  let proof_filename = proof_filename_root ^ "." ^ genesis_dir in
  let constants_filename = constants_filename_root ^ "." ^ genesis_dir in
  Logger.info logger ~module_:__MODULE__ ~location:__LOC__
    "Looking for the genesis ledger $ledger, proof $proof, and constants \
     $constants files"
    ~metadata:
      [ ("ledger", `String tar_filename)
      ; ("proof", `String proof_filename)
      ; ("constants", `String constants_filename) ] ;
  let s3_bucket_prefix = s3_root ^ tar_filename in
  let extract_tar_file ~tar_dir ~extract_target =
    match%map
      Monitor.try_with_or_error ~extract_exn:true (fun () ->
          (* Delete any old genesis state *)
          let%bind () =
            File_system.remove_dir (conf_dir ^/ "coda_genesis_*")
          in
          (* Look for the tar and extract *)
          let tar_file = tar_dir ^/ genesis_dir ^ ".tar.gz" in
          let%map _result =
            Process.run_exn ~prog:"tar"
              ~args:["-C"; conf_dir; "-xzf"; tar_file]
              ()
          in
          () )
    with
    | Ok () ->
        Logger.info ~module_:__MODULE__ ~location:__LOC__ logger
          "Found genesis ledger tar file at $source and extracted it to $path"
          ~metadata:
            [("source", `String tar_dir); ("path", `String extract_target)]
    | Error e ->
        Logger.debug ~module_:__MODULE__ ~location:__LOC__ logger
          "Error extracting genesis ledger: $error"
          ~metadata:[("error", `String (Error.to_string_hum e))]
  in
  let retrieve_genesis_data tar_dir =
    Logger.debug ~module_:__MODULE__ ~location:__LOC__ logger
      "Retrieving genesis ledger, proof, and constants from $path"
      ~metadata:[("path", `String tar_dir)] ;
    let ledger_subdir = "ledger" in
    let extract_target = conf_dir ^/ genesis_dir in
    let%bind () = extract_tar_file ~tar_dir ~extract_target in
    let%bind () =
      copy_file ~logger ~filename:proof_filename_root ~genesis_dir
        ~src_dir:tar_dir ~extract_target
    in
    let%bind () =
      copy_file ~logger ~filename:constants_filename_root ~genesis_dir
        ~src_dir:tar_dir ~extract_target
    in
    let ledger_dir = extract_target ^/ ledger_subdir in
    let proof_file = extract_target ^/ proof_filename_root in
    let constants_file = extract_target ^/ constants_filename_root in
    if
      Core.Sys.(
        file_exists ledger_dir = `Yes
        && file_exists proof_file = `Yes
        && file_exists constants_file = `Yes)
    then (
      let genesis_ledger =
        let ledger = lazy (Ledger.create ~directory_name:ledger_dir ()) in
        match Or_error.try_with (fun () -> Lazy.force ledger |> ignore) with
        | Ok _ ->
            ledger
        | Error e ->
            Logger.fatal ~module_:__MODULE__ ~location:__LOC__ logger
              "Error loading the genesis ledger from $dir: $error"
              ~metadata:
                [ ("dir", `String ledger_dir)
                ; ("error", `String (Error.to_string_hum e)) ] ;
            raise Genesis_state_initialization_error
      in
      Logger.info ~module_:__MODULE__ ~location:__LOC__ logger
        "Successfully retrieved genesis ledger from $path"
        ~metadata:[("path", `String tar_dir)] ;
      let genesis_constants =
        load_genesis_constants
          (module Genesis_constants.Config_file)
          ~default:Genesis_constants.compiled ~path:constants_file ~logger
      in
      let%map base_proof =
        match%map
          Monitor.try_with_or_error ~extract_exn:true (fun () ->
              let%bind r = Reader.open_file proof_file in
              let%map contents =
                Pipe.to_list (Reader.lines r) >>| String.concat
              in
              Sexp.of_string contents |> Proof.t_of_sexp )
        with
        | Ok base_proof ->
            base_proof
        | Error e ->
            Logger.fatal ~module_:__MODULE__ ~location:__LOC__ logger
              "Error reading the base proof from $file: $error"
              ~metadata:
                [ ("file", `String proof_file)
                ; ("error", `String (Error.to_string_hum e)) ] ;
            raise Genesis_state_initialization_error
      in
      Logger.info ~module_:__MODULE__ ~location:__LOC__ logger
        "Successfully retrieved genesis ledger, proof, and constants from $path"
        ~metadata:[("path", `String tar_dir)] ;
      Some (genesis_ledger, base_proof, genesis_constants) )
    else (
      Logger.debug ~module_:__MODULE__ ~location:__LOC__ logger
        "Did not find genesis ledger, proof, and constants at $path"
        ~metadata:[("path", `String tar_dir)] ;
      Deferred.return None )
  in
  let res_or_fail dir_str = function
    | Some ((ledger, proof, constants) as res) ->
        (* Replace runtime-configurable constants from the daemon, if any *)
        Option.value_map daemon_conf ~default:res ~f:(fun daemon_config_file ->
            let new_constants =
              load_genesis_constants
                (module Genesis_constants.Daemon_config)
                ~default:constants ~path:daemon_config_file ~logger
            in
            (ledger, proof, new_constants) )
    | None ->
        Logger.fatal ~module_:__MODULE__ ~location:__LOC__ logger
          "Could not retrieve genesis ledger, genesis proof, and genesis \
           constants from paths $paths"
          ~metadata:[("paths", `String dir_str)] ;
        raise Genesis_state_initialization_error
  in
  match dir_opt with
  | Some dir ->
      let%map genesis_state_opt = retrieve_genesis_data dir in
      res_or_fail dir genesis_state_opt
  | None -> (
      let directories =
        [ autogen_path
        ; manual_install_path
        ; brew_install_path
        ; Cache_dir.s3_install_path ]
      in
      match%bind
        Deferred.List.fold directories ~init:None ~f:(fun acc dir ->
            if is_some acc then Deferred.return acc
            else
              match%map retrieve_genesis_data dir with
              | Some res ->
                  Some (res, dir)
              | None ->
                  None )
      with
      | Some (res, dir) ->
          Deferred.return (res_or_fail dir (Some res))
      | None ->
          (* Check if genesis data is in s3 *)
          let tgz_local_path = Cache_dir.s3_install_path ^/ tar_filename in
          let proof_local_path = Cache_dir.s3_install_path ^/ proof_filename in
          let constants_local_path =
            Cache_dir.s3_install_path ^/ constants_filename
          in
          let%bind () =
            match%map
              Cache_dir.load_from_s3 [s3_bucket_prefix]
                [tgz_local_path; proof_local_path; constants_local_path]
                ~logger
            with
            | Ok () ->
                ()
            | Error e ->
                Logger.fatal ~module_:__MODULE__ ~location:__LOC__ logger
                  "Could not download genesis ledger, proof, and constants \
                   from $uri: $error"
                  ~metadata:
                    [ ("uri", `String s3_bucket_prefix)
                    ; ("error", `String (Error.to_string_hum e)) ]
          in
          let%map res = retrieve_genesis_data Cache_dir.s3_install_path in
          res_or_fail
            (String.concat ~sep:"," (s3_bucket_prefix :: directories))
            res )

[%%else]

let download_proof_from_s3_exn ~logger =
  (* genesis_dir.ml is generated by building runtime_genesis_ledger, then
     running the script genesis_dir_for_nonconsensus.py
  *)
  let proof_filename = proof_filename_root ^ "." ^ Genesis_dir.genesis_dir in
  let proof_uri = s3_root ^ "/" ^ proof_filename in
  match%map Cache_dir.load_from_s3_to_strings [proof_uri] ~logger with
  | Ok [proof] ->
      proof
  | Ok _ ->
      (* we sent one URI, we expect one result *)
      failwith "Expected single result when downloading genesis proof"
  | Error e ->
      (* exn from Monitor.try_with *)
      Logger.fatal ~module_:__MODULE__ ~location:__LOC__ logger
        "Error when downloading genesis proof from $uri: $error"
        ~metadata:
          [("uri", `String proof_uri); ("error", `String (Exn.to_string e))] ;
      raise Genesis_state_initialization_error

[%%if
ocaml_backend = "js_of_ocaml"]

(* for Javascript, loading from S3 only, no disk I/O *)

let retrieve_genesis_proof ~logger : Proof.t Deferred.t =
  download_proof_from_s3_exn ~logger |> Sexp.of_string |> Proof.t_of_sexp

[%%else]

(* for native code, load from file or S3
   essentially the same as the consensus code, restricted to the proof;
    there are no daemon constants to override
*)

open Coda_base

let retrieve_genesis_proof dir_opt ~logger ~conf_dir : Proof.t Deferred.t =
  let genesis_dir = Genesis_dir.genesis_dir in
  let retrieve_genesis_data src_dir =
    Logger.debug ~module_:__MODULE__ ~location:__LOC__ logger
      "Retrieving genesis proof from $path"
      ~metadata:[("path", `String src_dir)] ;
    let extract_target = conf_dir ^/ genesis_dir in
    let%bind () =
      copy_file ~logger ~filename:proof_filename_root ~genesis_dir ~src_dir
        ~extract_target
    in
    let proof_file = extract_target ^/ proof_filename_root in
    if Core.Sys.(file_exists proof_file = `Yes) then (
      let%map base_proof =
        match%map
          Monitor.try_with_or_error ~extract_exn:true (fun () ->
              let%bind r = Reader.open_file proof_file in
              let%map contents =
                Pipe.to_list (Reader.lines r) >>| String.concat
              in
              Sexp.of_string contents |> Proof.t_of_sexp )
        with
        | Ok base_proof ->
            base_proof
        | Error e ->
            Logger.fatal ~module_:__MODULE__ ~location:__LOC__ logger
              "Error reading the base proof from $file: $error"
              ~metadata:
                [ ("file", `String proof_file)
                ; ("error", `String (Error.to_string_hum e)) ] ;
            raise Genesis_state_initialization_error
      in
      Logger.info ~module_:__MODULE__ ~location:__LOC__ logger
        "Successfully retrieved genesis proof from $path"
        ~metadata:[("path", `String src_dir)] ;
      Some base_proof )
    else (
      Logger.debug ~module_:__MODULE__ ~location:__LOC__ logger
        "Did not find genesis proof at $path"
        ~metadata:[("path", `String src_dir)] ;
      Deferred.return None )
  in
  (* download genesis proof from disk or s3 *)
  match dir_opt with
  | Some dir -> (
      match%map retrieve_genesis_data dir with
      | Some proof ->
          proof
      | None ->
          (* don't try to load from S3 here, since client intended
          to load from disk
      *)
          raise Genesis_state_initialization_error )
  | None -> (
      let directories =
        let open Cache_dir in
        [autogen_path; manual_install_path; brew_install_path; s3_install_path]
      in
      match%bind
        Deferred.List.fold directories ~init:None ~f:(fun acc dir ->
            if is_some acc then Deferred.return acc
            else retrieve_genesis_data dir )
      with
      | Some res ->
          return res
      | None ->
          let%map proof_str = download_proof_from_s3_exn ~logger in
          proof_str |> Sexp.of_string |> Proof.t_of_sexp )

[%%endif]

[%%endif]
