(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Callable = Interprocedural.Callable
open Core
open Pyre
open Taint

(* Registers the Taint analysis with the interprocedural analysis framework. *)
include Taint.Result.Register (struct
  include Taint.Result

  let init ~configuration ~scheduler ~environment ~functions ~stubs =
    let global_resolution = Analysis.TypeEnvironment.ReadOnly.global_resolution environment in
    let resolution =
      Analysis.TypeCheck.resolution
        global_resolution
        (* TODO(T65923817): Eliminate the need of creating a dummy context here *)
        (module Analysis.TypeCheck.DummyContext)
    in
    let models = Model.infer_class_models ~environment in
    let taint = Yojson.Safe.Util.member "taint" configuration in
    let json_bool_member key value ~default =
      Yojson.Safe.Util.member key value |> Yojson.Safe.Util.to_bool_option |> Option.value ~default
    in
    let verify = json_bool_member "verify_models" taint ~default:true in
    let find_missing_flows =
      Yojson.Safe.Util.member "find_missing_flows" taint
      |> Yojson.Safe.Util.to_string_option
      >>= TaintConfiguration.missing_flows_kind_from_string
    in
    let dump_model_query_results_path =
      Yojson.Safe.Util.member "dump_model_query_results_path" taint
      |> Yojson.Safe.Util.to_string_option
      >>| Path.create_absolute ~follow_symbolic_links:false
    in
    let rule_filter =
      if List.mem ~equal:String.equal (Yojson.Safe.Util.keys taint) "rule_filter" then
        Some
          ( Yojson.Safe.Util.member "rule_filter" taint
          |> Yojson.Safe.Util.to_list
          |> List.map ~f:Yojson.Safe.Util.to_int )
      else
        None
    in
    let create_models ~configuration sources =
      List.fold
        sources
        ~init:(models, [], Ast.Reference.Set.empty, [])
        ~f:(fun (models, errors, skip_overrides, queries) (path, source) ->
          let {
            ModelParser.T.models;
            errors = new_errors;
            skip_overrides = new_skip_overrides;
            queries = new_queries;
          }
            =
            ModelParser.parse ~resolution ~path ~source ~configuration ?rule_filter models
          in
          ( models,
            List.rev_append new_errors errors,
            Set.union skip_overrides new_skip_overrides,
            List.rev_append new_queries queries ))
    in
    let remove_sinks models = Callable.Map.map ~f:Model.remove_sinks models in
    let add_obscure_sinks models =
      let add_obscure_sink models callable =
        let model =
          Callable.Map.find models callable
          |> Option.value ~default:Taint.Result.empty_model
          |> Model.add_obscure_sink ~resolution ~call_target:callable
        in
        Callable.Map.set models ~key:callable ~data:model
      in
      List.filter stubs ~f:(fun callable -> not (Callable.Map.mem models callable))
      |> List.fold ~init:models ~f:add_obscure_sink
    in
    let model_paths =
      Yojson.Safe.Util.member "model_paths" taint
      |> Yojson.Safe.Util.to_list
      |> List.map ~f:Yojson.Safe.Util.to_string
    in
    let models, skip_overrides =
      match model_paths with
      | [] -> models, Ast.Reference.Set.empty
      | _ -> (
          try
            let paths = List.map model_paths ~f:Path.create_absolute in
            let configuration =
              TaintConfiguration.create
                ~rule_filter
                ~find_missing_flows
                ~dump_model_query_results_path
                ~paths
            in
            TaintConfiguration.register configuration;
            let models, errors, skip_overrides, queries =
              Model.get_model_sources ~paths |> create_models ~configuration
            in
            List.iter errors ~f:(fun error -> Log.error "%s" error);
            if verify && not (List.is_empty errors) then
              raise (Model.InvalidModel (List.hd_exn errors));
            let models =
              let callables =
                List.rev_append stubs functions
                |> List.filter_map ~f:(function
                       | `Function _ as callable -> Some (callable :> Callable.real_target)
                       | `Method _ as callable -> Some (callable :> Callable.real_target)
                       | _ -> None)
              in
              TaintModelQuery.ModelQuery.apply_all_rules
                ~resolution
                ~scheduler
                ~configuration
                ~rule_filter
                ~rules:queries
                ~callables
                ~models
            in
            let models =
              match find_missing_flows with
              | Some Obscure -> models |> remove_sinks |> add_obscure_sinks
              | Some Type -> models |> remove_sinks
              | None -> models
            in
            models, skip_overrides
          with
          | exn ->
              Log.error "Error getting taint models.";
              Log.error "%s" (Exn.to_string exn);
              raise exn )
    in
    { Interprocedural.Result.initial_models = models; skip_overrides }


  let analyze ~callable ~environment ~qualifier ~define ~mode existing_model =
    let call_graph_of_define =
      Interprocedural.CallGraph.SharedMemory.get_or_compute
        ~callable
        ~environment
        ~define:(Ast.Node.value define)
    in
    let forward, result, triggered_sinks =
      ForwardAnalysis.run ~environment ~qualifier ~define ~call_graph_of_define ~existing_model
    in
    let backward =
      BackwardAnalysis.run
        ~environment
        ~qualifier
        ~define
        ~call_graph_of_define
        ~existing_model
        ~triggered_sinks
    in
    let model =
      let open Domains in
      match mode with
      | Mode.Normal -> { forward; backward; mode }
      | Sanitize { sources = sanitize_sources; sinks = sanitize_sinks; tito = sanitize_tito } ->
          let forward =
            match sanitize_sources with
            | Some Mode.AllSources -> empty_model.forward
            | Some (Mode.SpecificSources sanitized_sources) ->
                let { Forward.source_taint } = forward in
                ForwardState.partition
                  ForwardTaint.leaf
                  ~f:(fun source ->
                    Option.some_if
                      (not (List.mem ~equal:Sources.equal sanitized_sources source))
                      source)
                  source_taint
                |> Core.Map.Poly.fold
                     ~init:ForwardState.bottom
                     ~f:(fun ~key:_ ~data:source_state state ->
                       ForwardState.join source_state state)
                |> fun source_taint -> { Forward.source_taint }
            | None -> forward
          in
          let taint_in_taint_out =
            match sanitize_tito with
            | Some AllTito -> empty_model.backward.taint_in_taint_out
            | _ -> backward.taint_in_taint_out
          in
          let sink_taint =
            match sanitize_sinks with
            | Some Mode.AllSinks -> empty_model.backward.sink_taint
            | Some (Mode.SpecificSinks sanitized_sinks) ->
                let { Backward.sink_taint; _ } = backward in
                BackwardState.partition
                  BackwardTaint.leaf
                  ~f:(fun source ->
                    Option.some_if (not (List.mem ~equal:Sinks.equal sanitized_sinks source)) source)
                  sink_taint
                |> Core.Map.Poly.fold
                     ~init:BackwardState.bottom
                     ~f:(fun ~key:_ ~data:source_state state ->
                       BackwardState.join source_state state)
            | None -> backward.sink_taint
          in
          { forward; backward = { sink_taint; taint_in_taint_out }; mode }
      | SkipAnalysis -> { empty_model with mode }
    in
    result, model


  let analyze ~callable ~environment ~qualifier ~define ~existing =
    match existing with
    | Some ({ mode = SkipAnalysis; _ } as model) ->
        let () = Log.info "Skipping taint analysis of %a" Callable.pretty_print callable in
        [], model
    | Some ({ mode; _ } as model) -> analyze ~callable ~environment ~qualifier ~define ~mode model
    | None -> analyze ~callable ~environment ~qualifier ~define ~mode:Normal empty_model
end)
