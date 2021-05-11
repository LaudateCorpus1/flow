(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* These functions are adapted from typing/refinement.ml. Eventually, this will be the only place
 * where refinement logic lives, so jmbrown is ok with this temporary duplication while he is
 * fleshing out the refinement features of EnvBuilder
 *
 * The purpose of these functions is to extract _what_ is being refined when we have something like
 * expr != null. What in expr does this refine? *)
let rec key =
  let open Flow_ast.Expression in
  function
  | (_, Identifier id) -> key_of_identifier id
  | _ ->
    (* other LHSes unsupported currently/here *)
    None

and key_of_identifier (_, { Flow_ast.Identifier.name; comments = _ }) =
  if name = "undefined" then
    None
  else
    Some name

let is_number_literal node =
  let open Flow_ast in
  match node with
  | Expression.Literal { Literal.value = Literal.Number _; _ }
  | Expression.Unary
      {
        Expression.Unary.operator = Expression.Unary.Minus;
        argument = (_, Expression.Literal { Literal.value = Literal.Number _; _ });
        comments = _;
      } ->
    true
  | _ -> false

let extract_number_literal node =
  let open Flow_ast in
  match node with
  | Expression.Literal { Literal.value = Literal.Number _; raw; comments = _ } -> raw
  | Expression.Unary
      {
        Expression.Unary.operator = Expression.Unary.Minus;
        argument = (_, Expression.Literal { Literal.value = Literal.Number _; raw; _ });
        comments = _;
      } ->
    "-" ^ raw
  | _ -> Utils_js.assert_false "not a number literal"

module type S = sig
  module L : Loc_sig.S

  module Ssa_api : Ssa_api.S with module L = L

  module Scope_api : Scope_api_sig.S with module L = L

  module Provider_api : Provider_api.S with module L = L

  type refinement_kind =
    | And of refinement_kind * refinement_kind
    | Or of refinement_kind * refinement_kind
    | Not of refinement_kind
    | Truthy
    | Null
    | Undefined
    | Maybe
    | InstanceOf of L.t
    | IsArray
    | BoolR
    | FunctionR
    | NumberR
    | ObjectR
    | StringR
    | SymbolR
    | SingletonBoolR of bool
    | SingletonStrR of string
    | SingletonNumR of string
  [@@deriving show { with_path = false }]

  type refinement = L.LSet.t * refinement_kind

  val program_with_scope :
    ?ignore_toplevel:bool ->
    (L.t, L.t) Flow_ast.Program.t ->
    Scope_api.info * Ssa_api.values * refinement L.LMap.t * Provider_api.env

  val program : (L.t, L.t) Flow_ast.Program.t -> refinement L.LMap.t

  val sources_of_use :
    Scope_api.info * Ssa_api.values * refinement L.LMap.t * Provider_api.env -> L.t -> L.LSet.t

  val source_bindings :
    Scope_api.info * Ssa_api.values * refinement L.LMap.t * Provider_api.env -> L.LSet.t L.LMap.t
end

module Make
    (L : Loc_sig.S)
    (Ssa_api : Ssa_api.S with module L = L)
    (Scope_api : Scope_api_sig.S with module L = Ssa_api.L) :
  S with module L = L and module Ssa_api = Ssa_api and module Scope_api = Scope_api = struct
  module L = L
  module Ssa_api = Ssa_api
  module Scope_api = Scope_api
  module Scope_builder = Scope_builder.Make (L) (Scope_api)
  module Ssa_builder = Ssa_builder.Make (L) (Ssa_api) (Scope_builder)
  module Invalidation_api = Invalidation_api.Make (L) (Scope_api) (Ssa_api)
  module Provider_api = Provider_api.Make (L)

  type refinement_kind =
    | And of refinement_kind * refinement_kind
    | Or of refinement_kind * refinement_kind
    | Not of refinement_kind
    | Truthy
    | Null
    | Undefined
    | Maybe
    | InstanceOf of L.t
    | IsArray
    | BoolR
    | FunctionR
    | NumberR
    | ObjectR
    | StringR
    | SymbolR
    | SingletonBoolR of bool
    | SingletonStrR of string
    | SingletonNumR of string
  [@@deriving show { with_path = false }]

  type refinement = L.LSet.t * refinement_kind

  let merge_and (locs1, ref1) (locs2, ref2) = (L.LSet.union locs1 locs2, And (ref1, ref2))

  let merge_or (locs1, ref1) (locs2, ref2) = (L.LSet.union locs1 locs2, Or (ref1, ref2))

  class env_builder (prepass_info, prepass_values) (provider_info, _) =
    object (this)
      inherit Ssa_builder.ssa_builder as super

      val mutable expression_refinement_scopes = []

      val mutable refined_reads = L.LMap.empty

      method refined_reads : refinement L.LMap.t = refined_reads

      method private push_refinement_scope scope =
        expression_refinement_scopes <- scope :: expression_refinement_scopes

      method private pop_refinement_scope () =
        expression_refinement_scopes <- List.tl expression_refinement_scopes

      method private negate_new_refinements () =
        let head = List.hd expression_refinement_scopes in
        let head' = IMap.map (fun (l, v) -> (l, Not v)) head in
        expression_refinement_scopes <- head' :: List.tl expression_refinement_scopes

      method private peek_new_refinements () = List.hd expression_refinement_scopes

      method private merge_refinement_scopes ~merge scope1 scope2 =
        IMap.merge
          (fun _ ref1 ref2 ->
            match (ref1, ref2) with
            | (Some ref1, Some ref2) -> Some (merge ref1 ref2)
            | (Some ref, _) -> Some ref
            | (_, Some ref) -> Some ref
            | _ -> None)
          scope1
          scope2

      method private merge_self_refinement_scope scope1 =
        let scope2 = this#peek_new_refinements () in
        let scope = this#merge_refinement_scopes ~merge:merge_and scope1 scope2 in
        this#pop_refinement_scope ();
        this#push_refinement_scope scope

      method private find_refinement name =
        let writes = SMap.find_opt name this#ssa_env in
        match writes with
        | None -> None
        | Some writes ->
          let key = Ssa_builder.Val.id_of_val writes in
          List.fold_left
            (fun refinement refinement_scope ->
              match (IMap.find_opt key refinement_scope, refinement) with
              | (None, _) -> refinement
              | (Some refinement, None) -> Some refinement
              | (Some (l, refinement), Some (l', refinement')) ->
                Some (L.LSet.union l l', And (refinement, refinement')))
            None
            expression_refinement_scopes

      method private add_refinement name ((loc, kind) as refinement) =
        let writes_to_loc = SMap.find name this#ssa_env in
        match expression_refinement_scopes with
        | scope :: scopes ->
          let scope' =
            IMap.update
              (Ssa_builder.Val.id_of_val writes_to_loc)
              (function
                | None -> Some refinement
                | Some (l', r') -> Some (L.LSet.union loc l', And (r', kind)))
              scope
          in
          expression_refinement_scopes <- scope' :: scopes
        | _ -> failwith "Tried to add a refinement when no scope was on the stack"

      method! havoc_current_ssa_env ~all =
        SMap.iter
          (fun _x { Ssa_builder.val_ref; havoc = { Ssa_builder.Havoc.unresolved; locs } } ->
            match locs with
            | loc :: _ when Invalidation_api.should_invalidate ~all prepass_info prepass_values loc
              ->
              (* NOTE: havoc_env should already have all writes to x, so the only
               additional thing that could come from ssa_env is "uninitialized." On
               the other hand, we *dont* want to include "uninitialized" if it's no
               longer in ssa_env, since that means that x has been initialized (and
               there's no going back). *)
              val_ref := unresolved
            | [] ->
              (* If we haven't yet seen a write to this variable, we always havoc *)
              val_ref := unresolved
            | _ -> ())
          ssa_env

      method identifier_refinement ((loc, ident) as identifier) =
        ignore @@ this#identifier identifier;
        let { Flow_ast.Identifier.name; _ } = ident in
        this#add_refinement name (L.LSet.singleton loc, Truthy)

      method assignment_refinement loc assignment =
        ignore @@ this#assignment loc assignment;
        let open Flow_ast.Expression.Assignment in
        match assignment.left with
        | ( _,
            Flow_ast.Pattern.Identifier
              { Flow_ast.Pattern.Identifier.name = (_, { Flow_ast.Identifier.name; _ }); _ } ) ->
          this#add_refinement name (L.LSet.singleton loc, Truthy)
        | _ -> ()

      method logical_refinement expr =
        let { Flow_ast.Expression.Logical.operator; left; right; comments = _ } = expr in
        this#push_refinement_scope IMap.empty;
        ignore @@ this#expression_refinement left;
        let env1 = this#ssa_env in
        let refinement_scope1 = this#peek_new_refinements () in
        (match operator with
        | Flow_ast.Expression.Logical.Or -> this#negate_new_refinements ()
        | Flow_ast.Expression.Logical.And -> ()
        | Flow_ast.Expression.Logical.NullishCoalesce ->
          failwith "TODO logical_refinement nullish coalescing");
        this#push_refinement_scope IMap.empty;
        ignore @@ this#expression_refinement right;
        let refinement_scope2 = this#peek_new_refinements () in
        (* Pop RHS scope *)
        this#pop_refinement_scope ();
        (* Pop LHS scope *)
        this#pop_refinement_scope ();
        let merge =
          match operator with
          | Flow_ast.Expression.Logical.Or -> merge_or
          | _ -> merge_and
        in
        let refinement_scope =
          this#merge_refinement_scopes ~merge refinement_scope1 refinement_scope2
        in
        this#merge_self_refinement_scope refinement_scope;
        this#merge_self_ssa_env env1

      method null_test ~strict ~sense loc expr =
        ignore @@ this#expression expr;
        match key expr with
        | None -> ()
        | Some name ->
          let refinement =
            if strict then
              Null
            else
              Maybe
          in
          let refinement =
            if sense then
              refinement
            else
              Not refinement
          in
          this#add_refinement name (L.LSet.singleton loc, refinement)

      method void_test ~sense ~strict ~check_for_bound_undefined loc expr =
        ignore @@ this#expression expr;
        match key expr with
        | None -> ()
        | Some name ->
          (* Only add the refinement if undefined is not re-bound *)
          if (not check_for_bound_undefined) || SMap.find_opt "undefined" this#ssa_env = None then
            let refinement =
              if strict then
                Undefined
              else
                Maybe
            in
            let refinement =
              if sense then
                refinement
              else
                Not refinement
            in
            this#add_refinement name (L.LSet.singleton loc, refinement)

      method typeof_test loc arg typename sense =
        ignore @@ this#expression arg;
        let refinement =
          match typename with
          | "boolean" -> Some BoolR
          | "function" -> Some FunctionR
          | "number" -> Some NumberR
          | "object" -> Some ObjectR
          | "string" -> Some StringR
          | "symbol" -> Some SymbolR
          | "undefined" -> Some Undefined
          | _ -> None
        in
        match (refinement, key arg) with
        | (Some ref, Some name) ->
          let refinement =
            if sense then
              ref
            else
              Not ref
          in
          this#add_refinement name (L.LSet.singleton loc, refinement)
        | _ -> ()

      method literal_test ~strict ~sense loc expr refinement =
        ignore @@ this#expression expr;
        match key expr with
        | Some name when strict ->
          let refinement =
            if sense then
              refinement
            else
              Not refinement
          in
          this#add_refinement name (L.LSet.singleton loc, refinement)
        | _ -> ()

      method eq_test ~strict ~sense loc left right =
        let open Flow_ast in
        match (left, right) with
        (* typeof expr ==/=== string *)
        | ( ( _,
              Expression.Unary
                { Expression.Unary.operator = Expression.Unary.Typeof; argument; comments = _ } ),
            (_, Expression.Literal { Literal.value = Literal.String s; _ }) )
        | ( (_, Expression.Literal { Literal.value = Literal.String s; _ }),
            ( _,
              Expression.Unary
                { Expression.Unary.operator = Expression.Unary.Typeof; argument; comments = _ } ) )
        | ( ( _,
              Expression.Unary
                { Expression.Unary.operator = Expression.Unary.Typeof; argument; comments = _ } ),
            ( _,
              Expression.TemplateLiteral
                {
                  Expression.TemplateLiteral.quasis =
                    [
                      ( _,
                        {
                          Expression.TemplateLiteral.Element.value =
                            { Expression.TemplateLiteral.Element.cooked = s; _ };
                          _;
                        } );
                    ];
                  expressions = [];
                  comments = _;
                } ) )
        | ( ( _,
              Expression.TemplateLiteral
                {
                  Expression.TemplateLiteral.quasis =
                    [
                      ( _,
                        {
                          Expression.TemplateLiteral.Element.value =
                            { Expression.TemplateLiteral.Element.cooked = s; _ };
                          _;
                        } );
                    ];
                  expressions = [];
                  comments = _;
                } ),
            ( _,
              Expression.Unary
                { Expression.Unary.operator = Expression.Unary.Typeof; argument; comments = _ } ) )
          ->
          this#typeof_test loc argument s sense
        (* bool equality *)
        | ((_, Expression.Literal { Literal.value = Literal.Boolean lit; _ }), expr)
        | (expr, (_, Expression.Literal { Literal.value = Literal.Boolean lit; _ })) ->
          this#literal_test ~strict ~sense loc expr (SingletonBoolR lit)
        (* string equality *)
        | ((_, Expression.Literal { Literal.value = Literal.String lit; _ }), expr)
        | (expr, (_, Expression.Literal { Literal.value = Literal.String lit; _ }))
        | ( expr,
            ( _,
              Expression.TemplateLiteral
                {
                  Expression.TemplateLiteral.quasis =
                    [
                      ( _,
                        {
                          Expression.TemplateLiteral.Element.value =
                            { Expression.TemplateLiteral.Element.cooked = lit; _ };
                          _;
                        } );
                    ];
                  _;
                } ) )
        | ( ( _,
              Expression.TemplateLiteral
                {
                  Expression.TemplateLiteral.quasis =
                    [
                      ( _,
                        {
                          Expression.TemplateLiteral.Element.value =
                            { Expression.TemplateLiteral.Element.cooked = lit; _ };
                          _;
                        } );
                    ];
                  _;
                } ),
            expr ) ->
          this#literal_test ~strict ~sense loc expr (SingletonStrR lit)
        (* number equality *)
        | ((_, number_literal), expr) when is_number_literal number_literal ->
          let raw = extract_number_literal number_literal in
          this#literal_test ~strict ~sense loc expr (SingletonNumR raw)
        | (expr, (_, number_literal)) when is_number_literal number_literal ->
          let raw = extract_number_literal number_literal in
          this#literal_test ~strict ~sense loc expr (SingletonNumR raw)
        (* expr op null *)
        | ((_, Expression.Literal { Literal.value = Literal.Null; _ }), expr)
        | (expr, (_, Expression.Literal { Literal.value = Literal.Null; _ })) ->
          this#null_test ~sense ~strict loc expr
        (* expr op undefined *)
        | ( ( ( _,
                Expression.Identifier (_, { Flow_ast.Identifier.name = "undefined"; comments = _ })
              ) as undefined ),
            expr )
        | ( expr,
            ( ( _,
                Expression.Identifier (_, { Flow_ast.Identifier.name = "undefined"; comments = _ })
              ) as undefined ) ) ->
          ignore @@ this#expression undefined;
          this#void_test ~sense ~strict ~check_for_bound_undefined:true loc expr
        (* expr op void(...) *)
        | ((_, Expression.Unary { Expression.Unary.operator = Expression.Unary.Void; _ }), expr)
        | (expr, (_, Expression.Unary { Expression.Unary.operator = Expression.Unary.Void; _ })) ->
          this#void_test ~sense ~strict ~check_for_bound_undefined:false loc expr
        | _ ->
          ignore @@ this#expression left;
          ignore @@ this#expression right

      method instance_test loc expr instance =
        ignore @@ this#expression expr;
        ignore @@ this#expression instance;
        match key expr with
        | None -> ()
        | Some name ->
          let (inst_loc, _) = instance in
          this#add_refinement name (L.LSet.singleton loc, InstanceOf inst_loc)

      method binary_refinement loc expr =
        let open Flow_ast.Expression.Binary in
        let { operator; left; right; comments = _ } = expr in
        match operator with
        (* == and != refine if lhs or rhs is an ident and other side is null *)
        | Equal -> this#eq_test ~strict:false ~sense:true loc left right
        | NotEqual -> this#eq_test ~strict:false ~sense:false loc left right
        | StrictEqual -> this#eq_test ~strict:true ~sense:true loc left right
        | StrictNotEqual -> this#eq_test ~strict:true ~sense:false loc left right
        | Instanceof -> this#instance_test loc left right
        | LessThan
        | LessThanEqual
        | GreaterThan
        | GreaterThanEqual
        | In
        | LShift
        | RShift
        | RShift3
        | Plus
        | Minus
        | Mult
        | Exp
        | Div
        | Mod
        | BitOr
        | Xor
        | BitAnd ->
          ignore @@ this#binary loc expr

      method call_refinement loc call =
        match call with
        | {
         Flow_ast.Expression.Call.callee =
           ( _,
             Flow_ast.Expression.Member
               {
                 Flow_ast.Expression.Member._object =
                   ( _,
                     Flow_ast.Expression.Identifier
                       (_, { Flow_ast.Identifier.name = "Array"; comments = _ }) );
                 property =
                   Flow_ast.Expression.Member.PropertyIdentifier
                     (_, { Flow_ast.Identifier.name = "isArray"; comments = _ });
                 comments = _;
               } );
         targs = _;
         arguments =
           ( _,
             {
               Flow_ast.Expression.ArgList.arguments = [Flow_ast.Expression.Expression arg];
               comments = _;
             } );
         comments = _;
        } ->
          ignore @@ this#expression arg;
          (match key arg with
          | None -> ()
          | Some name -> this#add_refinement name (L.LSet.singleton loc, IsArray))
        | _ -> ignore @@ this#call loc call

      method unary_refinement
          loc ({ Flow_ast.Expression.Unary.operator; argument; comments = _ } as unary) =
        match operator with
        | Flow_ast.Expression.Unary.Not ->
          this#push_refinement_scope IMap.empty;
          ignore @@ this#expression_refinement argument;
          this#negate_new_refinements ();
          let new_refinements = this#peek_new_refinements () in
          this#pop_refinement_scope ();
          this#merge_self_refinement_scope new_refinements
        | _ -> ignore @@ this#unary_expression loc unary

      method expression_refinement ((loc, expr) as expression) =
        let open Flow_ast.Expression in
        match expr with
        | Identifier ident ->
          this#identifier_refinement ident;
          expression
        | Logical logical ->
          this#logical_refinement logical;
          expression
        | Assignment assignment ->
          this#assignment_refinement loc assignment;
          expression
        | Binary binary ->
          this#binary_refinement loc binary;
          expression
        | Call call ->
          this#call_refinement loc call;
          expression
        | Unary unary ->
          this#unary_refinement loc unary;
          expression
        | Array _
        | ArrowFunction _
        | Class _
        | Comprehension _
        | Conditional _
        | Function _
        | Generator _
        | Import _
        | JSXElement _
        | JSXFragment _
        | Literal _
        | MetaProperty _
        | Member _
        | New _
        | Object _
        | OptionalCall _
        | OptionalMember _
        | Sequence _
        | Super _
        | TaggedTemplate _
        | TemplateLiteral _
        | TypeCast _
        | This _
        | Update _
        | Yield _ ->
          this#expression expression

      method! logical _loc (expr : (L.t, L.t) Flow_ast.Expression.Logical.t) =
        let open Flow_ast.Expression.Logical in
        let { operator; left; right; comments = _ } = expr in
        this#push_refinement_scope IMap.empty;
        ignore @@ this#expression_refinement left;
        let env1 = this#ssa_env in
        (match operator with
        | Flow_ast.Expression.Logical.Or -> this#negate_new_refinements ()
        | Flow_ast.Expression.Logical.And -> ()
        | Flow_ast.Expression.Logical.NullishCoalesce ->
          failwith "nullish coalescing refinements are not yet implemented");
        ignore @@ this#expression right;
        this#pop_refinement_scope ();
        this#merge_self_ssa_env env1;
        expr

      method! pattern_identifier ?kind ident =
        let open Ssa_builder in
        let (loc, { Flow_ast.Identifier.name = x; comments = _ }) = ident in
        begin
          match SMap.find_opt x ssa_env with
          | Some { val_ref; havoc } ->
            val_ref := Val.one loc;
            Havoc.(
              havoc.locs <-
                Base.Option.value_exn (Provider_api.providers_of_def provider_info loc)
                |> L.LSet.elements)
          | _ -> ()
        end;
        super#super_pattern_identifier ?kind ident

      (* This method is called during every read of an identifier. We need to ensure that
       * if the identifier is refined that we record the refiner as the write that reaches
       * this read *)
      method! any_identifier loc name =
        super#any_identifier loc name;
        match this#find_refinement name with
        | None -> ()
        | Some refinement -> refined_reads <- L.LMap.add loc refinement refined_reads
    end

  let program_with_scope ?(ignore_toplevel = false) program =
    let open Hoister in
    let (loc, _) = program in
    let prepass = Ssa_builder.program_with_scope ~ignore_toplevel program in
    let providers = Provider_api.find_providers program in
    let ssa_walk = new env_builder prepass providers in
    let bindings =
      if ignore_toplevel then
        Bindings.empty
      else
        let hoist = new hoister ~with_types:true in
        hoist#eval hoist#program program
    in
    ignore @@ ssa_walk#with_bindings loc bindings ssa_walk#program program;
    (ssa_walk#acc, ssa_walk#values, ssa_walk#refined_reads, providers)

  let program program =
    let (_, _, refined_reads, _) = program_with_scope ~ignore_toplevel:false program in
    refined_reads

  let sources_of_use (_, vals, refis, _) loc =
    let write_locs =
      L.LMap.find_opt loc vals
      |> Base.Option.value_map
           ~f:
             (Fn.compose
                L.LSet.of_list
                (Base.List.filter_map ~f:(function
                    | Ssa_api.Uninitialized -> None
                    | Ssa_api.Write l -> Some l)))
           ~default:L.LSet.empty
    in
    let refi_locs =
      L.LMap.find_opt loc refis |> Base.Option.value_map ~f:fst ~default:L.LSet.empty
    in
    L.LSet.union refi_locs write_locs

  let source_bindings ((_, vals, refis, _) as info) =
    let keys = L.LSet.of_list (L.LMap.keys vals @ L.LMap.keys refis) in
    L.LSet.fold (fun k acc -> L.LMap.add k (sources_of_use info k) acc) keys L.LMap.empty
end

module With_Loc = Make (Loc_sig.LocS) (Ssa_api.With_Loc) (Scope_api.With_Loc)