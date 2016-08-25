open Positions
open Syntax
open Stretch
open UnparameterizedSyntax
open Settings

(* When the original grammar is split over several files, it may be IMPOSSIBLE
   to print it out into a single file, as this will introduce a total ordering
   (between rules, between priority declarations, between %on_error_reduce
   declarations) that did not exist originally. We currently do not warn about
   this problem. Nobody has ever complained about it. *)

let print_preludes f g =
  List.iter (fun prelude ->
    Printf.fprintf f "%%{%s%%}\n" prelude.stretch_raw_content
  ) g.preludes

let print_start_symbols b g =
  StringSet.iter (fun symbol ->
    Printf.fprintf b "%%start %s\n" (Misc.normalize symbol)
  ) g.start_symbols

let print_ocamltype ocamltype =
  Printf.sprintf " <%s>" (
    match ocamltype with
    | Declared stretch ->
        stretch.stretch_raw_content
    | Inferred t ->
        t
    )

let print_parameter f stretch =
  Printf.fprintf f "%%parameter<%s>\n" stretch.stretch_raw_content

let print_assoc = function
  | LeftAssoc ->
      Printf.sprintf "%%left"
  | RightAssoc ->
      Printf.sprintf "%%right"
  | NonAssoc ->
      Printf.sprintf "%%nonassoc"
  | UndefinedAssoc ->
      ""

let compare_pairs compare1 compare2 (x1, x2) (y1, y2) =
  let c = compare1 x1 y1 in
  if c <> 0 then c
  else compare2 x2 y2

let compare_tokens (_token, prop) (_token', prop') =
  match prop.tk_precedence, prop'.tk_precedence with
  | UndefinedPrecedence, UndefinedPrecedence ->
      0
  | UndefinedPrecedence, PrecedenceLevel _ ->
      -1
  | PrecedenceLevel _, UndefinedPrecedence ->
      1
  | PrecedenceLevel (m, v, _, _), PrecedenceLevel (m', v', _, _) ->
      compare_pairs InputFile.compare_input_files Pervasives.compare (m, v) (m', v')

let print_tokens mode b g =
  (* Print the %token declarations. *)
  StringMap.iter (fun token prop ->
    if prop.tk_is_declared then
      Printf.fprintf b "%%token%s %s\n"
        begin match mode with
        | PrintNormal
        | PrintUnitActions ->
            Misc.o2s prop.tk_ocamltype print_ocamltype
        | PrintUnitActionsUnitTokens ->
            "" (* omitted ocamltype after %token means <unit> *)
        end
        token
  ) g.tokens;
  (* Sort the tokens wrt. precedence. *)
  let ordered_tokens = List.sort compare_tokens (StringMap.bindings g.tokens) in
  (* Print the precedence declarations: %left, %right, %nonassoc.
     This code is a bit trickier than I would like. *)
  let last_prop : token_properties option ref = ref None in
  List.iter (fun (token, (prop : token_properties)) ->
    match !last_prop with
    | Some prop' when prop.tk_precedence = prop'.tk_precedence ->
        (* Continue an existing declaration. *)
        Printf.fprintf b "%s " token
    | _ ->
        if prop.tk_precedence = UndefinedPrecedence then
          assert (!last_prop = None)
        else begin
          (* This is a new priority level. End the previous declaration,
             if there was one, then produce a new declaration. *)
          if !last_prop <> None then
            Printf.fprintf b "\n";
          Printf.fprintf b "%s %s "
            (print_assoc prop.tk_associativity) token;
          last_prop := Some prop
        end
  ) ordered_tokens;
  Printf.fprintf b "\n"

let print_types mode b g =
  StringMap.iter (fun symbol ty ->
    Printf.fprintf b "%%type%s %s\n"
      begin match mode with
      | PrintNormal ->
          print_ocamltype ty
      | PrintUnitActions
      | PrintUnitActionsUnitTokens ->
          " <unit>"
      end
      (Misc.normalize symbol)
  ) g.types

let binding mode id =
  match mode with
  | PrintNormal ->
      id ^ " = "
  | PrintUnitActions
  | PrintUnitActionsUnitTokens ->
      ""

let string_of_producer mode (symbol, ido) =
  binding mode ido ^ (Misc.normalize symbol)

let print_branch mode f branch =
  Printf.fprintf f "%s%s\n    {"
    (String.concat " " (List.map (string_of_producer mode) branch.producers))
    (Misc.o2s branch.branch_prec_annotation (fun x -> " %prec "^x.value));
  begin match mode with
  | PrintNormal ->
      Action.print f branch.action
  | PrintUnitActions
  | PrintUnitActionsUnitTokens ->
      () (* Printing a pair of empty braces is fine. *)
  end;
  Printf.fprintf f "}\n"

let print_postludes b g =
  List.iter (fun stretch -> Printf.fprintf b "%s\n" stretch.stretch_raw_content) g.postludes

(* Because the resolution of reduce/reduce conflicts is implicitly dictated by
   the order in which productions appear in the grammar, the printer should be
   careful to preserve this order. *)

(* 2016/08/25: As noted above, when two productions originate in different files,
   we have a problem. We MUST print them in some order, even though they should
   be incomparable. In that case, we use the order in which the source files are
   specified on the command line. However, this behavior is undocumented, and
   should not be exploited. (In previous versions of Menhir, the function passed
   to [List.sort] was not transitive, so it did not make any sense!) *)

let compare_branches (b : branch) (b' : branch) =
  match b.branch_production_level, b'.branch_production_level with
  | ProductionLevel (m, l), ProductionLevel (m', l') ->
      compare_pairs InputFile.compare_input_files Pervasives.compare (m, l) (m', l')

let compare_rules (_nt, (r : rule)) (_nt', (r' : rule)) =
  match r.branches, r'.branches with
  | [], [] ->
      0
  | [], _ ->
      -1
  | _, [] ->
      1
  | b :: _, b' :: _ ->
      (* To compare two rules, it suffices to compare their first productions. *)
      compare_branches b b'

let print_rules mode b g =
  let rules = List.sort compare_rules (StringMap.bindings g.rules) in
  List.iter (fun (nt, r) ->
    Printf.fprintf b "\n%s:\n" (Misc.normalize nt);
    let first = ref true in
    List.iter (fun br ->
      (* Menhir accepts a leading "|", but bison does not. Let's not print it. *)
      let sep = if !first then "  " else "| " in
      first := false;
      Printf.fprintf b "%s" sep;
      print_branch mode b br
    ) r.branches
  ) rules

let print mode f g =
  List.iter (print_parameter f) g.parameters;
  begin match mode with
  | PrintNormal ->
      print_preludes f g
  | PrintUnitActions
  | PrintUnitActionsUnitTokens ->
      ()
  end;
  print_start_symbols f g;
  print_tokens mode f g;
  print_types mode f g;
  Printf.fprintf f "%%%%\n";
  print_rules mode f g;
  Printf.fprintf f "\n%%%%\n";
  begin match mode with
  | PrintNormal ->
      print_postludes f g
  | PrintUnitActions
  | PrintUnitActionsUnitTokens ->
      ()
  end
