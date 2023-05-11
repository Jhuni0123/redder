open CL.Typedtree
open CL.Types

exception RuntimeError of string

module Id = struct
  (* Ident.t is unique under a module file, except for the ident of top-level module (persistent). *)
  (* Then Ident.t with top-level module name is unique for whole codebase. *)
  type t = string * CL.Ident.t

  let create ctx ident : t = (ctx, ident)

  let createTopLevelModuleId modname : t =
    ("+", {name = modname; stamp = 0; flags = 0})

  let ident (id: t) = snd id
  let ctx (id: t) = fst id

  let name id = id |> ident |> CL.Ident.name

  let hash id =
    CL.Ident.hash (snd id)

  let compare a b =
    let c = String.compare (ctx a) (ctx b) in
    if c <> 0 then c
    else CL.Ident.compare (ident a) (ident b)

  let equal a b =
    String.equal (ctx a) (ctx b) && CL.Ident.equal (ident a) (ident b)

  let print (id: t) =
    Printf.printf "[%s]%s" (ctx id) (name id)
end

module ModuleEnv = struct
  module IdTbl = Hashtbl.Make (Id)
  type t = (string, Id.t) Hashtbl.t IdTbl.t

  let create (): t =
    IdTbl.create 10

  let addMember (parent: Id.t) (child: Id.t) env =
    match IdTbl.find_opt env parent with
    | Some tbl ->
        (* if not (Hashtbl.mem tbl (CL.Ident.name child)) then *)
          Hashtbl.add tbl (Id.name child) child
    | None ->
        let tbl = Hashtbl.create 10 in
        Hashtbl.add tbl (Id.name child) child;
        IdTbl.add env parent tbl

  let resolvePath currentMod (path: CL.Path.t) (env: t): Id.t list =
    let rec _findIdents (p: CL.Path.t): Id.t list =
      match p with
      | Pident id ->
          (match CL.Ident.persistent id with
          | true -> [Id.createTopLevelModuleId (CL.Ident.name id)]
          | false -> [Id.create currentMod id]
          )
      | Pdot (sub, name, _) -> (
        let parents = _findIdents sub in
        parents |> List.map (fun parent -> 
            (match IdTbl.find_opt env parent with
            | Some tbl -> Hashtbl.find_all tbl name
            | None -> []
            )
        ) |> List.flatten
      )
      | Papply _ -> []
    in _findIdents path

  let print (env: t) =
    env |> IdTbl.iter (fun id tbl ->
      Id.print id;
      print_endline ":";
      tbl |> Hashtbl.iter (fun name id' ->
        print_string ("  " ^ name ^ ": ");
        Id.print id';
        print_newline ();
      )
    )
end

(* Expression ID mapping *)
module Expr = struct
  type id = string

  let counter = ref 0

  let new_loc () =
    counter := !counter + 1;
    CL.Location.in_file ("_expr_" ^ string_of_int !counter)

  let toId e = e.exp_loc.loc_start.pos_fname
  let fromIdTbl : (id, expression) Hashtbl.t = Hashtbl.create 256
  let origLocTbl : (id, CL.Location.t) Hashtbl.t = Hashtbl.create 256
  let fromId eid = Hashtbl.find fromIdTbl eid

  let origLoc e = Hashtbl.find origLocTbl (toId e)

  let preprocess e =
    let origLoc = e.exp_loc in
    let e = {e with exp_loc = new_loc ()} in
    Hashtbl.add fromIdTbl (toId e) e;
    Hashtbl.add origLocTbl (toId e) origLoc;
    e
end

(* Function ID mapping *)
type fnbody = {pat : pattern; exp_id : Expr.id}

let idToBody : (Expr.id, fnbody list) Hashtbl.t = Hashtbl.create 256
let bodyOfFunction eid = Hashtbl.find idToBody eid

let preprocessFunction e =
  let eid = Expr.toId e in
  match e.exp_desc with
  | Texp_function {param; cases} ->
    let ids =
      cases
      |> List.map (fun case ->
             {pat = case.c_lhs; exp_id = Expr.toId case.c_rhs})
    in
    if Hashtbl.mem idToBody eid then raise (RuntimeError "duplicate ident");
    Hashtbl.add idToBody eid ids
  | _ -> ()

let string_of_loc (loc : CL.Location.t) =
  let file, line, startchar = CL.Location.get_pos_info loc.loc_start in
  let filename = file |> String.split_on_char '/' |> List.rev |> List.hd in
  let startchar = startchar + 1 in
  let endchar = loc.loc_end.pos_cnum - loc.loc_start.pos_cnum + startchar in
  Printf.sprintf "%s:%i:%i:%i:%B" filename line (startchar - 1) (endchar - 1)
    loc.loc_ghost

let rec isUnitType (t: type_expr) =
  match t.desc with
  | Tconstr (path, _, _) ->
      CL.Path.name path = "unit"
  | Tlink t -> isUnitType t
  | _ -> false

module ValueMeta = struct
  type t =
    | VM_Expr of Expr.id
    | VM_Mutable of Expr.id * string
    | VM_Name of Id.t

  let expr e = VM_Expr (Expr.toId e)
  let compare = compare

  let print vm =
    match vm with
    | VM_Expr eid -> Printf.printf "Expr(%s,%s)" eid (eid |> Expr.fromId |> Expr.origLoc |> string_of_loc)
    | VM_Mutable (et, s) -> Printf.printf "Mut(%s)" s
    | VM_Name id ->
        print_string "Name("; Id.print id; 
      Printf.printf ")"

  let shouldReport vm =
    match vm with
    | VM_Expr eid -> (
        let e = Expr.fromId eid in
        not (isUnitType e.exp_type)
    )
    | _ -> true

  let report ppf vm =
    let loc =
      match vm with
      | VM_Expr eid -> Expr.origLoc (Expr.fromId eid)
      | VM_Mutable (eid, _) -> (Expr.fromId eid).exp_loc
      | VM_Name (name) -> CL.Location.none
    in
    let name =
      match vm with
      | VM_Expr eid ->
          ""
      | VM_Mutable _ -> "<memory>"
      | VM_Name id -> Id.name id
    in
    if shouldReport vm then (
      Log_.warning ~loc ~name:"Warning Dead Value" (fun ppf () ->
        match vm with
        | VM_Expr eid ->
            let e = Expr.fromId eid in
            Format.fprintf ppf "\n";
            Print.print_expression 0 e
        | VM_Mutable _ ->  Format.fprintf ppf "<mutable field>"
        | VM_Name id ->
            Format.fprintf ppf "%s" (Id.name id)
      );
    )
end

module VMSet = Set.Make (ValueMeta)

module Field = struct
  type t = F_Record of string | F_Tuple of int

  let compare = compare
end

module Value = struct
  type t =
    | V_Expr of Expr.id
    | V_Mutable of Expr.id * string
    | V_Name of Id.t (* except primitive *)
    | V_Prim of CL.Primitive.description
    | V_Cstr of constructor_description * Expr.id list
    | V_Variant of string * Expr.id
    | V_Field of Field.t * Expr.id
    | V_Fn of Expr.id * CL.Ident.t (* (λx.e)_l *)
    | V_PartialApp of
        Expr.id * Expr.id option list (* first arg is none: e [_ e1 e2] *)
    | V_FnSideEffect

  let compare a b =
    match a, b with
    | V_Name id1, V_Name id2 -> Id.compare id1 id2
    | _ -> compare a b

  let expr e = V_Expr (Expr.toId e)

  let print v =
    match v with
    | V_Expr eid -> Printf.printf "Expr(%s)" eid
    | V_Mutable (et, s) -> Printf.printf "Mut(%s)" s
    | V_Name id -> Printf.printf "Name(%s)" (Id.name id)
    | V_Prim prim -> Printf.printf "Prim(%s)" prim.prim_name
    | V_Cstr (cstr_desc, eids) ->
      Printf.printf "Cstr-%s(" cstr_desc.cstr_name;
      Print.print_list (fun eid -> print_string eid) "," eids;
      print_string ")"
    | V_Variant (k, eid) -> Printf.printf "Variant(%s,%s)" k eid
    | V_Field (f, eid) ->
      Printf.printf "Field(%s,%s)"
        (match f with F_Record f -> f | F_Tuple n -> string_of_int n)
        eid
    | V_Fn (eid, param) -> Printf.printf "Fn(%s)" param.name
    | V_PartialApp (eid, args) ->
        Printf.printf "App(%s,[" eid;
      None :: args
      |> Print.print_list
           (fun argo ->
             match argo with
             | None -> print_string "-"
             | Some eid -> print_string eid)
           ",";
      print_string "])"
    | V_FnSideEffect -> Printf.printf "λ.φ"
end

module Reduction = struct
  type t = Reduce of Expr.id * Expr.id * Expr.id option list (* e [e1, ...] *)

  let compare = compare
end
open ValueMeta
open Value


open Reduction
module ReductionSet = Set.Make (Reduction)

module Reductions = struct
  type t = (Expr.id, ReductionSet.t) Hashtbl.t

  let add k reduc (reductions : t) : bool =
    match Hashtbl.find_opt reductions k with
    | None ->
      Hashtbl.add reductions k (ReductionSet.singleton reduc);
      true
    | Some s ->
      let s' = s |> ReductionSet.add reduc in
      if s' = s then false
      else (
        Hashtbl.replace reductions k s';
        true)

  let find k (reductions : t) =
    match Hashtbl.find_opt reductions k with
    | None -> ReductionSet.empty
    | Some s -> s
end

module StringMap = Map.Make (String)

module CstrMap = Map.Make (struct
  type t = constructor_description

  let compare = compare
end)

module FieldMap = Map.Make (Field)

module Live = struct
  type t =
    | Top
    | Bot
    | Construct of t list CstrMap.t
    | Variant of t option StringMap.t
    | Record of t FieldMap.t

  let variant lbl l : t = Variant (StringMap.singleton lbl l)
  let field f l : t = Record (FieldMap.singleton f l)
  let construct cstr ls : t =
    Construct (CstrMap.singleton cstr ls)
  let constructi cstr idx l : t =
    let ls = List.init (idx + 1) (function i when i = idx -> l | _ -> Bot) in
    Construct (CstrMap.singleton cstr ls)

  let rec join a b =
    match (a, b) with
    | Top, _ | _, Top -> Top
    | Bot, x | x, Bot -> x
    | Variant ks, Variant ks' ->
      let join_opt ao bo =
        match (ao, bo) with
        | Some a, Some b -> join a b
        | Some a, None -> a
        | None, Some b -> b
        | None, None -> Bot
      in
      Variant
        (StringMap.union (fun k l1 l2 -> Some (Some (join_opt l1 l2))) ks ks')
    | Record fs, Record fs' ->
      Record (FieldMap.union (fun k l1 l2 -> Some (join l1 l2)) fs fs')
    | Construct cs, Construct cs' ->
        let rec join_list l1 l2 =
          match l1, l2 with
          | [], [] -> []
          | [], _ -> l2
          | _, [] -> l1
          | hd1 :: tl1, hd2 :: tl2 -> (join hd1 hd2) :: (join_list tl1 tl2)
        in
      Construct (CstrMap.union (fun k l1 l2 -> Some (join_list l1 l2)) cs cs')
    | _ -> Top

  let rec meet a b =
    match (a, b) with
    | Top, x | x, Top -> x
    | Bot, _ | _, Bot -> Bot
    | Variant ks, Variant ks' ->
      let meet_opt ao bo =
        match (ao, bo) with Some a, Some b -> meet a b | _ -> Bot
      in
      Variant
        (StringMap.merge
           (fun k op1 op2 ->
             match (op1, op2) with
             | Some l1, Some l2 -> Some (Some (meet_opt l1 l2))
             | _ -> None)
           ks ks')
    | Record fs, Record fs' ->
      Record
        (FieldMap.merge
           (fun k op1 op2 ->
             match (op1, op2) with
             | Some l1, Some l2 -> Some (meet l1 l2)
             | _ -> None)
           fs fs')
    | Construct cs, Construct cs' ->
        let rec meet_list l1 l2 =
          match l1, l2 with
          | hd1 :: tl1, hd2 :: tl2 -> (meet hd1 hd2) :: (meet_list tl1 tl2)
          | _ -> []
        in
      Construct
        (CstrMap.merge
           (fun k op1 op2 ->
             match (op1, op2) with
             | Some l1, Some l2 -> Some (meet_list l1 l2)
             | _ -> None)
           cs cs')
    | _ -> Bot

  let variant_inv k l =
    match l with
    | Top -> Top
    | Bot -> Bot
    | Variant ks -> (
      match StringMap.find_opt k ks with
      | None -> Bot
      | Some (Some l) -> l
      | Some None -> Bot)
    | _ -> Bot

  let field_inv k l =
    match l with
    | Top -> Top
    | Bot -> Bot
    | Record fs -> (
      match FieldMap.find_opt k fs with None -> Bot | Some l -> l)
    | _ -> Bot

  let construct_inv cstr_desc idx l =
    match l with
    | Top -> Top
    | Bot -> Bot
    | Construct cs -> (
      match CstrMap.find_opt cstr_desc cs with
      | None -> Bot
      | Some ls -> List.nth_opt ls idx |> Option.value ~default:Bot)
    | _ -> Bot

  let rec equal l1 l2 =
    match (l1, l2) with
    | Top, Top -> true
    | Bot, Bot -> true
    | Variant ks1, Variant ks2 -> StringMap.equal (Option.equal equal) ks1 ks2
    | Record fs1, Record fs2 -> FieldMap.equal equal fs1 fs2
    | Construct cs1, Construct cs2 -> CstrMap.equal (List.equal equal) cs1 cs2
    | _ -> false

  let rec print l =
    let ps = print_string in
    match l with
    | Top -> ps "⊤"
    | Bot -> ps "⊥"
    | Variant ks ->
      ks |> StringMap.bindings
      |> Print.print_list
           (fun (k, vo) ->
             ps "Variant:";ps k;
             ps "(";
             (match vo with Some v -> print v | None -> ());
             ps ")")
           "+"
    | Record fs ->
      fs |> FieldMap.bindings
      |> Print.print_list
           (fun (k, v) ->
             ps "Field:";(match k with
             | Field.F_Tuple n -> print_int n
             | F_Record f -> print_string f);
             ps "(";
             print v;
             ps ")")
           "*"
    | Construct cs ->
      cs |> CstrMap.bindings
      |> Print.print_list
           (fun (cstr_desc, v) ->
             ps "Cstr:";ps cstr_desc.cstr_name;
             ps "(";
             v |> Print.print_list print ",";
             ps ")")
           "+"

  let rec controlledByPat pat =
    match pat.pat_desc with
    | Tpat_any -> Bot
    | Tpat_var _ -> Bot
    | Tpat_alias (pat, id, l) -> controlledByPat pat
    | Tpat_constant c -> Top
    | Tpat_tuple pats ->
      pats
      |> List.mapi (fun i pat -> field (F_Tuple i) (controlledByPat pat))
      |> List.fold_left (fun acc l -> join acc l) Bot
    | Tpat_construct (lid, cstr_desc, pats) ->
        pats |> List.map controlledByPat |> construct cstr_desc
    | Tpat_variant (label, pato, row) ->
      variant label (pato |> Option.map controlledByPat)
    | Tpat_record (fields, closed_flag) ->
      fields
      |> List.map (fun (lid, lbl_desc, pat) ->
             field (F_Record lbl_desc.lbl_name) (controlledByPat pat))
      |> List.fold_left join Bot
    | Tpat_array _ -> Top (* TODO: array *)
    | Tpat_or (pat1, pat2, _) ->
      join (controlledByPat pat1) (controlledByPat pat2)
    | Tpat_lazy _ -> Top
end

module ValueSet = struct
  module ElemSet = Set.Make (Value)

  type t = VS_Top | VS_Set of ElemSet.t

  let singleton v = VS_Set (ElemSet.singleton v)
  let empty = VS_Set ElemSet.empty
  let compare = compare

  let join a b =
    match (a, b) with
    | VS_Top, _ | _, VS_Top -> VS_Top
    | VS_Set s1, VS_Set s2 -> VS_Set (ElemSet.union s1 s2)

  let add vs v =
    match vs with
    | VS_Top -> VS_Top
    | VS_Set s ->
      let s' = ElemSet.add v s in
      if s == s' then vs else VS_Set s'

  let subset s1 s2 =
    match (s1, s2) with
    | _, VS_Top -> true
    | VS_Top, _ -> false
    | VS_Set s1', VS_Set s2' -> ElemSet.subset s1' s2'

  let print vs =
    match vs with
    | VS_Top -> print_string "Top"
    | VS_Set s -> s |> ElemSet.elements |> Print.print_list Value.print ", "

  let mem k vs = match vs with VS_Top -> true | VS_Set s -> s |> ElemSet.mem k
end

module ValueMap = Map.Make (ValueMeta)

module Closure = struct
  type t = (ValueMeta.t, ValueSet.t) Hashtbl.t

  let addValue k v c : bool =
    match Hashtbl.find_opt c k with
    | None ->
      Hashtbl.add c k (ValueSet.singleton v);
      true
    | Some s ->
      let s' = ValueSet.add s v in
      if ValueSet.compare s s' = 0 then false
      else (
        Hashtbl.replace c k s';
        true)

  let addValueSet k vs c =
    match Hashtbl.find_opt c k with
    | None ->
      Hashtbl.add c k vs;
      true
    | Some s ->
      let updated = not (ValueSet.subset vs s) in
      Hashtbl.replace c k (ValueSet.join s vs);
      updated

  let find k c =
    match Hashtbl.find_opt c k with None -> ValueSet.empty | Some s -> s

  let print c =
    c |> Hashtbl.to_seq
    |> Seq.iter (fun (vm, vs) ->
           ValueMeta.print vm;
           print_string ": ";
           ValueSet.print vs;
           print_newline ())
end

module Liveness = struct
  type t = (ValueMeta.t, Live.t) Hashtbl.t

  let init vms liveness =
    vms |> Seq.iter (fun vm -> Hashtbl.add liveness vm Live.Bot)

  let get k liveness =
    match Hashtbl.find_opt liveness k with None -> Live.Bot | Some l -> l

  let join k l liveness =
    let l_prev = liveness |> get k in
    Hashtbl.replace liveness k (Live.join l l_prev)

  let meet k l liveness =
    let l_prev = liveness |> get k in
    Hashtbl.replace liveness k (Live.meet l l_prev)
end

module ExprIdSet = Set.Make (struct
  type t = Expr.id

  let compare = compare
end)

module Stack = struct
  type 'a t = 'a list ref

  exception EmptyStack

  let create () = ref []
  let push x st = st := x :: !st

  let pop st =
    match !st with
    | [] -> raise EmptyStack
    | hd :: tl ->
      st := tl;
      hd

  let to_list st = !st
end

module Graph = struct
  type node = ValueMeta.t
  type func = Live.t -> Live.t
  type adj_list = (node, node * func) Hashtbl.t
  type t = {mutable nodes : VMSet.t; adj : adj_list; adj_rev : adj_list}

  let reset g =
    Hashtbl.reset g.adj;
    Hashtbl.reset g.adj_rev

  let addEdge (v1 : node) (v2 : node) f (g : t) =
    let {adj; adj_rev} = g in
    Hashtbl.add adj v1 (v2, f);
    Hashtbl.add adj_rev v2 (v1, f)

  let scc (g : t) : node list list =
    let counter = ref 0 in
    let stack = Stack.create () in
    let num = Hashtbl.create 256 in
    let getnum vm =
      match Hashtbl.find_opt num vm with Some res -> res | None -> 0
    in
    let finished = ref VMSet.empty in
    let markfinished vm = finished := !finished |> VMSet.add vm in
    let isfinished vm = !finished |> VMSet.mem vm in
    let scc = Stack.create () in
    let rec dfs v =
      counter := !counter + 1;
      Hashtbl.add num v !counter;
      stack |> Stack.push v;
      let result =
        Hashtbl.find_all g.adj v
        |> List.fold_left
             (fun result (next, _) ->
               if getnum next = 0 then min result (dfs next)
               else if not (isfinished next) then min result (getnum next)
               else result)
             (getnum v)
      in
      if result = getnum v then (
        let nodes = Stack.create () in
        let break = ref false in
        while not !break do
          let t = stack |> Stack.pop in
          nodes |> Stack.push t;
          markfinished t;
          if ValueMeta.compare t v = 0 then break := true
        done;
        scc |> Stack.push (nodes |> Stack.to_list));
      result
    in
    g.nodes
    |> VMSet.iter (fun node -> if getnum node = 0 then dfs node |> ignore);
    scc |> Stack.to_list
end

module Current = struct
  let cmtModName : string ref = ref ""
  let closure : Closure.t = Hashtbl.create 256
  let sideEffectSet : ExprIdSet.t ref = ref ExprIdSet.empty
  let liveness : Liveness.t = Hashtbl.create 256
  let applications : Reductions.t = Hashtbl.create 256

  let env: ModuleEnv.t = ModuleEnv.create ()

  let graph : Graph.t =
    {
      nodes = VMSet.empty;
      adj = Hashtbl.create 256;
      adj_rev = Hashtbl.create 256;
    }

  let markSideEffect e : bool =
    if !sideEffectSet |> ExprIdSet.mem (Expr.toId e) then false
    else (
      sideEffectSet := !sideEffectSet |> ExprIdSet.add (Expr.toId e);
      true)

  let hasSideEffect : expression -> bool =
   fun e -> !sideEffectSet |> ExprIdSet.mem (Expr.toId e)

  let isSideEffectFn : expression -> bool =
   fun e ->
    closure |> Closure.find (ValueMeta.expr e) |> ValueSet.mem V_FnSideEffect

  let markValuesAffectSideEffect e =
    match e.exp_desc with
    | Texp_setfield (exp1, lid, ld, exp2) ->
      liveness |> Liveness.join (ValueMeta.expr exp1) Live.Top;
      liveness |> Liveness.join (ValueMeta.expr exp2) Live.Top
    | Texp_apply (exp, (_, Some _) :: _) ->
      if exp |> isSideEffectFn then
        liveness |> Liveness.join (ValueMeta.expr exp) Live.Top
    | Texp_ifthenelse (exp1, exp2, Some exp3) ->
      if exp2 |> hasSideEffect || exp3 |> hasSideEffect then
        liveness |> Liveness.join (ValueMeta.expr exp1) Live.Top
    | Texp_ifthenelse (exp1, exp2, None) ->
      if hasSideEffect exp2 then
        liveness |> Liveness.join (ValueMeta.expr exp1) Live.Top
    | Texp_while (exp1, exp2) ->
      if exp2 |> hasSideEffect then
        liveness |> Liveness.join (ValueMeta.expr exp1) Live.Top
    | Texp_for (id, pat, exp1, exp2, direction_flag, exp3) ->
      if exp3 |> hasSideEffect then
        liveness |> Liveness.join (VM_Name (Id.create !cmtModName id)) Live.Top
    | Texp_match (exp, cases, exn_cases, partial) ->
      let casesHasSideEffect =
        cases
        |> List.fold_left
             (fun acc case -> case.c_rhs |> hasSideEffect || acc)
             false
      in
      if casesHasSideEffect then
        let cond =
          cases
          |> List.fold_left
               (fun acc case -> Live.join acc (Live.controlledByPat case.c_lhs))
               Live.Bot
        in
        liveness |> Liveness.join (ValueMeta.expr exp) cond
    | _ -> ()

  let reset () =
    Hashtbl.reset closure;
    sideEffectSet := ExprIdSet.empty;
    Hashtbl.reset applications;
    Graph.reset graph;
    Hashtbl.reset liveness
end

let traverseValueMetaMapper f =
  let super = CL.Tast_mapper.default in
  let expr self e =
    f (ValueMeta.expr e);
    (match e.exp_desc with
    | Texp_for (id, ppat, _, _, _, _) -> f (VM_Name (Id.create !Current.cmtModName id))
    | _ -> ());
    super.expr self e
  in
  let pat self p =
    (match p.pat_desc with
    | Tpat_var (id, l) -> f (VM_Name (Id.create !Current.cmtModName id))
    | Tpat_alias (_, id, l) -> f (VM_Name (Id.create !Current.cmtModName id))
    | _ -> ());
    super.pat self p
  in
  {super with expr; pat}

module ClosureAnalysis = struct
  open Closure

  let updated = ref false

  let addValue vm v =
    let u = Current.closure |> Closure.addValue vm v in
    updated := !updated || u

  let addValueSet vm vs =
    let u = Current.closure |> Closure.addValueSet vm vs in
    updated := !updated || u

  let find k = Current.closure |> Closure.find k

  let markSideEffect e =
    let u = Current.markSideEffect e in
    updated := !updated || u

  let addReduction eid reduce =
    let u = Current.applications |> Reductions.add eid reduce in
    updated := !updated || u

  let rec initBind pat e =
    match pat.pat_desc with
    | Tpat_var (id, l) -> addValue (VM_Name (Id.create !Current.cmtModName id)) (Value.expr e)
    | Tpat_alias (pat', id, l) ->
      addValue (VM_Name (Id.create !Current.cmtModName id)) (Value.expr e);
      initBind pat' e
    | _ -> ()

  let initValueBinding vb = initBind vb.vb_pat vb.vb_expr

  let initExpr e =
    match e.exp_desc with
    | Texp_ident (path, lid, vd) -> (
      match vd.val_kind with
      | Val_reg -> (
          match Current.env |> ModuleEnv.resolvePath !Current.cmtModName path with
          | [] -> addValueSet (ValueMeta.expr e) VS_Top
          | ids ->
              ids |> List.iter (fun id ->
                let vm = VM_Name (id) in
                if Current.graph.nodes |> VMSet.mem vm then
                  addValue (ValueMeta.expr e) (V_Name id)
                else
                  addValueSet (ValueMeta.expr e) VS_Top
              )
      )
      | Val_prim prim ->
          (* print_endline prim.prim_name; *)
          (* print_endline (string_of_int prim.prim_arity); *)
          addValue (ValueMeta.expr e) (V_Prim prim))
    | Texp_constant _ -> ()
    | Texp_let (_, _, exp) -> addValue (ValueMeta.expr e) (Value.expr exp)
    | Texp_function {arg_label; param; cases; partial} ->
      addValue (ValueMeta.expr e) (V_Fn (Expr.toId e, param))
    | Texp_apply (exp, args) -> (
      let args = args |> List.map snd in
      match args with
      | Some hd :: tl ->
        addReduction (Expr.toId e)
          (Reduce
             (Expr.toId exp, Expr.toId hd, tl |> List.map (Option.map Expr.toId)))
      | None :: tl ->
        addValue (ValueMeta.expr e)
          (V_PartialApp (Expr.toId exp, tl |> List.map (Option.map Expr.toId)))
      | [] -> raise (RuntimeError "Unreachable: Empty apply"))
    | Texp_match (exp, cases, exn_cases, partial) ->
      cases @ exn_cases
      |> List.iter (fun case ->
             addValue (ValueMeta.expr e) (Value.expr case.c_rhs);
             initBind case.c_lhs exp)
    | Texp_try (exp, cases) ->
      addValue (ValueMeta.expr e) (Value.expr exp);
      cases
      |> List.iter (fun case ->
             addValue (ValueMeta.expr e) (Value.expr case.c_rhs))
    | Texp_tuple exps ->
      exps
      |> List.iteri (fun i exp ->
             addValue (ValueMeta.expr e) (V_Field (F_Tuple i, Expr.toId exp)))
    | Texp_construct (lid, cstr_desc, exps) ->
      addValue (ValueMeta.expr e)
        (V_Cstr (cstr_desc, exps |> List.map Expr.toId))
    | Texp_variant (label, Some exp) ->
      addValue (ValueMeta.expr e) (V_Variant (label, Expr.toId exp))
    | Texp_record {fields; representation; extended_expression} ->
      fields
      |> Array.iter (fun (label_desc, label_def) ->
             match label_desc.lbl_mut with
             | Immutable -> (
               match label_def with
               | Kept t -> ()
               | Overridden (lid, fe) ->
                 addValue (ValueMeta.expr e)
                   (V_Field (F_Record label_desc.lbl_name, Expr.toId fe)))
             | Mutable -> (
               match label_def with
               | Kept t -> ()
               | Overridden (lid, fe) -> (
                 addValue (ValueMeta.expr e) (V_Mutable (Expr.toId e, label_desc.lbl_name));
                 addValue (VM_Mutable (Expr.toId e, label_desc.lbl_name)) (Value.expr fe)
               ) ))
    | Texp_field _ -> ()
    | Texp_setfield (exp1, lid, ld, exp2) -> markSideEffect e
    | Texp_array _ -> ()
    | Texp_ifthenelse (e1, e2, Some e3) ->
      addValue (ValueMeta.expr e) (Value.expr e2);
      addValue (ValueMeta.expr e) (Value.expr e3)
    | Texp_sequence (e1, e2) -> addValue (ValueMeta.expr e) (Value.expr e2)
    | Texp_while _ -> ()
    | Texp_for _ -> ()
    | _ -> markSideEffect e

  let initMapper =
    let super = CL.Tast_mapper.default in
    let expr self e =
      initExpr e;
      super.expr self e
    in
    let value_binding self vb =
      initValueBinding vb;
      super.value_binding self vb
    in
    {super with expr; value_binding}

  let update_transitivity vm =
    match find vm with
    | VS_Set s ->
      ValueSet.ElemSet.iter
        (fun v ->
          match v with
          | V_Expr eid ->
            let set' = find (VM_Expr eid) in
            addValueSet vm set'
          | V_Name id ->
            let set' = find (VM_Name id) in
            addValueSet vm set'
          | _ -> ())
        s
    | VS_Top -> ()

  let resolvePrimApp (prim : CL.Primitive.description) e app =
    match prim.prim_name with
    | "%addint" -> ()
    | _ ->
      let (Reduce (eid, arg1, args)) = app in
      addValueSet (ValueMeta.expr e) VS_Top;
      Current.liveness |> Liveness.join (VM_Expr eid) Live.Top;
      Some arg1 :: args
      |> List.iter (function
           | None -> ()
           | Some eid ->
             Current.liveness |> Liveness.join (VM_Expr eid) Live.Top);
      markSideEffect e

  let rec patIsTop pat =
    match pat.pat_desc with
    | Tpat_var (id, l) -> addValueSet (VM_Name (Id.create !Current.cmtModName id)) VS_Top
    | Tpat_alias (pat', id, l) ->
      addValueSet (VM_Name (Id.create !Current.cmtModName id)) VS_Top;
      patIsTop pat'
    | Tpat_or (pat1, pat2, _) ->
      patIsTop pat1;
      patIsTop pat2
    | Tpat_construct (_, _, pats) -> pats |> List.iter patIsTop
    | Tpat_variant (_, Some pat', _) -> patIsTop pat'
    | Tpat_tuple pats -> pats |> List.iter patIsTop
    | Tpat_array pats -> pats |> List.iter patIsTop
    | Tpat_lazy pat' -> patIsTop pat'
    | Tpat_record (fields, _) ->
      fields |> List.iter (fun (_, _, pat') -> patIsTop pat')
    | _ -> ()

  let rec stepBind pat expr =
    match pat.pat_desc with
    | Tpat_any -> ()
    | Tpat_var (id, l) -> addValue (VM_Name (Id.create !Current.cmtModName id)) (Value.expr expr)
    | Tpat_alias (pat', id, l) ->
      addValue (VM_Name (Id.create !Current.cmtModName id)) (Value.expr expr);
      stepBind pat' expr
    | Tpat_constant _ -> ()
    | Tpat_tuple pats -> (
      match find (ValueMeta.expr expr) with
      | VS_Top -> pats |> List.iter patIsTop
      | VS_Set vs ->
        vs
        |> ValueSet.ElemSet.iter (function
             | V_Field (F_Tuple i, eid) ->
               stepBind (List.nth pats i) (Expr.fromId eid)
             | _ -> ()))
    | Tpat_construct (lid, cstr_desc, pats) -> (
      match find (ValueMeta.expr expr) with
      | VS_Top -> pats |> List.iter patIsTop
      | VS_Set vs ->
        vs
        |> ValueSet.ElemSet.iter (fun v ->
               match v with
               | V_Cstr (cstr_desc', eids) when cstr_desc = cstr_desc' ->
                 List.combine pats eids
                 |> List.iter (fun (pat, eid) -> stepBind pat (Expr.fromId eid))
               | _ -> ()))
    | Tpat_variant (_, None, _) -> ()
    | Tpat_variant (lbl, Some pat, _) -> (
      match find (ValueMeta.expr expr) with
      | VS_Top -> patIsTop pat
      | VS_Set vs ->
        vs
        |> ValueSet.ElemSet.iter (function
             | V_Variant (lbl', eid) when lbl = lbl' ->
               stepBind pat (Expr.fromId eid)
             | _ -> ()))
    | Tpat_record (fields, closed_flag) -> (
      match find (ValueMeta.expr expr) with
      | VS_Top -> fields |> List.iter (fun (_, _, pat) -> patIsTop pat)
      | VS_Set vs ->
        vs
        |> ValueSet.ElemSet.iter (function
             | V_Field (F_Record lbl, eid) ->
               fields
               |> List.iter (fun (lid, lbl_desc, pat) ->
                      if lbl_desc.lbl_name = lbl then
                        stepBind pat (Expr.fromId eid))
             | _ -> ()))
    | Tpat_or (pat1, pat2, _) ->
      stepBind pat1 expr;
      stepBind pat2 expr
    | Tpat_array _ -> () (* TODO: array *)
    | Tpat_lazy _ -> ()

  let stepExpr e =
    match e.exp_desc with
    | Texp_let (ref_flag, vbs, exp) ->
      let valueBindingsHaveSideEffect =
        vbs
        |> List.fold_left
             (fun acc vb -> acc || vb.vb_expr |> Current.hasSideEffect)
             false
      in
      if valueBindingsHaveSideEffect || exp |> Current.hasSideEffect then
        markSideEffect e
    | Texp_apply _ ->
      Current.applications |> Reductions.find (Expr.toId e) |> ReductionSet.elements
      |> List.iter (fun app ->
             match app with
             | Reduce (eid, arg, tl) -> (
               if Current.isSideEffectFn (Expr.fromId eid) then markSideEffect e;
               match find (VM_Expr eid) with
               | VS_Top ->
                   markSideEffect e;
                   addValueSet (ValueMeta.expr e) VS_Top;
                   Current.liveness |> Liveness.join (VM_Expr arg) Live.Top;
                   tl |> List.iter (function None -> () | Some arg -> 
                     Current.liveness |> Liveness.join (VM_Expr arg) Live.Top
                   );

               | VS_Set s ->
                 s
                 |> ValueSet.ElemSet.iter (fun v ->
                        match v with
                        | V_Prim prim ->
                          if
                            tl |> List.for_all Option.is_some
                            && (tl |> List.length) + 1 = prim.prim_arity
                          then resolvePrimApp prim e app
                          else ()
                        | V_Fn (eid, param) -> (
                          let bodies = bodyOfFunction eid in
                          bodies
                          |> List.iter (fun body ->
                                 stepBind body.pat (Expr.fromId arg));
                          match tl with
                          | [] ->
                            bodies
                            |> List.iter (fun body ->
                                   addValue (ValueMeta.expr e)
                                     (V_Expr body.exp_id))
                          | Some arg' :: tl' ->
                            bodies
                            |> List.iter (fun body ->
                                   addReduction (Expr.toId e)
                                     (Reduce (body.exp_id, arg', tl')))
                          | None :: tl' ->
                            bodies
                            |> List.iter (fun body ->
                                   addValue (ValueMeta.expr e)
                                     (V_PartialApp (body.exp_id, tl'))))
                        | _ -> ())))
    | Texp_match (exp, cases, exn_cases, partial) ->
        cases |> List.iter (fun case -> stepBind case.c_lhs exp);
        let casesHasSideEffect =
          cases @ exn_cases |> List.fold_left (fun acc case -> acc || case.c_rhs |> Current.hasSideEffect) false
        in
        if casesHasSideEffect then markSideEffect e
    | Texp_field (exp, lid, ld) -> (
      match find (ValueMeta.expr exp) with
      | VS_Top -> ()
      | VS_Set vs ->
        vs
        |> ValueSet.ElemSet.iter (function
             | V_Field (f, eid) when Field.F_Record ld.lbl_name = f ->
               addValue (ValueMeta.expr exp) (V_Expr eid)
             | _ -> ()))
    | Texp_setfield (exp1, lid, ld, exp2) -> (
      match find (ValueMeta.expr exp1) with
      | VS_Top -> ()
      | VS_Set vs ->
        vs
        |> ValueSet.ElemSet.iter (function
             | V_Mutable (eid, f) when ld.lbl_name = f ->
               addValue (VM_Mutable (eid, f)) (Value.expr exp2)
             | _ -> ()))
    | Texp_function {arg_label; param; cases; partial} ->
      let bodyHasSideEffect =
        cases
        |> List.fold_left
             (fun acc case -> acc || case.c_rhs |> Current.hasSideEffect)
             false
      in
      if bodyHasSideEffect then addValue (ValueMeta.expr e) V_FnSideEffect
    | Texp_ifthenelse (exp1, exp2, Some exp3) ->
      if
        exp1 |> Current.hasSideEffect
        || exp2 |> Current.hasSideEffect
        || exp3 |> Current.hasSideEffect
      then markSideEffect e
    | Texp_sequence (exp1, exp2) ->
      if exp1 |> Current.hasSideEffect || exp2 |> Current.hasSideEffect then
        markSideEffect e
    | Texp_while (exp1, exp2) ->
      if exp1 |> Current.hasSideEffect || exp2 |> Current.hasSideEffect then
        markSideEffect e
    | Texp_for (id, pat, exp1, exp2, df, exp3) ->
      if
        exp1 |> Current.hasSideEffect
        || exp2 |> Current.hasSideEffect
        || exp3 |> Current.hasSideEffect
      then markSideEffect e
    | _ -> ()

  let stepMapper =
    let super = CL.Tast_mapper.default in
    let expr self e =
      stepExpr e;
      super.expr self e
    in
    let value_binding self vb =
      stepBind vb.vb_pat vb.vb_expr;
      super.value_binding self vb
    in
    {super with expr; value_binding}

  let runStructures strs =
    print_endline "############ closure init ##############";
    strs |> List.iter (fun (modname, str) ->
      Current.cmtModName := modname;
      initMapper.structure initMapper str |> ignore
    );
    updated := true;
    let counter = ref 0 in
    print_endline "############ closure step ##############";
    while !updated do
      counter := !counter + 1;
      Printf.printf "step %d" !counter;
      print_newline ();
      updated := false;
      Current.graph.nodes |> VMSet.iter (fun vm -> update_transitivity vm);
      strs
      |> List.iter (fun (modname, str) ->
          Current.cmtModName := modname;
          stepMapper.structure stepMapper str |> ignore
      )
    done;
    print_endline "############ closure end ##############"
end

let traverseTopMostExprMapper (f : expression -> bool) =
  let super = CL.Tast_mapper.default in
  let expr self e = if f e then e else super.expr self e in
  {super with expr}

let collectDeadValues cmts =
  let deads = ref VMSet.empty in
  let isDeadExpr e =
    let isDead =
      Current.liveness |> Liveness.get (ValueMeta.expr e) = Live.Bot
      && not (Current.hasSideEffect e)
    in
    if isDead then deads := !deads |> VMSet.add (ValueMeta.expr e);
    isDead
  in
  let mapper = traverseTopMostExprMapper isDeadExpr in
  cmts |> List.iter (fun (modname, str) -> mapper.structure mapper str |> ignore);
  Current.graph.nodes
  |> VMSet.iter (fun vm ->
         match vm with
         | VM_Name (name) ->
           if Current.liveness |> Liveness.get vm = Live.Bot then
             deads := !deads |> VMSet.add vm
         | _ -> ());
  !deads

module ValueDependency = struct
  let addEdge a b f =
    print_string "addEdge "; ValueMeta.print a; print_string " -> "; ValueMeta.print b; print_newline();
    Current.graph |> Graph.addEdge a b f
  let ( >> ) f g x = g (f x)

  module Func = struct
    let ifnotbot l : Live.t -> Live.t =
     fun x -> if Live.equal x Live.Bot then Live.Bot else l

    let iftop l : Live.t -> Live.t =
      fun x -> if Live.equal x Live.Top then l else Live.Bot
    let id : Live.t -> Live.t = fun x -> x
  end

  let collectPrimApp (prim : CL.Primitive.description) e app =
    let (Reduce (eid, eid2, args)) = app in
    match prim.prim_name with
    | _ ->
      addEdge (ValueMeta.expr e) (VM_Expr eid) (Func.ifnotbot Live.Top);
      Some eid2 :: args
      |> List.fold_left
           (fun acc argo ->
             match argo with None -> acc | Some eid -> eid :: acc)
           []
      |> List.iter (fun eid ->
             addEdge (ValueMeta.expr e) (VM_Expr eid) (Func.ifnotbot Live.Top))

  let rec collectBind pat expr (f : Live.t -> Live.t) =
    match pat.pat_desc with
    | Tpat_var (id, l) ->
      addEdge (VM_Name (Id.create !Current.cmtModName id)) (ValueMeta.expr expr) f
    | Tpat_alias (pat, id, l) ->
      addEdge (VM_Name (Id.create !Current.cmtModName id)) (ValueMeta.expr expr) f;
      collectBind pat expr f
    | Tpat_tuple pats ->
      pats
      |> List.iteri (fun i pat ->
             collectBind pat expr (Live.field (F_Tuple i) >> f))
    | Tpat_construct (lid, cstr_desc, pats) ->
      pats
      |> List.iteri (fun i pat ->
             collectBind pat expr (Live.constructi cstr_desc i >> f))
    | Tpat_variant (lbl, None, row) -> ()
    | Tpat_variant (lbl, Some pat, row) ->
      collectBind pat expr (Option.some >> Live.variant lbl >> f)
    | Tpat_record (fields, closed_flag) ->
      fields
      |> List.iter (fun (lid, label_desc, pat) ->
             collectBind pat expr
               (Live.field (F_Record label_desc.lbl_name) >> f))
    | Tpat_array pats ->
      pats
      |> List.iter (fun pat -> collectBind pat expr (Func.ifnotbot Live.Top))
    | Tpat_or (pat1, pat2, _) ->
      collectBind pat1 expr f;
      collectBind pat2 expr f
    | Tpat_lazy pat -> collectBind pat expr (Func.ifnotbot Live.Top)
    | Tpat_any -> ()
    | Tpat_constant _ -> ()

  let collectExpr e =
    match e.exp_desc with
    | Texp_ident (path, lid, vd) -> (
        match Current.env |> ModuleEnv.resolvePath !Current.cmtModName path with
        | [] -> ()
        | ids -> ids |> List.iter (fun id -> 
          addEdge (ValueMeta.expr e)
            (VM_Name (id))
            Func.id
        )
    )
    | Texp_constant _ -> ()
    | Texp_let (_, vbs, exp) ->
      addEdge (ValueMeta.expr e) (ValueMeta.expr exp) Func.id
    | Texp_function {arg_label; param; cases; partial} ->
        cases |> List.iter (fun case -> 
          addEdge (ValueMeta.expr e) (ValueMeta.expr case.c_rhs) (Func.ifnotbot Live.Top);
          addEdge (ValueMeta.expr e) (ValueMeta.expr case.c_rhs) (Func.iftop Live.Top)
        )
    | Texp_apply (exp, args) ->
      addEdge (ValueMeta.expr e) (ValueMeta.expr exp) (Func.ifnotbot Live.Top);
      Current.applications |> Reductions.find (Expr.toId e) |> ReductionSet.elements
      |> List.iter (fun app ->
             let (Reduce (eid, arg, tl)) = app in
             match Current.closure |> Closure.find (VM_Expr eid) with
             | VS_Top -> ()
             | VS_Set s ->
               s
               |> ValueSet.ElemSet.iter (fun v ->
                      match v with
                      | V_Prim prim ->
                        if
                          tl |> List.for_all Option.is_some
                          && (tl |> List.length) + 1 = prim.prim_arity
                        then collectPrimApp prim e app
                      | V_Fn (eid, param) ->
                        let bodies = bodyOfFunction eid in
                        addEdge (ValueMeta.expr e) (VM_Expr eid)
                          (Func.ifnotbot Live.Top);
                        bodies
                        |> List.iter (fun body ->
                               addEdge (ValueMeta.expr e) (VM_Expr body.exp_id)
                                 Func.id;
                               collectBind body.pat (Expr.fromId arg) Func.id)
                      | _ -> ()))
    | Texp_match (exp, cases, exn_cases, _) ->
      cases @ exn_cases
      |> List.iter (fun case ->
             addEdge (ValueMeta.expr e) (ValueMeta.expr case.c_rhs) Func.id;
             match case.c_guard with
             | Some guard ->
               addEdge (ValueMeta.expr e) (ValueMeta.expr guard)
                 (Func.ifnotbot Live.Top)
             | None -> ());
      let cond_base =
        cases
        |> List.map (fun case -> Live.controlledByPat case.c_lhs)
        |> List.fold_left Live.join Live.Bot
      in
      cases |> List.iter (fun case -> collectBind case.c_lhs exp Func.id);
      addEdge (ValueMeta.expr e) (ValueMeta.expr exp) (Func.ifnotbot cond_base)
    | Texp_try (exp, cases) ->
      addEdge (ValueMeta.expr e) (ValueMeta.expr exp) Func.id;
      cases
      |> List.iter (fun case ->
             addEdge (ValueMeta.expr e) (ValueMeta.expr case.c_rhs) Func.id;
             match case.c_guard with
             | Some guard ->
               addEdge (ValueMeta.expr e) (ValueMeta.expr guard)
                 (Func.ifnotbot Live.Top)
             | None -> ())
    | Texp_tuple exps ->
      exps
      |> List.iteri (fun i exp ->
             addEdge (ValueMeta.expr e) (ValueMeta.expr exp)
               (Live.field_inv (F_Tuple i)))
    | Texp_construct (lid, cstr_desc, exps) ->
      assert (List.length exps = cstr_desc.cstr_arity);
      exps
      |> List.iteri (fun i exp ->
             addEdge (ValueMeta.expr e) (ValueMeta.expr exp)
               (Live.construct_inv cstr_desc i))
    | Texp_variant (label, None) -> ()
    | Texp_variant (label, Some exp) ->
      addEdge (ValueMeta.expr e) (ValueMeta.expr exp) (Live.variant_inv label)
    | Texp_record {fields; representation; extended_expression} ->
      fields
      |> Array.iter (fun (label_desc, label_def) ->
             match label_def with
             | Kept _ -> ()
             | Overridden (lid, fe) -> (
               match label_desc.lbl_mut with
               | Immutable ->
                 addEdge (ValueMeta.expr e) (ValueMeta.expr fe)
                   (Live.field_inv (F_Record label_desc.lbl_name))
               | Mutable -> ()))
    | Texp_field (exp, lid, ld) ->
      addEdge (ValueMeta.expr e) (ValueMeta.expr exp)
        (Live.field (F_Record ld.lbl_name))
    | Texp_setfield (exp1, lid, label_desc, exp2) -> () (* FIXME *)
    | Texp_array exps ->
      exps
      |> List.iter (fun exp ->
             addEdge (ValueMeta.expr e) (ValueMeta.expr exp)
               (Func.ifnotbot Live.Top))
    | Texp_ifthenelse (exp1, exp2, Some exp3) ->
        addEdge (ValueMeta.expr e) (ValueMeta.expr exp1) (Func.ifnotbot Live.Top);
        addEdge (ValueMeta.expr e) (ValueMeta.expr exp2) Func.id;
        addEdge (ValueMeta.expr e) (ValueMeta.expr exp3) Func.id
    | Texp_ifthenelse _ -> ()
    | Texp_sequence (_, exp2) ->
      addEdge (ValueMeta.expr e) (ValueMeta.expr exp2) Func.id
    | Texp_while _ -> ()
    | Texp_for (id, ppat, exp1, exp2, dir_flag, exp_body) ->
      addEdge (VM_Name (Id.create !Current.cmtModName id)) (ValueMeta.expr exp1) Func.id;
      addEdge (VM_Name (Id.create !Current.cmtModName id)) (ValueMeta.expr exp2) Func.id
    | Texp_send (exp, meth, expo) ->
        addEdge (ValueMeta.expr e) (ValueMeta.expr exp) (Func.ifnotbot Live.Top)
    | _ -> ()

  let collectMapper =
    let super = CL.Tast_mapper.default in
    let expr self e =
      collectExpr e;
      super.expr self e
    in
    let value_binding self vb =
      collectBind vb.vb_pat vb.vb_expr Func.id;
      super.value_binding self vb
    in
    {super with expr; value_binding}
end


let addChild parent child =
  Current.env |> ModuleEnv.addMember parent child

let rec getSignature (moduleType : CL.Types.module_type) =
  match moduleType with
  | Mty_signature signature -> signature
  | Mty_functor _ -> (
    match moduleType |> Compat.getMtyFunctorModuleType with
    | Some (_, mt) -> getSignature mt
    | _ -> [])
  | _ -> []

let rec processSignatureItem ~parent
    (si : CL.Types.signature_item) =
  match si with
  | Sig_value _ ->
    print_endline "Sig_value";
    let id, loc, kind, valType = si |> Compat.getSigValue in
    let id = Id.create (!Current.cmtModName) id in
    Id.print parent;
    print_string " -> ";
    Id.print id;
    print_newline();
    addChild parent id
  | Sig_module _-> (
    print_endline "Sig_module";
    match si |> Compat.getSigModuleModtype with
    | Some (id, moduleType, moduleLoc) ->
        let id = Id.create (!Current.cmtModName) id in
        addChild parent id;
        getSignature moduleType
        |> List.iter 
             (processSignatureItem ~parent:id)
    | None -> ())
  | _ -> ()

let topLevelModuleId modname: CL.Ident.t =
  {name = modname; stamp=0; flags=0}

let processSignature (signature : CL.Types.signature) =
  signature
  |> List.iter (fun sig_item ->
         processSignatureItem
           ~parent:(Id.createTopLevelModuleId !Current.cmtModName)
           sig_item)


let process_module_expr me mid =
    let signature = getSignature me.mod_type in
    signature |> List.iter (fun sig_item ->
      processSignatureItem ~parent:mid sig_item
    )

let rec bind_member mod_id (pat: pattern) =
  match pat.pat_desc with
  | Tpat_var (id, _) -> addChild mod_id (Id.create !Current.cmtModName id)
  | Tpat_alias (p, id, _) ->
      addChild mod_id (Id.create !Current.cmtModName id);
      bind_member mod_id p
  | Tpat_tuple ps ->
      ps |> List.iter (bind_member mod_id)
  | Tpat_construct (_, _, ps) ->
      ps |> List.iter (bind_member mod_id)
  | Tpat_variant (_, Some p, _) -> bind_member mod_id p
  | Tpat_record (fs, _) ->
      fs |> List.iter (fun (_, _, p) -> bind_member mod_id p)
  | Tpat_array ps ->
      ps |> List.iter (bind_member mod_id)
  | Tpat_or (p1, p2, _) ->
      bind_member mod_id p1;
      bind_member mod_id p2
  | Tpat_lazy p ->
      bind_member mod_id p
  | _ -> ()

let process_value_binding mod_id vb =
  bind_member mod_id vb.vb_pat

let process_structure_item mod_id structureItem =
  print_endline "process_structure_item";
  match structureItem.str_desc with
  | Tstr_value (_, vbs) ->
      vbs |> List.iter (process_value_binding mod_id)
  | _ -> ()

let process_structure mod_id structure =
  structure.str_items |> List.iter (process_structure_item mod_id)

let rec process_module_expr mod_id module_expr =
  match module_expr.mod_desc with
  | Tmod_structure structure -> process_structure mod_id structure
  | Tmod_constraint (me, _, _, _) -> process_module_expr mod_id me
  | _ -> ()

let preprocessMapper =
  let super = CL.Tast_mapper.default in
  let expr self e =
    let e = super.expr self e in
    let e = Expr.preprocess e in
    preprocessFunction e;
    e
  in
  let module_binding self moduleBinding =
      Print.print_ident moduleBinding.mb_id;
      print_newline ();
      let id = Id.create !Current.cmtModName moduleBinding.mb_id in
      let signature = getSignature moduleBinding.mb_expr.mod_type in
      signature |> List.iter (fun sig_item ->
        processSignatureItem ~parent:id sig_item
      );
      process_module_expr id moduleBinding.mb_expr;
      super.module_binding self moduleBinding
  in
  {super with expr; module_binding}


(* collect structures from cmt *)
let targetCmtStructures : (string * structure) list ref = ref []


let reportDead ~ppf =
  print_endline "############ reportDead ##############";
  print_endline "################ Env #################";
  Current.env |> ModuleEnv.print;
  (* init liveness *)
  print_endline "############ init liveness ##############";
  Current.liveness |> Liveness.init (Current.graph.nodes |> VMSet.to_seq);
  (* closure analysis *)
  print_endline "############ closure analysis ##############";
  !targetCmtStructures |> ClosureAnalysis.runStructures;
  if !Common.Cli.debug then (
    print_endline "\n### Closure Analysis ###";
    Current.closure |> Closure.print;
    print_endline "\n### Reductions ###";
    Current.applications
    |> Hashtbl.iter (fun eid _ ->
        Printf.printf "Expr(%s): " eid;
           Current.applications |> Reductions.find eid |> ReductionSet.elements
           |> Print.print_list
                (function
                  | Reduce (eid, eid2, args) ->
                      Printf.printf "App(%s,[" eid;
                    Some eid2 :: args
                    |> Print.print_list
                         (fun arg ->
                           match arg with
                           | None -> print_string "-"
                           | Some eid -> print_string eid)
                         ",";
                    print_string "])")
                ", ";
           print_newline ()));
  (* liveness by side effect *)
  let mapper =
    let super = CL.Tast_mapper.default in
    let expr self e =
      Current.markValuesAffectSideEffect e;
      super.expr self e
    in
    {super with expr}
  in
  !targetCmtStructures |> List.iter (fun (modname, str) ->
    Current.cmtModName := modname;
    mapper.structure mapper str |> ignore);
  (* values dependencies *)
  print_endline
    "######################## Value Dependency #####################";
  let mapper = ValueDependency.collectMapper in
  !targetCmtStructures |> List.iter (fun (modname, str) ->
    Current.cmtModName := modname;
    mapper.structure mapper str |> ignore);
  (* tracking liveness *)
  print_endline
    "######################## Tracking Liveness #####################";
  let dag = Graph.scc Current.graph in
  if !Common.Cli.debug then (
    print_endline "\n### Track liveness ###";
    print_endline "* Topological order:";
    dag
    |> List.iter (fun nodes ->
           nodes |> Print.print_list ValueMeta.print ", ";
           print_newline ()));
  let dependentsLives node =
    let dependents = Hashtbl.find_all Current.graph.adj_rev node in
    dependents
    |> List.fold_left
         (fun acc (dep, f) ->
           Current.liveness |> Liveness.get dep |> f |> Live.join acc)
         Live.Bot
  in
  dag
  |> List.iter (fun nodes ->
         match nodes with
         | [] -> raise (RuntimeError "Empty SCC")
         | [node] ->
           (* ValueMeta.print node; *)
           Current.liveness |> Liveness.join node (dependentsLives node)
         | _ ->
           nodes
           |> List.iter (fun node ->
                  Current.liveness |> Liveness.join node Live.Top)
         (* nodes |> List.iter (fun node -> Current.liveness |> Liveness.meet node (dependentsLives node)); *));
  (* log dead values *)
  if !Common.Cli.debug then (
    print_endline "\n### Liveness, SideEffect ###";
    Current.liveness
    |> Hashtbl.iter (fun k v ->
           ValueMeta.print k;
           print_string ": ";
           Live.print v;
           (match k with
           | VM_Expr eid ->
             if !Current.sideEffectSet |> ExprIdSet.mem eid then
               print_string ", φ"
           | _ -> ());
           print_newline ()));
  print_endline "###########################################";
  print_endline "##                  DVA                  ##";
  print_endline "###########################################";
  let deadValues = collectDeadValues !targetCmtStructures in
  deadValues |> VMSet.elements
  |> List.iter (function vm -> vm |> ValueMeta.report ppf);
  print_newline ()

let processCmtStructure modname (structure : CL.Typedtree.structure) =
  print_endline "processCmtStructure";
  print_endline modname;
  Print.print_structure structure;
  print_newline ();
  structure.str_items |> List.iter (process_structure_item (Id.createTopLevelModuleId modname));
  let structure = preprocessMapper.structure preprocessMapper structure in
  targetCmtStructures := (modname, structure) :: !targetCmtStructures;
  let mapper =
    traverseValueMetaMapper (fun vm ->
        Current.graph.nodes <- VMSet.add vm Current.graph.nodes)
  in
  mapper.structure mapper structure |> ignore;
  (* let _ = Print.print_structure structure in *)
  ()

let processCmt (cmt_infos : CL.Cmt_format.cmt_infos) =
  Current.cmtModName := cmt_infos.cmt_modname;
  (match cmt_infos.cmt_annots with
  | Interface signature ->
    processSignature signature.sig_type
  | Implementation structure ->
    processSignature structure.str_type;
    processCmtStructure cmt_infos.cmt_modname structure
  | _ -> ())
