open Syntax

(* For each anonymous rule, we define a fresh nonterminal symbol, and
   replace the anonymous rule with a reference to this symbol. If the
   anonymous rule appears inside a parameterized rule, then we must
   define a parameterized nonterminal symbol. *)

(* ------------------------------------------------------------------------ *)

(* This functor makes it easy to share mutable internal state between
   the functions that follow. *)

module Run (X : sig end) = struct

(* ------------------------------------------------------------------------ *)

(* A fresh name generator. *)

let fresh : unit -> string =
  let next = ref 0 in
  fun () ->
    Printf.sprintf "__anonymous_%d" (Misc.postincrement next)

(* ------------------------------------------------------------------------ *)

(* A rule accumulator. Used to collect the fresh definitions that we
   produce. *)

let rules =
  ref []

(* ------------------------------------------------------------------------ *)

(* [anonymous pos parameters branches] deals with an anonymous rule,
   at position [pos], which appears inside a possibly-parameterized
   rule whose parameters are [parameters], and whose body is
   [branches]. We assume that [branches] does not itself contain any
   anonymous rules. As a side effect, we create a fresh definition,
   and return its name. *)

let var (symbol : symbol) : parameter =
  ParameterVar (Positions.with_pos Positions.dummy symbol)

let anonymous pos (parameters : symbol list) (branches : parameterized_branch list) : parameter =
  (* Generate a fresh non-terminal symbol. *)
  let symbol = fresh() in
  (* Construct its definition. Note that it is implicitly marked %inline. *)
  let rule = {
    pr_public_flag = false;
    pr_inline_flag = true;
    pr_nt          = symbol;
    pr_positions   = [ pos ]; (* this list is not allowed to be empty *)
    pr_parameters  = parameters;
    pr_branches    = branches
  } in
  (* Record this definition. *)
  rules := rule :: !rules;
  (* Return the symbol that stands for it. *)
  Parameters.app (Positions.with_pos pos symbol) (List.map var parameters)
      (* TEMPORARY should use as few parameters as possible *)

(* ------------------------------------------------------------------------ *)

(* Traversal code. *)

let rec transform_parameter (parameters : symbol list) (p : parameter) : parameter =
  match p with
  | ParameterVar _ ->
      p
  | ParameterApp (x, ps) ->
      ParameterApp (x, List.map (transform_parameter parameters) ps)
  | ParameterAnonymous branches ->
      let pos = Positions.position branches
      and branches = Positions.value branches in
      (* Do not forget the recursive invocation! *)
      let branches = List.map (transform_parameterized_branch parameters) branches in
      (* This is where the real work is done. *)
      anonymous pos parameters branches

and transform_producer parameters (x, p) =
  x, transform_parameter parameters p

and transform_parameterized_branch parameters branch =
  let pr_producers =
    List.map (transform_producer parameters) branch.pr_producers
  in
  { branch with pr_producers }

let transform_parameterized_rule rule =
  let pr_branches =
    List.map (transform_parameterized_branch rule.pr_parameters) rule.pr_branches
  in
  { rule with pr_branches }

end

(* ------------------------------------------------------------------------ *)

(* The main entry point invokes the functor and reads its result. *)

let transform_partial_grammar g =
  let module R = Run(struct end) in
  let pg_rules = List.map R.transform_parameterized_rule g.pg_rules in
  let pg_rules = !R.rules @ pg_rules in
  { g with pg_rules }
