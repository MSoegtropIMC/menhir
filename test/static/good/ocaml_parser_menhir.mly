/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           */
/*                                                                        */
/*   Copyright 1996 Institut National de Recherche en Informatique et     */
/*     en Automatique.                                                    */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

/* The parser definition */

%{
open Asttypes
open Longident
open Parsetree
open Ast_helper
open Docstrings
open Docstrings.WithMenhir

let mkloc = Location.mkloc
let mknoloc = Location.mknoloc

let mktyp ~loc d = Typ.mk ~loc d
let mkpat ~loc d = Pat.mk ~loc d
let mkexp ~loc d = Exp.mk ~loc d
let mkmty ~loc ?attrs d = Mty.mk ~loc ?attrs d
let mksig ~loc d = Sig.mk ~loc d
let mkmod ~loc ?attrs d = Mod.mk ~loc ?attrs d
let mkstr ~loc d = Str.mk ~loc d
let mkclass ~loc ?attrs d = Cl.mk ~loc ?attrs d
let mkcty ~loc ?attrs d = Cty.mk ~loc ?attrs d

let mkctf ~loc ?attrs ?docs d =
  Ctf.mk ~loc ?attrs ?docs d
let mkcf ~loc ?attrs ?docs d =
  Cf.mk ~loc ?attrs ?docs d

(* for now silently turn positions into locations *)
let rhs_loc pos = pos

let mkrhs rhs pos = mkloc rhs (rhs_loc pos)

let reloc_pat ~loc x = { x with ppat_loc = loc };;
let reloc_exp ~loc x = { x with pexp_loc = loc };;
let reloc_typ ~loc x = { x with ptyp_loc = loc };;

let mkoperator name pos =
  let loc = rhs_loc pos in
  Exp.mk ~loc (Pexp_ident(mkloc (Lident name) loc))

let mkpatvar name pos =
  Pat.mk ~loc:(rhs_loc pos) (Ppat_var (mkrhs name pos))

(*
  Ghost expressions and patterns:
  expressions and patterns that do not appear explicitly in the
  source file they have the loc_ghost flag set to true.
  Then the profiler will not try to instrument them and the
  -annot option will not try to display their type.

  Every grammar rule that generates an element with a location must
  make at most one non-ghost element, the topmost one.

  How to tell whether your location must be ghost:
  A location corresponds to a range of characters in the source file.
  If the location contains a piece of code that is syntactically
  valid (according to the documentation), and corresponds to the
  AST node, then the location must be real; in all other cases,
  it must be ghost.
*)
let ghexp ~loc d = Exp.mk ~loc:{ loc with Location.loc_ghost = true } d
let ghpat ~loc d = Pat.mk ~loc:{ loc with Location.loc_ghost = true } d
let ghtyp ~loc d = Typ.mk ~loc:{ loc with Location.loc_ghost = true } d
let ghloc ~loc d = { txt = d; loc = { loc with Location.loc_ghost = true } }
let ghstr ~loc d = Str.mk ~loc:{ loc with Location.loc_ghost = true } d
let ghsig ~loc d = Sig.mk ~loc:{ loc with Location.loc_ghost = true } d

let mkinfix arg1 op arg2 =
  Pexp_apply(op, [Nolabel, arg1; Nolabel, arg2])

let neg_string f =
  if String.length f > 0 && f.[0] = '-'
  then String.sub f 1 (String.length f - 1)
  else "-" ^ f

let mkuminus ~oploc name arg =
  match name, arg.pexp_desc with
  | "-", Pexp_constant(Pconst_integer (n,m)) ->
      Pexp_constant(Pconst_integer(neg_string n,m))
  | ("-" | "-."), Pexp_constant(Pconst_float (f, m)) ->
      Pexp_constant(Pconst_float(neg_string f, m))
  | _ ->
      Pexp_apply(mkoperator ("~" ^ name) oploc, [Nolabel, arg])

let mkuplus ~oploc name arg =
  let desc = arg.pexp_desc in
  match name, desc with
  | "+", Pexp_constant(Pconst_integer _)
  | ("+" | "+."), Pexp_constant(Pconst_float _) -> desc
  | _ ->
      Pexp_apply(mkoperator ("~" ^ name) oploc, [Nolabel, arg])

let mkexp_cons_desc consloc args =
  Pexp_construct(mkloc (Lident "::") consloc, Some args)
let mkexp_cons ~loc consloc args =
  mkexp ~loc (mkexp_cons_desc consloc args)

let mkpat_cons_desc consloc args =
  Ppat_construct(mkloc (Lident "::") consloc, Some args)
let mkpat_cons ~loc consloc args =
  mkpat ~loc (mkpat_cons_desc consloc args)

let rec mktailexp nilloc = let open Location in function
    [] ->
      let nil = ghloc ~loc:nilloc (Lident "[]") in
      Pexp_construct (nil, None), nilloc
  | e1 :: el ->
      let exp_el, el_loc = mktailexp nilloc el in
      let loc = {loc_start = e1.pexp_loc.loc_start;
                 loc_end = el_loc.loc_end;
                 loc_ghost = true}
      in
      let arg = ghexp ~loc (Pexp_tuple [e1; ghexp ~loc:el_loc exp_el]) in
      mkexp_cons_desc loc arg, loc

let rec mktailpat nilloc = let open Location in function
    [] ->
      let nil = ghloc ~loc:nilloc (Lident "[]") in
      Ppat_construct (nil, None), nilloc
  | p1 :: pl ->
      let pat_pl, el_loc = mktailpat nilloc pl in
      let loc = {loc_start = p1.ppat_loc.loc_start;
                 loc_end = el_loc.loc_end;
                 loc_ghost = true}
      in
      let arg = ghpat ~loc (Ppat_tuple [p1; ghpat ~loc:el_loc pat_pl]) in
      mkpat_cons_desc loc arg, loc

let mkstrexp e attrs =
  { pstr_desc = Pstr_eval (e, attrs); pstr_loc = e.pexp_loc }

let mkexp_constraint ~loc e (t1, t2) =
  let ghexp = ghexp ~loc in
  match t1, t2 with
  | Some t, None -> ghexp(Pexp_constraint(e, t))
  | _, Some t -> ghexp(Pexp_coerce(e, t1, t))
  | None, None -> assert false

let mkexp_opt_constraint ~loc e = function
  | None -> e
  | Some constraint_ -> mkexp_constraint ~loc e constraint_

let mkpat_opt_constraint ~loc p = function
  | None -> p
  | Some typ -> mkpat ~loc (Ppat_constraint(p, typ))

let syntax_error () =
  raise Syntaxerr.Escape_error

let unclosed opening_name opening_num closing_name closing_num =
  raise(Syntaxerr.Error(Syntaxerr.Unclosed(rhs_loc opening_num, opening_name,
                                           rhs_loc closing_num, closing_name)))

let expecting pos nonterm =
    raise Syntaxerr.(Error(Expecting(rhs_loc pos, nonterm)))

let not_expecting pos nonterm =
    raise Syntaxerr.(Error(Not_expecting(rhs_loc pos, nonterm)))

let dotop_fun ~loc dotop =
  (* We could use ghexp here, but sticking to mkexp for parser.mly
     compatibility. TODO improve parser.mly *)
  mkexp ~loc (Pexp_ident (ghloc ~loc dotop))

let array_function ~loc str name =
  ghloc ~loc (Ldot(Lident str, (if !Clflags.fast then "unsafe_" ^ name else name)))

let array_get_fun ~loc =
  ghexp ~loc (Pexp_ident(array_function ~loc "Array" "get"))
let string_get_fun ~loc =
  ghexp ~loc (Pexp_ident(array_function ~loc "String" "get"))

let array_set_fun ~loc =
  ghexp ~loc (Pexp_ident(array_function ~loc "Array" "set"))
let string_set_fun ~loc =
  ghexp ~loc (Pexp_ident(array_function ~loc "String" "set"))

let index_get ~loc get_fun array index =
  let args = [Nolabel, array; Nolabel, index] in
   mkexp ~loc (Pexp_apply(get_fun, args))

let index_set ~loc set_fun array index value =
  let args = [Nolabel, array; Nolabel, index; Nolabel, value] in
   mkexp ~loc (Pexp_apply(set_fun, args))

let array_get ~loc = index_get ~loc (array_get_fun ~loc)
let string_get ~loc = index_get ~loc (string_get_fun ~loc)
let dotop_get ~loc dotop = index_get ~loc (dotop_fun ~loc dotop)

let array_set ~loc = index_set ~loc (array_set_fun ~loc)
let string_set ~loc = index_set ~loc (string_set_fun ~loc)
let dotop_set ~loc dotop = index_set ~loc (dotop_fun ~loc dotop)

let bigarray_function ~loc str name =
  ghloc ~loc (Ldot(Ldot(Lident "Bigarray", str), name))

let bigarray_untuplify = function
    { pexp_desc = Pexp_tuple explist; pexp_loc = _ } -> explist
  | exp -> [exp]

let bigarray_get ~loc arr arg =
  let mkexp, ghexp = mkexp ~loc, ghexp ~loc in
  let bigarray_function = bigarray_function ~loc in
  let get = if !Clflags.fast then "unsafe_get" else "get" in
  match bigarray_untuplify arg with
    [c1] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array1" get)),
                       [Nolabel, arr; Nolabel, c1]))
  | [c1;c2] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array2" get)),
                       [Nolabel, arr; Nolabel, c1; Nolabel, c2]))
  | [c1;c2;c3] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array3" get)),
                       [Nolabel, arr; Nolabel, c1; Nolabel, c2; Nolabel, c3]))
  | coords ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Genarray" "get")),
                       [Nolabel, arr; Nolabel, ghexp(Pexp_array coords)]))

let bigarray_set ~loc arr arg newval =
  let mkexp, ghexp = mkexp ~loc, ghexp ~loc in
  let bigarray_function = bigarray_function ~loc in
  let set = if !Clflags.fast then "unsafe_set" else "set" in
  match bigarray_untuplify arg with
    [c1] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array1" set)),
                       [Nolabel, arr; Nolabel, c1; Nolabel, newval]))
  | [c1;c2] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array2" set)),
                       [Nolabel, arr; Nolabel, c1;
                        Nolabel, c2; Nolabel, newval]))
  | [c1;c2;c3] ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Array3" set)),
                       [Nolabel, arr; Nolabel, c1;
                        Nolabel, c2; Nolabel, c3; Nolabel, newval]))
  | coords ->
      mkexp(Pexp_apply(ghexp(Pexp_ident(bigarray_function "Genarray" "set")),
                       [Nolabel, arr;
                        Nolabel, ghexp(Pexp_array coords);
                        Nolabel, newval]))

let lapply p1 p2 =
  if !Clflags.applicative_functors
  then Lapply(p1, p2)
  else raise (Syntaxerr.Error(Syntaxerr.Applicative_path (Location.symbol_rloc())))

let exp_of_longident ~loc {Location.txt = lid; loc = var_loc} =
  mkexp ~loc (Pexp_ident(mkrhs (Lident(Longident.last lid)) var_loc))

let exp_of_label ~loc {Location.txt = lbl; loc = var_loc} =
  mkexp ~loc (Pexp_ident(mkrhs (Lident lbl) var_loc))

let pat_of_label ~loc {Location.txt = lbl; loc = var_loc} =
  mkpat ~loc (Ppat_var(mkrhs (Longident.last lbl) var_loc))

let mk_newtypes ~loc newtypes exp =
  let mkexp = mkexp ~loc in
  List.fold_right (fun newtype exp -> mkexp (Pexp_newtype (newtype, exp)))
    newtypes exp

let wrap_type_annotation ~loc newtypes core_type body =
  let mkexp, ghtyp = mkexp ~loc, ghtyp ~loc in
  let mk_newtypes = mk_newtypes ~loc in
  let exp = mkexp(Pexp_constraint(body,core_type)) in
  let exp = mk_newtypes newtypes exp in
  (exp, ghtyp(Ptyp_poly(newtypes, Typ.varify_constructors newtypes core_type)))

let wrap_exp_attrs ~loc body (ext, attrs) =
  let ghexp = ghexp ~loc in
  (* todo: keep exact location for the entire attribute *)
  let body = {body with pexp_attributes = attrs @ body.pexp_attributes} in
  match ext with
  | None -> body
  | Some id -> ghexp(Pexp_extension (id, PStr [mkstrexp body []]))

let mkexp_attrs ~loc d attrs =
  wrap_exp_attrs ~loc (mkexp ~loc d) attrs

let wrap_typ_attrs ~loc typ (ext, attrs) =
  (* todo: keep exact location for the entire attribute *)
  let typ = {typ with ptyp_attributes = attrs @ typ.ptyp_attributes} in
  match ext with
  | None -> typ
  | Some id -> ghtyp ~loc (Ptyp_extension (id, PTyp typ))

let wrap_pat_attrs ~loc pat (ext, attrs) =
  (* todo: keep exact location for the entire attribute *)
  let pat = {pat with ppat_attributes = attrs @ pat.ppat_attributes} in
  match ext with
  | None -> pat
  | Some id -> ghpat ~loc (Ppat_extension (id, PPat (pat, None)))

let mkpat_attrs ~loc d attrs =
  wrap_pat_attrs ~loc (mkpat ~loc d) attrs

let wrap_class_attrs ~loc:_ body attrs =
  {body with pcl_attributes = attrs @ body.pcl_attributes}
let wrap_mod_attrs ~loc:_ body attrs =
  {body with pmod_attributes = attrs @ body.pmod_attributes}
let wrap_mty_attrs ~loc:_ body attrs =
  {body with pmty_attributes = attrs @ body.pmty_attributes}

let wrap_str_ext ~loc body ext =
  match ext with
  | None -> body
  | Some id -> ghstr ~loc (Pstr_extension ((id, PStr [body]), []))

let wrap_sig_ext ~loc body ext =
  match ext with
  | None -> body
  | Some id -> ghsig ~loc (Psig_extension ((id, PSig [body]), []))

let text_str pos = Str.text (rhs_text pos)
let text_sig pos = Sig.text (rhs_text pos)
let text_cstr pos = Cf.text (rhs_text pos)
let text_csig pos = Ctf.text (rhs_text pos)
let text_def pos = [Ptop_def (Str.text (rhs_text pos))]

let extra_text startpos endpos text items =
  match items with
  | [] ->
      let post = rhs_post_text endpos in
      let post_extras = rhs_post_extra_text endpos in
      text post @ text post_extras
  | _ :: _ ->
      let pre_extras = rhs_pre_extra_text startpos in
      let post_extras = rhs_post_extra_text endpos in
        text pre_extras @ items @ text post_extras

let extra_str p1 p2 items = extra_text p1 p2 Str.text items
let extra_sig p1 p2 items = extra_text p1 p2 Sig.text items
let extra_cstr p1 p2 items = extra_text p1 p2 Cf.text items
let extra_csig p1 p2 items = extra_text p1 p2 Ctf.text  items
let extra_def p1 p2 items =
  extra_text p1 p2 (fun txt -> [Ptop_def (Str.text txt)]) items

let extra_rhs_core_type ct ~pos =
  let docs = rhs_info pos in
  { ct with ptyp_attributes = add_info_attrs docs ct.ptyp_attributes }

type let_binding =
  { lb_pattern: pattern;
    lb_expression: expression;
    lb_attributes: attributes;
    lb_docs: docs Lazy.t;
    lb_text: text Lazy.t;
    lb_loc: Location.t; }

type let_bindings =
  { lbs_bindings: let_binding list;
    lbs_rec: rec_flag;
    lbs_extension: string Asttypes.loc option;
    lbs_loc: Location.t }

let mklb first ~loc (p, e) attrs =
  let open Location in {
    lb_pattern = p;
    lb_expression = e;
    lb_attributes = attrs;
    lb_docs = symbol_docs_lazy loc.loc_start loc.loc_end;
    lb_text = (if first then empty_text_lazy
               else symbol_text_lazy loc.loc_start);
    lb_loc = loc;
  }

let mklbs ~loc ext rf lb =
  {
    lbs_bindings = [lb];
    lbs_rec = rf;
    lbs_extension = ext ;
    lbs_loc = loc;
  }

let addlb lbs lb =
  { lbs with lbs_bindings = lb :: lbs.lbs_bindings }

let val_of_let_bindings ~loc lbs =
  let bindings =
    List.map
      (fun lb ->
         Vb.mk ~loc:lb.lb_loc ~attrs:lb.lb_attributes
           ~docs:(Lazy.force lb.lb_docs)
           ~text:(Lazy.force lb.lb_text)
           lb.lb_pattern lb.lb_expression)
      lbs.lbs_bindings
  in
  let str = mkstr ~loc (Pstr_value(lbs.lbs_rec, List.rev bindings)) in
  match lbs.lbs_extension with
  | None -> str
  | Some id -> ghstr ~loc (Pstr_extension((id, PStr [str]), []))

let expr_of_let_bindings ~loc lbs body =
  let bindings =
    List.map
      (fun lb ->
         Vb.mk ~loc:lb.lb_loc ~attrs:lb.lb_attributes
           lb.lb_pattern lb.lb_expression)
      lbs.lbs_bindings
  in
    mkexp_attrs ~loc (Pexp_let(lbs.lbs_rec, List.rev bindings, body))
      (lbs.lbs_extension, [])

let class_of_let_bindings ~loc lbs body =
  let bindings =
    List.map
      (fun lb ->
         Vb.mk ~loc:lb.lb_loc ~attrs:lb.lb_attributes
           lb.lb_pattern lb.lb_expression)
      lbs.lbs_bindings
  in
    if lbs.lbs_extension <> None then
      raise Syntaxerr.(Error(Not_expecting(lbs.lbs_loc, "extension")));
    mkclass ~loc (Pcl_let (lbs.lbs_rec, List.rev bindings, body))

let make_loc startpos endpos = {
  Location.loc_start = startpos;
  Location.loc_end = endpos;
  Location.loc_ghost = false;
}

(* Alternatively, we could keep the generic module type in the Parsetree
   and extract the package type during type-checking. In that case,
   the assertions below should be turned into explicit checks. *)
let package_type_of_module_type pmty =
  let err loc s =
    raise (Syntaxerr.Error (Syntaxerr.Invalid_package_type (loc, s)))
  in
  let map_cstr = function
    | Pwith_type (lid, ptyp) ->
        let loc = ptyp.ptype_loc in
        if ptyp.ptype_params <> [] then
          err loc "parametrized types are not supported";
        if ptyp.ptype_cstrs <> [] then
          err loc "constrained types are not supported";
        if ptyp.ptype_private <> Public then
          err loc "private types are not supported";

        (* restrictions below are checked by the 'with_constraint' rule *)
        assert (ptyp.ptype_kind = Ptype_abstract);
        assert (ptyp.ptype_attributes = []);
        let ty =
          match ptyp.ptype_manifest with
          | Some ty -> ty
          | None -> assert false
        in
        (lid, ty)
    | _ ->
        err pmty.pmty_loc "only 'with type t =' constraints are supported"
  in
  match pmty with
  | {pmty_desc = Pmty_ident lid} -> (lid, [])
  | {pmty_desc = Pmty_with({pmty_desc = Pmty_ident lid}, cstrs)} ->
      (lid, List.map map_cstr cstrs)
  | _ ->
      err pmty.pmty_loc
        "only module type identifier and 'with type' constraints are supported"

%}

/* Tokens */

%token AMPERAMPER
%token AMPERSAND
%token AND
%token AS
%token ASSERT
%token BACKQUOTE
%token BANG
%token BAR
%token BARBAR
%token BARRBRACKET
%token BEGIN
%token <char> CHAR
%token CLASS
%token COLON
%token COLONCOLON
%token COLONEQUAL
%token COLONGREATER
%token COMMA
%token CONSTRAINT
%token DO
%token DONE
%token DOT
%token DOTDOT
%token DOWNTO
%token ELSE
%token END
%token EOF
%token EQUAL
%token EXCEPTION
%token EXTERNAL
%token FALSE
%token <string * char option> FLOAT
%token FOR
%token FUN
%token FUNCTION
%token FUNCTOR
%token GREATER
%token GREATERRBRACE
%token GREATERRBRACKET
%token IF
%token IN
%token INCLUDE
%token <string> INFIXOP0
%token <string> INFIXOP1
%token <string> INFIXOP2
%token <string> INFIXOP3
%token <string> INFIXOP4
%token <string> DOTOP
%token INHERIT
%token INITIALIZER
%token <string * char option> INT
%token <string> LABEL
%token LAZY
%token LBRACE
%token LBRACELESS
%token LBRACKET
%token LBRACKETBAR
%token LBRACKETLESS
%token LBRACKETGREATER
%token LBRACKETPERCENT
%token LBRACKETPERCENTPERCENT
%token LESS
%token LESSMINUS
%token LET
%token <string> LIDENT
%token LPAREN
%token LBRACKETAT
%token LBRACKETATAT
%token LBRACKETATATAT
%token MATCH
%token METHOD
%token MINUS
%token MINUSDOT
%token MINUSGREATER
%token MODULE
%token MUTABLE
%token NEW
%token NONREC
%token OBJECT
%token OF
%token OPEN
%token <string> OPTLABEL
%token OR
/* %token PARSER */
%token PERCENT
%token PLUS
%token PLUSDOT
%token PLUSEQ
%token <string> PREFIXOP
%token PRIVATE
%token QUESTION
%token QUOTE
%token RBRACE
%token RBRACKET
%token REC
%token RPAREN
%token SEMI
%token SEMISEMI
%token HASH
%token <string> HASHOP
%token SIG
%token STAR
%token <string * string option> STRING
%token STRUCT
%token THEN
%token TILDE
%token TO
%token TRUE
%token TRY
%token TYPE
%token <string> UIDENT
%token UNDERSCORE
%token VAL
%token VIRTUAL
%token WHEN
%token WHILE
%token WITH
%token <string * Location.t> COMMENT
%token <Docstrings.docstring> DOCSTRING

%token EOL

/* Precedences and associativities.

Tokens and rules have precedences.  A reduce/reduce conflict is resolved
in favor of the first rule (in source file order).  A shift/reduce conflict
is resolved by comparing the precedence and associativity of the token to
be shifted with those of the rule to be reduced.

By default, a rule has the precedence of its rightmost terminal (if any).

When there is a shift/reduce conflict between a rule and a token that
have the same precedence, it is resolved using the associativity:
if the token is left-associative, the parser will reduce; if
right-associative, the parser will shift; if non-associative,
the parser will declare a syntax error.

We will only use associativities with operators of the kind  x * x -> x
for example, in the rules of the form    expr: expr BINOP expr
in all other cases, we define two precedences if needed to resolve
conflicts.

The precedences must be listed from low to high.
*/

%nonassoc IN
%nonassoc below_SEMI
%nonassoc SEMI                          /* below EQUAL ({lbl=...; lbl=...}) */
%nonassoc LET                           /* above SEMI ( ...; let ... in ...) */
%nonassoc below_WITH
%nonassoc FUNCTION WITH                 /* below BAR  (match ... with ...) */
%nonassoc AND             /* above WITH (module rec A: SIG with ... and ...) */
%nonassoc THEN                          /* below ELSE (if ... then ...) */
%nonassoc ELSE                          /* (if ... then ... else ...) */
%nonassoc LESSMINUS                     /* below COLONEQUAL (lbl <- x := e) */
%right    COLONEQUAL                    /* expr (e := e := e) */
%nonassoc AS
%left     BAR                           /* pattern (p|p|p) */
%nonassoc below_COMMA
%left     COMMA                         /* expr/expr_comma_list (e,e,e) */
%right    MINUSGREATER                  /* core_type2 (t -> t -> t) */
%right    OR BARBAR                     /* expr (e || e || e) */
%right    AMPERSAND AMPERAMPER          /* expr (e && e && e) */
%nonassoc below_EQUAL
%left     INFIXOP0 EQUAL LESS GREATER   /* expr (e OP e OP e) */
%right    INFIXOP1                      /* expr (e OP e OP e) */
%nonassoc below_LBRACKETAT
%nonassoc LBRACKETAT
%nonassoc LBRACKETATAT
%right    COLONCOLON                    /* expr (e :: e :: e) */
%left     INFIXOP2 PLUS PLUSDOT MINUS MINUSDOT PLUSEQ /* expr (e OP e OP e) */
%left     PERCENT INFIXOP3 STAR                 /* expr (e OP e OP e) */
%right    INFIXOP4                      /* expr (e OP e OP e) */
%nonassoc prec_unary_minus prec_unary_plus /* unary - */
%nonassoc prec_constant_constructor     /* cf. simple_expr (C versus C x) */
%nonassoc prec_constr_appl              /* above AS BAR COLONCOLON COMMA */
%nonassoc below_HASH
%nonassoc HASH                         /* simple_expr/toplevel_directive */
%left     HASHOP
%nonassoc below_DOT
%nonassoc DOT DOTOP
/* Finally, the first tokens of simple_expr are above everything else. */
%nonassoc BACKQUOTE BANG BEGIN CHAR FALSE FLOAT INT
          LBRACE LBRACELESS LBRACKET LBRACKETBAR LIDENT LPAREN
          NEW PREFIXOP STRING TRUE UIDENT
          LBRACKETPERCENT LBRACKETPERCENTPERCENT


/* Entry points */

%start implementation                   /* for implementation files */
%type <Parsetree.structure> implementation
%start interface                        /* for interface files */
%type <Parsetree.signature> interface
%start toplevel_phrase                  /* for interactive use */
%type <Parsetree.toplevel_phrase> toplevel_phrase
%start use_file                         /* for the #use directive */
%type <Parsetree.toplevel_phrase list> use_file
%start parse_core_type
%type <Parsetree.core_type> parse_core_type
%start parse_expression
%type <Parsetree.expression> parse_expression
%start parse_pattern
%type <Parsetree.pattern> parse_pattern
%%

/* macros */
%inline extra_str(symb): symb { extra_str $startpos $endpos $1 };
%inline extra_sig(symb): symb { extra_sig $startpos $endpos $1 };
%inline extra_cstr(symb): symb { extra_cstr $startpos $endpos $1 };
%inline extra_csig(symb): symb { extra_csig $startpos $endpos $1 };
%inline extra_def(symb): symb { extra_def $startpos $endpos $1 };
%inline extra_text(symb): symb { extra_text $startpos $endpos $1 };

%inline mkrhs(symb): symb
    {
      (* Semantically we could use $symbolstartpos instead of $startpos
         here, but the code comes from calls to (Parsing.rhs_loc p) for
         some position p, which rather corresponds to
         $startpos, so we kept it for compatibility.

         I do not know if mkrhs is ever used in a situation where $startpos
         and $symbolpos do not coincide.  *)
      mkrhs $1 (make_loc $startpos $endpos) }
;

%inline op(symb): symb
   { (* see the mkrhs comment above
        for the choice of $startpos over $symbolstartpos *)
     mkoperator $1 (make_loc $startpos $endpos) }

%inline mkloc(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkloc $1 loc }

%inline mkexp(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkexp ~loc $1 }
%inline mkpat(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkpat ~loc $1 }
%inline mktyp(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mktyp ~loc $1 }
%inline mksig(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mksig ~loc $1 }
%inline mkmod(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkmod ~loc $1 }
%inline mkmty(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkmty ~loc $1 }
%inline mkcty(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkcty ~loc $1 }
%inline mkctf(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkctf ~loc $1 }
%inline mkcf(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkcf ~loc $1 }
%inline mkclass(symb): symb
    { let loc = make_loc $symbolstartpos $endpos in
      mkclass ~loc $1 }

%inline only_loc(symb): symb { make_loc $startpos $endpos }
%inline with_loc(symb): symb { ($1, make_loc $startpos $endpos) }

/* Entry points */

implementation:
    structure EOF                        { $1 }
;

interface:
    signature EOF                        { $1 }
;

toplevel_phrase:
    top_structure SEMISEMI               { Ptop_def ($1) }
  | toplevel_directive SEMISEMI          { $1 }
  | EOF                                  { raise End_of_file }
;
top_structure: extra_str(top_structure_nodoc) { $1 }
top_structure_nodoc:
    seq_expr post_item_attributes
      { text_str $startpos($1) @ [mkstrexp $1 $2] }
  | top_structure_tail_nodoc
      { $1 }
;
top_structure_tail_nodoc:
    /* empty */                              { [] }
  | structure_item top_structure_tail_nodoc  { text_str $startpos($1) @ $1 :: $2 }
;

use_file:
    extra_def(use_file_body)             { $1 }
/* TODO Menhir reports:
   > Warning: production use_file_tail -> is never reduced.

   This warning can be fixed by adding an EOF token
   at the end of the use_file production. Is this
   the right move?
*/
;
use_file_body:
    use_file_tail                        { $1 }
  | seq_expr post_item_attributes use_file_tail
      { text_def $startpos($1) @ Ptop_def[mkstrexp $1 $2] :: $3 }
;
use_file_tail:
    /* empty */
      { [] }
  | SEMISEMI use_file_body
      { $2 }
  | structure_item use_file_tail
      { text_def $startpos($1) @ Ptop_def[$1] :: $2 }
  | toplevel_directive use_file_tail
      { mark_rhs_docs $startpos($1) $endpos($1);
        text_def $startpos($1) @ $1 :: $2 }
;

parse_core_type:
    core_type EOF { $1 }
;

parse_expression:
    seq_expr EOF { $1 }
;

parse_pattern:
    pattern EOF { $1 }
;

/* Module expressions */

functor_arg:
    mkrhs(LPAREN RPAREN {"*"})
      { $1, None }
  | LPAREN mkrhs(functor_arg_name) COLON module_type RPAREN
      { $2, Some $4 }
;

functor_arg_name:
    UIDENT     { $1 }
  | UNDERSCORE { "_" }
;

functor_args:
    functor_args functor_arg
      { $2 :: $1 }
  | functor_arg
      { [ $1 ] }
;

module_expr:
  | STRUCT attributes structure END
      { let loc = make_loc $symbolstartpos $endpos in
        mkmod ~loc ~attrs:$2 (Pmod_structure($3)) }
  | only_loc(STRUCT) attributes structure only_loc(error)
      { unclosed "struct" $1 "end" $4 }
  | FUNCTOR attributes functor_args MINUSGREATER module_expr
      { let loc = make_loc $symbolstartpos $endpos in
        let modexp =
          List.fold_left
            (fun acc (n, t) -> mkmod ~loc (Pmod_functor(n, t, acc)))
            $5 $3
        in wrap_mod_attrs ~loc modexp $2 }
  | mkmod(module_expr2)
      { $1 }
  | paren_module_expr
      { $1 }
  | module_expr attribute
      { Mod.attr $1 $2 }
;
%inline module_expr2:
  | mkrhs(mod_longident)
    { Pmod_ident $1 }
  | module_expr paren_module_expr
    { Pmod_apply($1, $2) }
  | module_expr with_loc(LPAREN RPAREN { Pmod_structure [] })
    { let loc = make_loc $symbolstartpos $endpos in
      (* TODO review mkmod location *)
      Pmod_apply($1, mkmod ~loc (fst $2)) }
  | extension
    { Pmod_extension $1 }
;

paren_module_expr:
    mkmod(LPAREN module_expr COLON module_type RPAREN
      { Pmod_constraint($2, $4) })
      { $1 }
  | only_loc(LPAREN) module_expr COLON module_type only_loc(error)
      { unclosed "(" $1 ")" $5 }
  | LPAREN module_expr RPAREN
      { $2 }
  | only_loc(LPAREN) module_expr only_loc(error)
      { unclosed "(" $1 ")" $3 }
  | LPAREN VAL attributes expr RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        mkmod ~loc ~attrs:$3 (Pmod_unpack $4)}
  | LPAREN VAL attributes expr COLON package_type RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        let constr_loc = make_loc $startpos($4) $endpos($6) in
        mkmod ~loc ~attrs:$3
          (Pmod_unpack(
               ghexp ~loc:constr_loc (Pexp_constraint($4, $6)))) }
  | LPAREN VAL attributes expr COLON package_type COLONGREATER package_type
    RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        let constr_loc = make_loc $startpos($4) $endpos($8) in
        mkmod ~loc ~attrs:$3
          (Pmod_unpack(
               ghexp ~loc:constr_loc (Pexp_coerce($4, Some $6, $8)))) }
  | LPAREN VAL attributes expr COLONGREATER package_type RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        let constr_loc = make_loc $startpos($4) $endpos($6) in
        mkmod ~loc ~attrs:$3
          (Pmod_unpack(
               ghexp ~loc:constr_loc (Pexp_coerce($4, None, $6)))) }
  | only_loc(LPAREN) VAL attributes expr COLON only_loc(error)
      { unclosed "(" $1 ")" $6 }
  | only_loc(LPAREN) VAL attributes expr COLONGREATER only_loc(error)
      { unclosed "(" $1 ")" $6 }
  | only_loc(LPAREN) VAL attributes expr only_loc(error)
      { unclosed "(" $1 ")" $5 }
;

structure: extra_str(structure_nodoc) { $1 }
structure_nodoc:
    seq_expr post_item_attributes structure_tail_nodoc
      { mark_rhs_docs $startpos($1) $endpos($2);
        text_str $startpos($1) @ mkstrexp $1 $2 :: $3 }
  | structure_tail_nodoc { $1 }
;
structure_tail_nodoc:
    /* empty */                         { [] }
  | SEMISEMI structure_nodoc            { text_str $startpos($1) @ $2 }
  | structure_item structure_tail_nodoc { text_str $startpos($1) @ $1 :: $2 }
;

structure_item:
    let_bindings
      { let loc = make_loc $symbolstartpos $endpos in
        val_of_let_bindings ~loc $1 }
  | structure_item_with_ext
      { let item, ext = $1 in
        let loc = make_loc $startpos $endpos in
        wrap_str_ext ~loc (mkstr ~loc item) ext }
  | item_extension post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkstr ~loc (Pstr_extension ($1, (add_docs_attrs docs $2))) }
  | floating_attribute
      { let loc = make_loc $symbolstartpos $endpos in
        mkstr ~loc (Pstr_attribute $1) }
;
structure_item_with_ext:
  | primitive_declaration
      { let (body, ext) = $1 in (Pstr_primitive body, ext) }
  | value_description
      { let (body, ext) = $1 in (Pstr_primitive body, ext) }
  | type_declarations
      { let (nr, l, ext ) = $1 in (Pstr_type (nr, List.rev l), ext) }
  | str_type_extension
      { let (l, ext) = $1 in (Pstr_typext l, ext) }
  | str_exception_declaration
      { let (l, ext) = $1 in (Pstr_exception l, ext) }
  | module_binding
      { let (body, ext) = $1 in (Pstr_module body, ext) }
  | rec_module_bindings
      { let (l, ext) = $1 in (Pstr_recmodule (List.rev l), ext) }
  | module_type_declaration
      { let (body, ext) = $1 in (Pstr_modtype body, ext) }
  | open_statement
      { let (body, ext) = $1 in (Pstr_open body, ext) }
  | class_declarations
      { let (l, ext) = $1 in (Pstr_class (List.rev l), ext) }
  | class_type_declarations
      { let (l, ext) = $1 in (Pstr_class_type (List.rev l), ext) }
  | str_include_statement
      { let (body, ext) = $1 in (Pstr_include body, ext) }
;

str_include_statement:
    INCLUDE ext_attributes module_expr post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Incl.mk $3 ~attrs:(attrs@$4) ~loc ~docs, ext }
;
module_binding_body:
    EQUAL module_expr
      { $2 }
  | mkmod(
      COLON module_type EQUAL module_expr
        { Pmod_constraint($4, $2) }
    | functor_arg module_binding_body
        { Pmod_functor(fst $1, snd $1, $2) }
  ) { $1 }
;
module_binding:
    MODULE ext_attributes mkrhs(UIDENT) module_binding_body post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Mb.mk $3 $4 ~attrs:(attrs@$5) ~loc ~docs, ext }
;
rec_module_bindings:
    rec_module_binding
      { let (b, ext) = $1 in ([b], ext) }
  | rec_module_bindings and_module_binding
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
rec_module_binding:
    MODULE ext_attributes REC mkrhs(UIDENT) module_binding_body post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Mb.mk $4 $5 ~attrs:(attrs@$6) ~loc ~docs, ext }
;
and_module_binding:
    AND attributes mkrhs(UIDENT) module_binding_body post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        let text = symbol_text $symbolstartpos in
        Mb.mk $3 $4 ~attrs:($2@$5) ~loc ~text ~docs }
;

/* Module types */

module_type:
  | mkmty(module_type2)
      { $1 }
  | SIG attributes signature END
      { let loc = make_loc $symbolstartpos $endpos in
        mkmty ~loc ~attrs:$2 (Pmty_signature ($3)) }
  | only_loc(SIG) attributes signature only_loc(error)
      { unclosed "sig" $1 "end" $4 }
  | FUNCTOR attributes functor_args MINUSGREATER module_type
      %prec below_WITH
      { let loc = make_loc $symbolstartpos $endpos in
        let mty =
          List.fold_left
            (fun acc (n, t) -> mkmty ~loc (Pmty_functor(n, t, acc)))
            $5 $3
        in wrap_mty_attrs ~loc mty $2 }
  | MODULE TYPE OF attributes module_expr %prec below_LBRACKETAT
      { let loc = make_loc $symbolstartpos $endpos in
        mkmty ~loc ~attrs:$4 (Pmty_typeof $5) }
  | LPAREN module_type RPAREN
      { $2 }
  | only_loc(LPAREN) module_type only_loc(error)
      { unclosed "(" $1 ")" $3 }
  | module_type attribute
      { Mty.attr $1 $2 }
;
%inline module_type2:
  | mkrhs(mty_longident)
      { Pmty_ident $1 }
  | module_type MINUSGREATER module_type
      %prec below_WITH
      { Pmty_functor(mknoloc "_", Some $1, $3) }
  | module_type WITH with_constraints
      { Pmty_with($1, List.rev $3) }
/*  | LPAREN MODULE mkrhs(mod_longident) RPAREN
      { Pmty_alias $3 } */
  | extension
      { Pmty_extension $1 }
;

signature: extra_sig(signature_nodoc) { $1 }
signature_nodoc:
    /* empty */                    { [] }
  | SEMISEMI signature_nodoc       { text_sig $startpos($1) @ $2 }
  | signature_item signature_nodoc { text_sig $startpos($1) @ $1 :: $2 }
;
signature_item:
  | signature_item_with_ext
      { let item, ext = $1 in
        let loc = make_loc $startpos $endpos in
        wrap_sig_ext ~loc (mksig ~loc item) ext }
  | item_extension post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mksig ~loc (Psig_extension ($1, (add_docs_attrs docs $2))) }
  | mksig(floating_attribute
      { Psig_attribute $1 })
      { $1 }
;
signature_item_with_ext:
    value_description
      { let (body, ext) = $1 in (Psig_value body, ext) }
  | primitive_declaration
      { let (body, ext) = $1 in (Psig_value body, ext) }
  | type_declarations
      { let (nr, l, ext) = $1 in (Psig_type (nr, List.rev l), ext) }
  | sig_type_extension
      { let (l, ext) = $1 in (Psig_typext l, ext) }
  | sig_exception_declaration
      { let (l, ext) = $1 in (Psig_exception l, ext) }
  | module_declaration
      { let (body, ext) = $1 in (Psig_module body, ext) }
  | module_alias
      { let (body, ext) = $1 in (Psig_module body, ext) }
  | rec_module_declarations
      { let (l, ext) = $1 in (Psig_recmodule (List.rev l), ext) }
  | module_type_declaration
      { let (body, ext) = $1 in (Psig_modtype body, ext) }
  | open_statement
      { let (body, ext) = $1 in (Psig_open body, ext) }
  | sig_include_statement
      { let (body, ext) = $1 in (Psig_include body, ext) }
  | class_descriptions
      { let (l, ext) = $1 in (Psig_class (List.rev l), ext) }
  | class_type_declarations
      { let (l, ext) = $1 in (Psig_class_type (List.rev l), ext) }
;
open_statement:
  | OPEN override_flag ext_attributes mkrhs(mod_longident) post_item_attributes
      { let (ext, attrs) = $3 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Opn.mk $4 ~override:$2 ~attrs:(attrs@$5) ~loc ~docs, ext}
;
sig_include_statement:
    INCLUDE ext_attributes module_type post_item_attributes %prec below_WITH
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Incl.mk $3 ~attrs:(attrs@$4) ~loc ~docs, ext}
;
module_declaration_body:
    COLON module_type
      { $2 }
  | mkmty(
      LPAREN mkrhs(UIDENT) COLON module_type RPAREN module_declaration_body
        { Pmty_functor($2, Some $4, $6) }
    | mkrhs(LPAREN RPAREN {"*"}) module_declaration_body
        { Pmty_functor($1, None, $2) }
  ) { $1 }
;
module_declaration:
    MODULE ext_attributes mkrhs(UIDENT) module_declaration_body post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Md.mk $3 $4 ~attrs:(attrs@$5) ~loc ~docs, ext }
;
%inline module_expr_alias: mkrhs(mod_longident)
  { let loc = make_loc $symbolstartpos $endpos in
    Mty.alias ~loc $1 };
module_alias:
    MODULE ext_attributes mkrhs(UIDENT) EQUAL module_expr_alias post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Md.mk $3 $5 ~attrs:(attrs@$6) ~loc ~docs, ext }
;
rec_module_declarations:
    rec_module_declaration
      { let (body, ext) = $1 in ([body], ext) }
  | rec_module_declarations and_module_declaration
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
rec_module_declaration:
    MODULE ext_attributes REC mkrhs(UIDENT) COLON module_type post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Md.mk $4 $6 ~attrs:(attrs@$7) ~loc ~docs, ext }
;
and_module_declaration:
    AND attributes mkrhs(UIDENT) COLON module_type post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        let text = symbol_text $symbolstartpos in
        Md.mk $3 $5 ~attrs:($2@$6) ~loc ~text ~docs }
;
module_type_declaration_body:
    /* empty */               { None }
  | EQUAL module_type         { Some $2 }
;
module_type_declaration:
    MODULE TYPE ext_attributes mkrhs(ident) module_type_declaration_body
    post_item_attributes
      { let (ext, attrs) = $3 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Mtd.mk $4 ?typ:$5 ~attrs:(attrs@$6) ~loc ~docs, ext }
;
/* Class expressions */

class_declarations:
    class_declaration
      { let (body, ext) = $1 in ([body], ext) }
  | class_declarations and_class_declaration
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
class_declaration:
    CLASS ext_attributes virtual_flag class_type_parameters mkrhs(LIDENT)
    class_fun_binding post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Ci.mk $5 $6 ~virt:$3 ~params:$4 ~attrs:(attrs@$7) ~loc ~docs, ext }
;
and_class_declaration:
    AND attributes virtual_flag class_type_parameters mkrhs(LIDENT) class_fun_binding
    post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        let text = symbol_text $symbolstartpos in
        Ci.mk $5 $6 ~virt:$3 ~params:$4 ~attrs:($2@$7) ~loc ~text ~docs }
;
class_fun_binding:
    EQUAL class_expr
      { $2 }
  | mkclass(
      COLON class_type EQUAL class_expr
        { Pcl_constraint($4, $2) }
    | labeled_simple_pattern class_fun_binding
      { let (l,o,p) = $1 in Pcl_fun(l, o, p, $2) }
    ) { $1 }
;
class_type_parameters:
    /*empty*/                                   { [] }
  | LBRACKET type_parameter_list RBRACKET       { List.rev $2 }
;

class_fun_def: mkclass(class_fun_def_desc) { $1 };
class_fun_def_desc:
    labeled_simple_pattern MINUSGREATER class_expr
      { let (l,o,p) = $1 in Pcl_fun(l, o, p, $3) }
  | labeled_simple_pattern class_fun_def
      { let (l,o,p) = $1 in Pcl_fun(l, o, p, $2) }
;
class_expr:
    class_simple_expr
      { $1 }
  | FUN attributes class_fun_def
      { let loc = make_loc $symbolstartpos $endpos in
        wrap_class_attrs ~loc $3 $2 }
  | let_bindings IN class_expr
      { let loc = make_loc $symbolstartpos $endpos in
        class_of_let_bindings ~loc $1 $3 }
  | LET OPEN override_flag attributes mkrhs(mod_longident) IN class_expr
      { let loc = make_loc $symbolstartpos $endpos in
        mkclass ~loc ~attrs:$4 (Pcl_open($3, $5, $7)) }
  | class_expr attribute
      { Cl.attr $1 $2 }
  | mkclass(
      class_simple_expr simple_labeled_expr_list
        { Pcl_apply($1, List.rev $2) }
    | extension
        { Pcl_extension $1 }
    ) { $1 }
;
class_simple_expr:
  | LPAREN class_expr RPAREN
      { $2 }
  | only_loc(LPAREN) class_expr only_loc(error)
      { unclosed "(" $1 ")" $3 }
  | mkclass(
      LBRACKET core_type_comma_list RBRACKET mkrhs(class_longident)
        { Pcl_constr($4, List.rev $2) }
    | mkrhs(class_longident)
        { Pcl_constr($1, []) }
    | only_loc(OBJECT) attributes class_structure only_loc(error)
        { unclosed "object" $1 "end" $4 }
    | LPAREN class_expr COLON class_type RPAREN
        { Pcl_constraint($2, $4) }
    | only_loc(LPAREN) class_expr COLON class_type only_loc(error)
        { unclosed "(" $1 ")" $5 }
    ) { $1 }
  | OBJECT attributes class_structure END
    { let loc = make_loc $symbolstartpos $endpos in
      mkclass ~loc ~attrs:$2 (Pcl_structure $3) }
;
class_structure:
  |  class_self_pattern extra_cstr(class_fields)
       { Cstr.mk $1 (List.rev $2) }
;
class_self_pattern:
    LPAREN pattern RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        reloc_pat ~loc $2 }
  | mkpat(LPAREN pattern COLON core_type RPAREN
      { Ppat_constraint($2, $4) })
      { $1 }
  | /* empty */
      { let loc = make_loc $symbolstartpos $endpos in
        ghpat ~loc Ppat_any }
;
class_fields:
    /* empty */
      { [] }
  | class_fields class_field
      { $2 :: text_cstr $startpos($2) @ $1 }
;
class_field:
  | INHERIT override_flag attributes class_expr parent_binder
    post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkcf ~loc (Pcf_inherit ($2, $4, $5)) ~attrs:($3@$6) ~docs }
  | VAL value post_item_attributes
      { let v, attrs = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkcf ~loc (Pcf_val v) ~attrs:(attrs@$3) ~docs }
  | METHOD method_ post_item_attributes
      { let meth, attrs = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkcf ~loc (Pcf_method meth) ~attrs:(attrs@$3) ~docs }
  | CONSTRAINT attributes constrain_field post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkcf ~loc (Pcf_constraint $3) ~attrs:($2@$4) ~docs }
  | INITIALIZER attributes seq_expr post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkcf ~loc (Pcf_initializer $3) ~attrs:($2@$4) ~docs }
  | item_extension post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkcf ~loc (Pcf_extension $1) ~attrs:$2 ~docs }
  | mkcf(floating_attribute
      { Pcf_attribute $1 })
      { $1 }
;
parent_binder:
    AS mkrhs(LIDENT)
          { Some $2 }
  | /* empty */
          { None }
;
value:
/* TODO: factorize these rules (also with method): */
    override_flag attributes MUTABLE VIRTUAL mkrhs(label) COLON core_type
      { if $1 = Override then syntax_error ();
        ($5, Mutable, Cfk_virtual $7), $2 }
  | override_flag attributes VIRTUAL mutable_flag mkrhs(label) COLON core_type
      { if $1 = Override then syntax_error ();
        ($5, $4, Cfk_virtual $7), $2 }
  | override_flag attributes mutable_flag mkrhs(label) EQUAL seq_expr
      { ($4, $3, Cfk_concrete ($1, $6)), $2 }
  | override_flag attributes mutable_flag mkrhs(label) type_constraint EQUAL seq_expr
      { let loc = make_loc $symbolstartpos $endpos in
        let e = mkexp_constraint ~loc $7 $5 in
        ($4, $3, Cfk_concrete ($1, e)), $2
      }
;
method_:
/* TODO: factorize those rules... */
    override_flag attributes PRIVATE VIRTUAL mkrhs(label) COLON poly_type
      { if $1 = Override then syntax_error ();
        ($5, Private, Cfk_virtual $7), $2 }
  | override_flag attributes VIRTUAL private_flag mkrhs(label) COLON poly_type
      { if $1 = Override then syntax_error ();
        ($5, $4, Cfk_virtual $7), $2 }
  | override_flag attributes private_flag mkrhs(label) strict_binding
      { let e = $5 in
        ($4, $3,
        Cfk_concrete ($1, ghexp ~loc:e.pexp_loc (Pexp_poly (e, None)))), $2 }
  | override_flag attributes private_flag mkrhs(label)
    COLON poly_type EQUAL seq_expr
      { let poly_exp =
          let loc = make_loc $startpos($6) $endpos($8) in
          ghexp ~loc (Pexp_poly($8, Some $6)) in
        ($4, $3, Cfk_concrete ($1, poly_exp)), $2 }
  | override_flag attributes private_flag mkrhs(label) COLON TYPE lident_list
    DOT core_type EQUAL seq_expr
      { let loc = make_loc $symbolstartpos $endpos in
        let poly_exp_loc = make_loc $startpos($7) $endpos($11) in
        let poly_exp =
          let exp, poly =
            (* it seems odd to use the global ~loc here while poly_exp_loc
               is tighter, but this is what ocamlyacc does;
               TODO improve parser.mly *)
            wrap_type_annotation ~loc $7 $9 $11 in
          ghexp ~loc:poly_exp_loc (Pexp_poly(exp, Some poly)) in
        ($4, $3,
        Cfk_concrete ($1, poly_exp)), $2 }
;

/* Class types */

class_type:
    class_signature
      { $1 }
  | mkcty(
      QUESTION LIDENT COLON simple_core_type_or_tuple MINUSGREATER class_type
        { Pcty_arrow(Optional $2 , $4, $6) }
    | OPTLABEL simple_core_type_or_tuple MINUSGREATER class_type
        { Pcty_arrow(Optional $1, $2, $4) }
    | LIDENT COLON simple_core_type_or_tuple MINUSGREATER class_type
        { Pcty_arrow(Labelled $1, $3, $5) }
    | simple_core_type_or_tuple MINUSGREATER class_type
        { Pcty_arrow(Nolabel, $1, $3) }
    ) { $1 }
 ;
class_signature:
    mkcty(
      LBRACKET core_type_comma_list RBRACKET mkrhs(clty_longident)
        { Pcty_constr ($4, List.rev $2) }
    | mkrhs(clty_longident)
        { Pcty_constr ($1, []) }
    | extension
        { Pcty_extension $1 }
    ) { $1 }
  | OBJECT attributes class_sig_body END
      { let loc = make_loc $symbolstartpos $endpos in
        mkcty ~loc ~attrs:$2 (Pcty_signature $3) }
  | only_loc(OBJECT) attributes class_sig_body only_loc(error)
      { unclosed "object" $1 "end" $4 }
  | class_signature attribute
      { Cty.attr $1 $2 }
  | LET OPEN override_flag attributes mkrhs(mod_longident) IN class_signature
      { let loc = make_loc $symbolstartpos $endpos in
        mkcty ~loc ~attrs:$4 (Pcty_open($3, $5, $7)) }
;
class_sig_body:
    class_self_type extra_csig(class_sig_fields)
      { Csig.mk $1 (List.rev $2) }
;
class_self_type:
    LPAREN core_type RPAREN
      { $2 }
  | mktyp(/* empty */ { Ptyp_any })
      { $1 }
;
class_sig_fields:
    /* empty */                                 { [] }
| class_sig_fields class_sig_field     { $2 :: text_csig $startpos($2) @ $1 }
;
class_sig_field:
    INHERIT attributes class_signature post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkctf ~loc (Pctf_inherit $3) ~attrs:($2@$4) ~docs }
  | VAL attributes value_type post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkctf ~loc (Pctf_val $3) ~attrs:($2@$4) ~docs }
  | METHOD attributes private_virtual_flags mkrhs(label) COLON poly_type
    post_item_attributes
      { let (p, v) = $3 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkctf ~loc (Pctf_method ($4, p, v, $6)) ~attrs:($2@$7) ~docs }
  | CONSTRAINT attributes constrain_field post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkctf ~loc (Pctf_constraint $3) ~attrs:($2@$4) ~docs }
  | item_extension post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        mkctf ~loc (Pctf_extension $1) ~attrs:$2 ~docs }
  | mkctf(floating_attribute
      { Pctf_attribute $1 })
      { $1 }
;
value_type:
    VIRTUAL mutable_flag mkrhs(label) COLON core_type
      { $3, $2, Virtual, $5 }
  | MUTABLE virtual_flag mkrhs(label) COLON core_type
      { $3, Mutable, $2, $5 }
  | mkrhs(label) COLON core_type
      { $1, Immutable, Concrete, $3 }
;
constrain:
    core_type EQUAL core_type
    { let loc = make_loc $symbolstartpos $endpos in
      $1, $3, loc }
;
constrain_field:
  core_type EQUAL core_type
    { $1, $3 }
;
class_descriptions:
    class_description
      { let (body, ext) = $1 in ([body],ext) }
  | class_descriptions and_class_description
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
class_description:
    CLASS ext_attributes virtual_flag class_type_parameters mkrhs(LIDENT) COLON
    class_type post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Ci.mk $5 $7 ~virt:$3 ~params:$4 ~attrs:(attrs @ $8) ~loc ~docs, ext }
;
and_class_description:
    AND attributes virtual_flag class_type_parameters mkrhs(LIDENT) COLON class_type
    post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        let text = symbol_text $symbolstartpos in
        Ci.mk $5 $7 ~virt:$3 ~params:$4 ~attrs:($2@$8) ~loc ~text ~docs }
;
class_type_declarations:
    class_type_declaration
      { let (body, ext) = $1 in ([body],ext) }
  | class_type_declarations and_class_type_declaration
      { let (l, ext) = $1 in ($2 :: l, ext) }
;
class_type_declaration:
    CLASS TYPE ext_attributes virtual_flag class_type_parameters mkrhs(LIDENT) EQUAL
    class_signature post_item_attributes
      { let (ext, attrs) = $3 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Ci.mk $6 $8 ~virt:$4 ~params:$5 ~attrs:(attrs@$9) ~loc ~docs, ext }
;
and_class_type_declaration:
    AND attributes virtual_flag class_type_parameters mkrhs(LIDENT) EQUAL
    class_signature post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        let text = symbol_text $symbolstartpos in
        Ci.mk $5 $7 ~virt:$3 ~params:$4 ~attrs:($2@$8) ~loc ~text ~docs }
;

/* Core expressions */

seq_expr:
  | expr        %prec below_SEMI  { $1 }
  | expr SEMI                     { $1 }
  | mkexp(expr SEMI seq_expr
    { Pexp_sequence($1, $3) })
    { $1 }
  | expr SEMI PERCENT attr_id seq_expr
    { let loc = make_loc $symbolstartpos $endpos in
      let seq = mkexp ~loc (Pexp_sequence ($1, $5)) in
      let payload = PStr [mkstrexp seq []] in
      mkexp ~loc (Pexp_extension ($4, payload)) }
;
labeled_simple_pattern:
    QUESTION LPAREN label_let_pattern opt_default RPAREN
      { (Optional (fst $3), $4, snd $3) }
  | QUESTION label_var
      { (Optional (fst $2), None, snd $2) }
  | OPTLABEL LPAREN let_pattern opt_default RPAREN
      { (Optional $1, $4, $3) }
  | OPTLABEL pattern_var
      { (Optional $1, None, $2) }
  | TILDE LPAREN label_let_pattern RPAREN
      { (Labelled (fst $3), None, snd $3) }
  | TILDE label_var
      { (Labelled (fst $2), None, snd $2) }
  | LABEL simple_pattern
      { (Labelled $1, None, $2) }
  | simple_pattern
      { (Nolabel, None, $1) }
;
pattern_var2:
    mkrhs(LIDENT)     { Ppat_var $1 }
  | UNDERSCORE        { Ppat_any }
;
pattern_var:
    mkpat(pattern_var2)
      { $1 }
;
opt_default:
    /* empty */                         { None }
  | EQUAL seq_expr                      { Some $2 }
;
label_let_pattern:
    label_var
      { $1 }
  | label_var COLON core_type
      { let (lab, pat) = $1 in
        let loc = make_loc $symbolstartpos $endpos in
        (lab, mkpat ~loc (Ppat_constraint(pat, $3))) }
;
label_var:
    mkrhs(LIDENT)
      { let loc = make_loc $symbolstartpos $endpos in
        ($1.Location.txt, mkpat ~loc (Ppat_var $1)) }
;
let_pattern:
    pattern
      { $1 }
  | mkpat(pattern COLON core_type
      { Ppat_constraint($1, $3) })
      { $1 }
;

expr:
    simple_expr %prec below_HASH
      { $1 }
  | expr_attrs
    { let loc = make_loc $symbolstartpos $endpos in
      let desc, attrs = $1 in
      mkexp_attrs ~loc desc attrs }
  | mkexp(expr2)
    { $1 }
  | let_bindings IN seq_expr
    { let loc = make_loc $symbolstartpos $endpos in
      expr_of_let_bindings ~loc $1 $3 }
  | expr COLONCOLON expr
      { let loc = make_loc $symbolstartpos $endpos in
        let consloc = make_loc $startpos($2) $endpos($2) in
        mkexp_cons ~loc consloc (ghexp ~loc (Pexp_tuple[$1;$3])) }
  | mkrhs(label) LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        mkexp ~loc (Pexp_setinstvar($1, $3)) }
  | simple_expr DOT mkrhs(label_longident) LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        mkexp ~loc (Pexp_setfield($1, $3, $5)) }
  | simple_expr DOT LPAREN seq_expr RPAREN LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        array_set ~loc $1 $4 $7 }
  | simple_expr DOT LBRACKET seq_expr RBRACKET LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        string_set ~loc $1 $4 $7 }
  | simple_expr DOT LBRACE expr RBRACE LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        bigarray_set ~loc $1 $4 $7 }
  | simple_expr DOTOP LBRACKET expr RBRACKET LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_set ~loc (Lident ("." ^ $2 ^ "[]<-")) $1 $4 $7 }
  | simple_expr DOTOP LPAREN expr RPAREN LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_set ~loc (Lident ("." ^ $2 ^ "()<-")) $1 $4 $7 }
  | simple_expr DOTOP LBRACE expr RBRACE LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_set ~loc (Lident ("." ^ $2 ^ "{}<-")) $1 $4 $7 }
  | simple_expr DOT mod_longident DOTOP LBRACKET expr RBRACKET LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_set ~loc (Ldot($3,"." ^ $4 ^ "[]<-")) $1 $6 $9 }
  | simple_expr DOT mod_longident DOTOP LPAREN expr RPAREN LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_set ~loc (Ldot($3, "." ^ $4 ^ "()<-")) $1 $6 $9 }
  | simple_expr DOT mod_longident DOTOP LBRACE expr RBRACE LESSMINUS expr
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_set ~loc (Ldot($3, "." ^ $4 ^ "{}<-")) $1 $6 $9 }
  | expr attribute
      { Exp.attr $1 $2 }
  | only_loc(UNDERSCORE)
     { not_expecting $1 "wildcard \"_\"" }
;
%inline expr_attrs:
  | LET MODULE ext_attributes mkrhs(UIDENT) module_binding_body IN seq_expr
      { Pexp_letmodule($4, $5, $7), $3 }
  | LET EXCEPTION ext_attributes let_exception_declaration IN seq_expr
      { Pexp_letexception($4, $6), $3 }
  | LET OPEN override_flag ext_attributes mkrhs(mod_longident) IN seq_expr
      { Pexp_open($3, $5, $7), $4 }
  | FUNCTION ext_attributes opt_bar match_cases
      { Pexp_function(List.rev $4), $2 }
  | FUN ext_attributes labeled_simple_pattern fun_def
      { let (l,o,p) = $3 in
        Pexp_fun(l, o, p, $4), $2 }
  | FUN ext_attributes LPAREN TYPE lident_list RPAREN fun_def
      { let loc = make_loc $symbolstartpos $endpos in
        (mk_newtypes ~loc $5 $7).pexp_desc, $2 }
  | MATCH ext_attributes seq_expr WITH opt_bar match_cases
      { Pexp_match($3, List.rev $6), $2 }
  | TRY ext_attributes seq_expr WITH opt_bar match_cases
      { Pexp_try($3, List.rev $6), $2 }
  | TRY ext_attributes seq_expr WITH error
      { syntax_error() }
  | IF ext_attributes seq_expr THEN expr ELSE expr
      { Pexp_ifthenelse($3, $5, Some $7), $2 }
  | IF ext_attributes seq_expr THEN expr
      { Pexp_ifthenelse($3, $5, None), $2 }
  | WHILE ext_attributes seq_expr DO seq_expr DONE
      { Pexp_while($3, $5), $2 }
  | FOR ext_attributes pattern EQUAL seq_expr direction_flag seq_expr DO
    seq_expr DONE
      { Pexp_for($3, $5, $7, $6, $9), $2 }
  | ASSERT ext_attributes simple_expr %prec below_HASH
      { Pexp_assert $3, $2 }
  | LAZY ext_attributes simple_expr %prec below_HASH
      { Pexp_lazy $3, $2 }
  | OBJECT ext_attributes class_structure END
      { Pexp_object $3, $2 }
  | only_loc(OBJECT) ext_attributes class_structure only_loc(error)
      { unclosed "object" $1 "end" $4 }
;
%inline expr2:
  | expr_op { $1 }
  | simple_expr simple_labeled_expr_list
    { Pexp_apply($1, List.rev $2) }
  | expr_comma_list %prec below_COMMA
    { Pexp_tuple(List.rev $1) }
  | mkrhs(constr_longident) simple_expr %prec below_HASH
    { Pexp_construct($1, Some $2) }
  | name_tag simple_expr %prec below_HASH
    { Pexp_variant($1, Some $2) }
;
%inline expr_op:
  | expr op(INFIXOP0) expr
      { mkinfix $1 $2 $3 }
  | expr op(INFIXOP1) expr
      { mkinfix $1 $2 $3 }
  | expr op(INFIXOP2) expr
      { mkinfix $1 $2 $3 }
  | expr op(INFIXOP3) expr
      { mkinfix $1 $2 $3 }
  | expr op(INFIXOP4) expr
      { mkinfix $1 $2 $3 }
  | expr op(PLUS {"+"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(PLUSDOT {"+."}) expr
      { mkinfix $1 $2 $3 }
  | expr op(PLUSEQ {"+="}) expr
      { mkinfix $1 $2 $3 }
  | expr op(MINUS {"-"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(MINUSDOT {"-."}) expr
      { mkinfix $1 $2 $3 }
  | expr op(STAR {"*"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(PERCENT {"%"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(EQUAL {"="}) expr
      { mkinfix $1 $2 $3 }
  | expr op(LESS {"<"}) expr
    { mkinfix $1 $2 $3 }
  | expr op(GREATER {">"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(OR {"or"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(BARBAR {"||"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(AMPERSAND {"&"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(AMPERAMPER {"&&"}) expr
      { mkinfix $1 $2 $3 }
  | expr op(COLONEQUAL {":="}) expr
      { mkinfix $1 $2 $3 }
  | with_loc(subtractive) expr %prec prec_unary_minus
      { let op, oploc = $1 in
        mkuminus ~oploc op $2 }
  | with_loc(additive) expr %prec prec_unary_plus
      { let op, oploc = $1 in
        mkuplus ~oploc op $2 }
;

simple_expr:
  | mkexp(simple_expr2)
      { $1 }
  | simple_expr_attrs
    { let loc = make_loc $symbolstartpos $endpos in
      let desc, attrs = $1 in
      mkexp_attrs ~loc desc attrs }
  | LPAREN seq_expr RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        reloc_exp ~loc $2 }
  | only_loc(LPAREN) seq_expr only_loc(error)
      { unclosed "(" $1 ")" $3 }
  | LPAREN seq_expr type_constraint RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        mkexp_constraint ~loc $2 $3 }
  | simple_expr DOT LPAREN seq_expr RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        array_get ~loc $1 $4 }
  | simple_expr DOT only_loc(LPAREN) seq_expr only_loc(error)
      { unclosed "(" $3 ")" $5 }
  | simple_expr DOT LBRACKET seq_expr RBRACKET
      { let loc = make_loc $symbolstartpos $endpos in
        string_get ~loc $1 $4 }
  | simple_expr DOT only_loc(LBRACKET) seq_expr only_loc(error)
      { unclosed "[" $3 "]" $5 }
  | simple_expr DOTOP LBRACKET expr RBRACKET
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_get ~loc (Lident ("." ^ $2 ^ "[]")) $1 $4 }
  | simple_expr DOTOP only_loc(LBRACKET) expr only_loc(error)
      { unclosed "[" $3 "]" $5 }
  | simple_expr DOTOP LPAREN expr RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_get ~loc (Lident ("." ^ $2 ^ "()")) $1 $4  }
  | simple_expr DOTOP only_loc(LPAREN) expr only_loc(error)
      { unclosed "(" $3 ")" $5 }
  | simple_expr DOTOP LBRACE expr RBRACE
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_get ~loc (Lident ("." ^ $2 ^ "{}")) $1 $4 }
  | simple_expr DOTOP only_loc(LBRACE) expr only_loc(error)
      { unclosed "{" $3 "}" $5 }
  | simple_expr DOT mod_longident DOTOP LBRACKET expr RBRACKET
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_get ~loc (Ldot($3, "." ^ $4 ^ "[]")) $1 $6  }
  | simple_expr DOT
    mod_longident DOTOP only_loc(LBRACKET) expr only_loc(error)
      { unclosed "[" $5 "]" $7 }
  | simple_expr DOT mod_longident DOTOP LPAREN expr RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_get ~loc (Ldot($3, "." ^ $4 ^ "()")) $1 $6 }
  | simple_expr DOT
    mod_longident DOTOP only_loc(LPAREN) expr only_loc(error)
      { unclosed "(" $5 ")" $7 }
  | simple_expr DOT mod_longident DOTOP LBRACE expr RBRACE
      { let loc = make_loc $symbolstartpos $endpos in
        dotop_get ~loc (Ldot($3, "." ^ $4 ^ "{}")) $1 $6  }
  | simple_expr DOT
    mod_longident DOTOP only_loc(LBRACE) expr only_loc(error)
      { unclosed "{" $5 "}" $7 }
  | simple_expr DOT LBRACE expr RBRACE
      { let loc = make_loc $symbolstartpos $endpos in
        bigarray_get ~loc $1 $4 }
  | simple_expr DOT only_loc(LBRACE) expr_comma_list only_loc(error)
      { unclosed "{" $3 "}" $5 }
;
%inline simple_expr_attrs:
  | BEGIN ext_attributes seq_expr END
      { let (ext, attrs) = $2 in
        $3.pexp_desc, (ext, attrs @ $3.pexp_attributes) }
  | BEGIN ext_attributes END
      { let loc = make_loc $symbolstartpos $endpos in
        Pexp_construct (mkloc (Lident "()") loc, None), $2 }
  | only_loc(BEGIN) ext_attributes seq_expr only_loc(error)
      { unclosed "begin" $1 "end" $4 }
  | NEW ext_attributes mkrhs(class_longident)
      { Pexp_new($3), $2 }
  | LPAREN MODULE ext_attributes module_expr RPAREN
      { Pexp_pack $4, $3 }
  | LPAREN MODULE ext_attributes module_expr COLON package_type RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        Pexp_constraint (ghexp ~loc (Pexp_pack $4), $6), $3 }
  | only_loc(LPAREN) MODULE ext_attributes module_expr COLON only_loc(error)
      { unclosed "(" $1 ")" $6 }
;
%inline simple_expr2:
  | mkrhs(val_longident)
      { Pexp_ident ($1) }
  | constant
      { Pexp_constant $1 }
  | mkrhs(constr_longident) %prec prec_constant_constructor
      { Pexp_construct($1, None) }
  | name_tag %prec prec_constant_constructor
      { Pexp_variant($1, None) }
  | op(PREFIXOP) simple_expr
      { Pexp_apply($1, [Nolabel,$2]) }
  | op(BANG {"!"}) simple_expr
      { Pexp_apply($1, [Nolabel,$2]) }
  | LBRACELESS field_expr_list GREATERRBRACE
      { Pexp_override $2 }
  | only_loc(LBRACELESS) field_expr_list only_loc(error)
      { unclosed "{<" $1 ">}" $3 }
  | LBRACELESS GREATERRBRACE
      { Pexp_override [] }
  | simple_expr DOT mkrhs(label_longident)
      { Pexp_field($1, $3) }
  | mkrhs(mod_longident) DOT LPAREN seq_expr RPAREN
      { Pexp_open(Fresh, $1, $4) }
  | mkrhs(mod_longident) DOT LBRACELESS field_expr_list GREATERRBRACE
      { let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of Pexp_override *)
        Pexp_open(Fresh, $1, mkexp ~loc (Pexp_override $4)) }
  | mod_longident DOT only_loc(LBRACELESS) field_expr_list only_loc(error)
      { unclosed "{<" $3 ">}" $5 }
  | simple_expr HASH mkrhs(label)
      { Pexp_send($1, $3) }
  | simple_expr op(HASHOP) simple_expr
      { mkinfix $1 $2 $3 }
  | extension
      { Pexp_extension $1 }
  | mkrhs(mod_longident) DOT mkrhs(LPAREN RPAREN {Lident "()"})
      { let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of Pexp_construct *)
        Pexp_open(Fresh, $1, mkexp ~loc (Pexp_construct($3, None))) }
  | mod_longident DOT only_loc(LPAREN) seq_expr only_loc(error)
      { unclosed "(" $3 ")" $5 }
  | LBRACE record_expr RBRACE
      { let (exten, fields) = $2 in
        Pexp_record(fields, exten) }
  | only_loc(LBRACE) record_expr only_loc(error)
      { unclosed "{" $1 "}" $3 }
  | mkrhs(mod_longident) DOT LBRACE record_expr RBRACE
      { let (exten, fields) = $4 in
        let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of Pexp_construct *)
        Pexp_open(Fresh, $1, mkexp ~loc (Pexp_record(fields, exten))) }
  | mod_longident DOT only_loc(LBRACE) record_expr only_loc(error)
      { unclosed "{" $3 "}" $5 }
  | LBRACKETBAR expr_semi_list opt_semi BARRBRACKET
      { Pexp_array(List.rev $2) }
  | only_loc(LBRACKETBAR) expr_semi_list opt_semi only_loc(error)
      { unclosed "[|" $1 "|]" $4 }
  | LBRACKETBAR BARRBRACKET
      { Pexp_array [] }
  | mkrhs(mod_longident) DOT LBRACKETBAR expr_semi_list opt_semi BARRBRACKET
      { let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of Pexp_array *)
        Pexp_open(Fresh, $1, mkexp ~loc (Pexp_array(List.rev $4))) }
  | mkrhs(mod_longident) DOT LBRACKETBAR BARRBRACKET
      { let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of Pexp_array *)
        Pexp_open(Fresh, $1, mkexp ~loc (Pexp_array [])) }
  | mod_longident DOT
    only_loc(LBRACKETBAR) expr_semi_list opt_semi only_loc(error)
      { unclosed "[|" $3 "|]" $6 }
  | LBRACKET expr_semi_list opt_semi only_loc(RBRACKET)
      { fst (mktailexp $4 (List.rev $2)) }
  | only_loc(LBRACKET) expr_semi_list opt_semi only_loc(error)
      { unclosed "[" $1 "]" $4 }
  | mkrhs(mod_longident) DOT LBRACKET expr_semi_list opt_semi only_loc(RBRACKET)
      { let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of list_exp *)
        let list_exp = mkexp ~loc (fst (mktailexp $6 (List.rev $4))) in
        Pexp_open(Fresh, $1, list_exp) }
  | mkrhs(mod_longident) DOT mkrhs(LBRACKET RBRACKET {Lident "[]"})
      { let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of Pexp_construct *)
        Pexp_open(Fresh, $1, mkexp ~loc (Pexp_construct($3, None))) }
  | mod_longident DOT
    only_loc(LBRACKET) expr_semi_list opt_semi only_loc(error)
      { unclosed "[" $3 "]" $6 }
  | mkrhs(mod_longident) DOT LPAREN MODULE ext_attributes module_expr COLON
    package_type RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        (* TODO: review the location of Pexp_constraint *)
        let modexp =
          mkexp_attrs ~loc (Pexp_constraint (ghexp ~loc (Pexp_pack $6), $8)) $5 in
        Pexp_open(Fresh, $1, modexp) }
  | mod_longident DOT
    only_loc(LPAREN) MODULE ext_attributes module_expr COLON only_loc(error)
      { unclosed "(" $3 ")" $8 }
;

simple_labeled_expr_list:
    labeled_simple_expr
      { [$1] }
  | simple_labeled_expr_list labeled_simple_expr
      { $2 :: $1 }
;
labeled_simple_expr:
    simple_expr %prec below_HASH
      { (Nolabel, $1) }
  | label_expr
      { $1 }
;
label_expr:
    LABEL simple_expr %prec below_HASH
      { (Labelled $1, $2) }
  | TILDE label_ident
      { (Labelled (fst $2), snd $2) }
  | QUESTION label_ident
      { (Optional (fst $2), snd $2) }
  | OPTLABEL simple_expr %prec below_HASH
      { (Optional $1, $2) }
;
label_ident:
    LIDENT
      { let loc = make_loc $symbolstartpos $endpos in
        ($1, mkexp ~loc (Pexp_ident(mkrhs (Lident $1) loc))) }
;
lident_list:
    mkrhs(LIDENT)                     { [$1] }
  | mkrhs(LIDENT) lident_list         { $1 :: $2 }
;
%inline let_ident:
    val_ident { mkpatvar $1 (make_loc $startpos $endpos) };
let_binding_body:
    let_ident strict_binding
      { ($1, $2) }
  | let_ident type_constraint EQUAL seq_expr
      { let v = $1 in (* PR#7344 *)
        let t =
          match $2 with
            Some t, None -> t
          | _, Some t -> t
          | _ -> assert false
        in
        let typ = ghtyp ~loc:t.ptyp_loc (Ptyp_poly([],t)) in
        let loc = make_loc $symbolstartpos $endpos in
        let patloc = make_loc $startpos($1) $endpos($2) in
        (ghpat ~loc:patloc (Ppat_constraint(v, typ)),
         mkexp_constraint ~loc $4 $2) }
  | let_ident COLON typevar_list DOT core_type EQUAL seq_expr
      { let typloc = make_loc $startpos($3) $endpos($5) in
        let patloc = make_loc $startpos($1) $endpos($5) in
        (ghpat ~loc:patloc
           (Ppat_constraint($1, ghtyp ~loc:typloc (Ptyp_poly(List.rev $3,$5)))),
         $7) }
  | let_ident COLON TYPE lident_list DOT core_type EQUAL seq_expr
      { let exp, poly =
          let loc = make_loc $symbolstartpos $endpos in
          wrap_type_annotation ~loc $4 $6 $8 in
        let loc = make_loc $startpos($1) $endpos($6) in
        (ghpat ~loc (Ppat_constraint($1, poly)), exp) }
  | pattern_no_exn EQUAL seq_expr
      { ($1, $3) }
  | simple_pattern_not_ident COLON core_type EQUAL seq_expr
      { let loc = make_loc $startpos($1) $endpos($3) in
        (ghpat ~loc (Ppat_constraint($1, $3)), $5) }
;
let_bindings:
    let_binding                                 { $1 }
  | let_bindings and_let_binding                { addlb $1 $2 }
;
let_binding:
    LET ext_attributes rec_flag let_binding_body post_item_attributes
      { let (ext, attr) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        mklbs ~loc ext $3 (mklb ~loc true $4 (attr@$5)) }
;
and_let_binding:
    AND attributes let_binding_body post_item_attributes
      { let loc = make_loc $symbolstartpos $endpos in
        mklb ~loc false $3 ($2@$4) }
;
fun_binding:
    strict_binding
      { $1 }
  | type_constraint EQUAL seq_expr
      { let loc = make_loc $symbolstartpos $endpos in
        mkexp_constraint ~loc $3 $1 }
;
strict_binding:
    EQUAL seq_expr
      { $2 }
  | labeled_simple_pattern fun_binding
      { let loc = make_loc $symbolstartpos $endpos in
        let (l, o, p) = $1 in ghexp ~loc (Pexp_fun(l, o, p, $2)) }
  | LPAREN TYPE lident_list RPAREN fun_binding
      { let loc = make_loc $symbolstartpos $endpos in
        mk_newtypes ~loc $3 $5 }
;
match_cases:
    match_case { [$1] }
  | match_cases BAR match_case { $3 :: $1 }
;
match_case:
    pattern MINUSGREATER seq_expr
      { Exp.case $1 $3 }
  | pattern WHEN seq_expr MINUSGREATER seq_expr
      { Exp.case $1 ~guard:$3 $5 }
  | pattern MINUSGREATER only_loc(DOT)
      { Exp.case $1 (Exp.unreachable ~loc:$3 ())}
;
fun_def:
    MINUSGREATER seq_expr
      { $2 }
  | mkexp(COLON simple_core_type MINUSGREATER seq_expr
      { Pexp_constraint ($4, $2) })
      { $1 }
/* Cf #5939: we used to accept (fun p when e0 -> e) */
  | labeled_simple_pattern fun_def
      {
       let loc = make_loc $symbolstartpos $endpos in
       let (l,o,p) = $1 in
       ghexp ~loc (Pexp_fun(l, o, p, $2))
      }
  | LPAREN TYPE lident_list RPAREN fun_def
      { let loc = make_loc $symbolstartpos $endpos in
        mk_newtypes ~loc $3 $5 }
;
expr_comma_list:
    expr_comma_list COMMA expr                  { $3 :: $1 }
  | expr COMMA expr                             { [$3; $1] }
;
record_expr:
    simple_expr WITH lbl_expr_list              { (Some $1, $3) }
  | lbl_expr_list                               { (None, $1) }
;
lbl_expr_list:
     lbl_expr { [$1] }
  |  lbl_expr SEMI lbl_expr_list { $1 :: $3 }
  |  lbl_expr SEMI { [$1] }
;
lbl_expr:
    mkrhs(label_longident) opt_type_constraint EQUAL expr
      { let loc = make_loc $symbolstartpos $endpos in
        ($1, mkexp_opt_constraint ~loc $4 $2) }
  | mkrhs(label_longident) opt_type_constraint
      { let loc = make_loc $symbolstartpos $endpos in
        ($1, mkexp_opt_constraint ~loc (exp_of_longident ~loc $1) $2) }
;
field_expr_list:
    field_expr opt_semi { [$1] }
  | field_expr SEMI field_expr_list { $1 :: $3 }
;
field_expr:
    mkrhs(label) EQUAL expr
      { ($1, $3) }
  | with_loc(label)
      { let label, loc = $1 in
        let label = mkrhs label loc in
        (label, exp_of_label ~loc label) }
;
expr_semi_list:
    expr                                        { [$1] }
  | expr_semi_list SEMI expr                    { $3 :: $1 }
;
type_constraint:
    COLON core_type                             { (Some $2, None) }
  | COLON core_type COLONGREATER core_type      { (Some $2, Some $4) }
  | COLONGREATER core_type                      { (None, Some $2) }
  | COLON error                                 { syntax_error() }
  | COLONGREATER error                          { syntax_error() }
;
opt_type_constraint:
    type_constraint { Some $1 }
  | /* empty */ { None }
;

/* Patterns */

%inline pattern2:
  | pattern AS mkrhs(val_ident)
      { Ppat_alias($1, $3) }
  | pattern AS only_loc(error)
      { expecting $3 "identifier" }
  | pattern_comma_list  %prec below_COMMA
      { Ppat_tuple(List.rev $1) }
  | pattern COLONCOLON only_loc(error)
      { expecting $3 "pattern" }
  | pattern BAR pattern
      { Ppat_or($1, $3) }
  | pattern BAR only_loc(error)
      { expecting $3 "pattern" }
;
pattern:
    mkpat(pattern2)
      {  $1 }
  | pattern only_loc(COLONCOLON) pattern
      { let loc = make_loc $symbolstartpos $endpos in
        mkpat_cons ~loc $2 (ghpat ~loc (Ppat_tuple[$1;$3])) }
  | EXCEPTION ext_attributes pattern %prec prec_constr_appl
      { let loc = make_loc $symbolstartpos $endpos in
        mkpat_attrs ~loc (Ppat_exception $3) $2}
  | pattern attribute
      { Pat.attr $1 $2 }
  | pattern_gen { $1 }
;
%inline pattern_no_exn2:
  | pattern_no_exn AS mkrhs(val_ident)
      { Ppat_alias($1, $3) }
  | pattern_no_exn AS only_loc(error)
      { expecting $3 "identifier" }
  | pattern_no_exn_comma_list  %prec below_COMMA
      { Ppat_tuple(List.rev $1) }
  | pattern_no_exn COLONCOLON only_loc(error)
      { expecting $3 "pattern" }
  | pattern_no_exn BAR pattern
      { Ppat_or($1, $3) }
  | pattern_no_exn BAR only_loc(error)
      { expecting $3 "pattern" }
;
pattern_no_exn:
    mkpat(pattern_no_exn2)
      { $1 }
  | pattern_no_exn only_loc(COLONCOLON) pattern
      { let loc = make_loc $symbolstartpos $endpos in
        mkpat_cons ~loc $2 (ghpat ~loc (Ppat_tuple[$1;$3])) }
  | pattern_no_exn attribute
      { Pat.attr $1 $2 }
  | pattern_gen { $1 }
;
pattern_gen:
    simple_pattern
      { $1 }
  | mkpat(
      mkrhs(constr_longident) pattern %prec prec_constr_appl
        { Ppat_construct($1, Some $2) }
    | name_tag pattern %prec prec_constr_appl
        { Ppat_variant($1, Some $2) }
    ) { $1 }
  | LAZY ext_attributes simple_pattern
      { let loc = make_loc $symbolstartpos $endpos in
        mkpat_attrs ~loc (Ppat_lazy $3) $2}
;
simple_pattern:
    mkpat(mkrhs(val_ident) %prec below_EQUAL
      { Ppat_var ($1) })
      { $1 }
  | simple_pattern_not_ident { $1 }
;
%inline simple_pattern_not_ident2:
  | UNDERSCORE
      { Ppat_any }
  | signed_constant
      { Ppat_constant $1 }
  | signed_constant DOTDOT signed_constant
      { Ppat_interval ($1, $3) }
  | mkrhs(constr_longident)
      { Ppat_construct($1, None) }
  | name_tag
      { Ppat_variant($1, None) }
  | HASH mkrhs(type_longident)
      { Ppat_type ($2) }
  | mkrhs(mod_longident) DOT simple_delimited_pattern
      { Ppat_open($1, $3) }
  | mkrhs(mod_longident) DOT mkrhs(LBRACKET RBRACKET {Lident "[]"})
    { let loc = make_loc $symbolstartpos $endpos in
      Ppat_open($1, mkpat ~loc (Ppat_construct($3, None))) }
  | mkrhs(mod_longident) DOT mkrhs(LPAREN RPAREN {Lident "()"})
    { let loc = make_loc $symbolstartpos $endpos in
      Ppat_open($1, mkpat ~loc (Ppat_construct($3, None))) }
  | mkrhs(mod_longident) DOT LPAREN pattern RPAREN
      { Ppat_open ($1, $4) }
  | mod_longident DOT only_loc(LPAREN) pattern only_loc(error)
      { unclosed "(" $3 ")" $5  }
  | mod_longident DOT LPAREN only_loc(error)
      { expecting $4 "pattern" }
  | only_loc(LPAREN) pattern only_loc(error)
      { unclosed "(" $1 ")" $3 }
  | LPAREN pattern COLON core_type RPAREN
      { Ppat_constraint($2, $4) }
  | only_loc(LPAREN) pattern COLON core_type only_loc(error)
      { unclosed "(" $1 ")" $5 }
  | LPAREN pattern COLON only_loc(error)
      { expecting $4 "type" }
  | only_loc(LPAREN) MODULE ext_attributes UIDENT COLON package_type
    only_loc(error)
      { unclosed "(" $1 ")" $7 }
  | extension
      { Ppat_extension $1 }
;
simple_pattern_not_ident:
    mkpat(simple_pattern_not_ident2)
      { $1 }
  | LPAREN pattern RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        reloc_pat ~loc $2 }
  | simple_delimited_pattern
      { $1 }
  | LPAREN MODULE ext_attributes mkrhs(UIDENT) RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        mkpat_attrs ~loc (Ppat_unpack $4) $3 }
  | LPAREN MODULE ext_attributes mkrhs(UIDENT) COLON package_type RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        mkpat_attrs ~loc
          (Ppat_constraint(mkpat ~loc (Ppat_unpack $4), $6))
          $3 }
;

simple_delimited_pattern:
  mkpat(
      LBRACE lbl_pattern_list RBRACE
      { let (fields, closed) = $2 in
        Ppat_record(fields, closed) }
    | only_loc(LBRACE) lbl_pattern_list only_loc(error)
      { unclosed "{" $1 "}" $3 }
    | LBRACKET pattern_semi_list opt_semi only_loc(RBRACKET)
      { fst (mktailpat $4 (List.rev $2)) }
    | only_loc(LBRACKET) pattern_semi_list opt_semi only_loc(error)
      { unclosed "[" $1 "]" $4 }
    | LBRACKETBAR pattern_semi_list opt_semi BARRBRACKET
      { Ppat_array(List.rev $2) }
    | LBRACKETBAR BARRBRACKET
      { Ppat_array [] }
    | only_loc(LBRACKETBAR) pattern_semi_list opt_semi only_loc(error)
      { unclosed "[|" $1 "|]" $4 }
  ) { $1 }

pattern_comma_list:
    pattern_comma_list COMMA pattern            { $3 :: $1 }
  | pattern COMMA pattern                       { [$3; $1] }
  | pattern COMMA only_loc(error)               { expecting $3 "pattern" }
;
pattern_no_exn_comma_list:
    pattern_no_exn_comma_list COMMA pattern     { $3 :: $1 }
  | pattern_no_exn COMMA pattern                { [$3; $1] }
  | pattern_no_exn COMMA only_loc(error)        { expecting $3 "pattern" }
;
pattern_semi_list:
    pattern                                     { [$1] }
  | pattern_semi_list SEMI pattern              { $3 :: $1 }
;
lbl_pattern_list:
    lbl_pattern { [$1], Closed }
  | lbl_pattern SEMI { [$1], Closed }
  | lbl_pattern SEMI UNDERSCORE opt_semi { [$1], Open }
  | lbl_pattern SEMI lbl_pattern_list
      { let (fields, closed) = $3 in $1 :: fields, closed }
;
lbl_pattern:
    mkrhs(label_longident) opt_pattern_type_constraint EQUAL pattern
     { let loc = make_loc $symbolstartpos $endpos in
       ($1, mkpat_opt_constraint ~loc $4 $2) }
  | mkrhs(label_longident) opt_pattern_type_constraint
     { let loc = make_loc $symbolstartpos $endpos in
       ($1, mkpat_opt_constraint ~loc (pat_of_label ~loc $1) $2) }
;
opt_pattern_type_constraint:
    COLON core_type { Some $2 }
  | /* empty */ { None }
;

/* Value descriptions */

value_description:
    VAL ext_attributes mkrhs(val_ident) COLON core_type post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Val.mk $3 $5 ~attrs:(attrs@$6) ~loc ~docs, ext }
;

/* Primitive declarations */

primitive_declaration_body:
    STRING                                      { [fst $1] }
  | STRING primitive_declaration_body           { fst $1 :: $2 }
;
primitive_declaration:
    EXTERNAL ext_attributes mkrhs(val_ident) COLON core_type EQUAL
    primitive_declaration_body post_item_attributes
      { let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Val.mk $3 $5 ~prim:$7 ~attrs:(attrs@$8) ~loc ~docs, ext }
;

/* Type declarations */

type_declarations:
    type_declaration
      { let (nonrec_flag, ty, ext) = $1 in (nonrec_flag, [ty], ext) }
  | type_declarations and_type_declaration
      { let (nonrec_flag, tys, ext) = $1 in (nonrec_flag, $2 :: tys, ext) }
;

type_declaration:
    TYPE ext_attributes nonrec_flag optional_type_parameters mkrhs(LIDENT)
    type_kind constraints post_item_attributes
      { let (kind, priv, manifest) = $6 in
        let (ext, attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        let ty =
          Type.mk $5 ~params:$4 ~cstrs:(List.rev $7) ~kind
            ~priv ?manifest ~attrs:(attrs@$8) ~loc ~docs
        in
          ($3, ty, ext) }
;
and_type_declaration:
    AND attributes optional_type_parameters mkrhs(LIDENT) type_kind constraints
    post_item_attributes
      { let (kind, priv, manifest) = $5 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        let text = symbol_text $symbolstartpos in
        Type.mk $4 ~params:$3 ~cstrs:(List.rev $6)
          ~kind ~priv ?manifest ~attrs:($2@$7) ~loc ~docs ~text }
;
constraints:
        constraints CONSTRAINT constrain        { $3 :: $1 }
      | /* empty */                             { [] }
;
type_kind:
    /*empty*/
      { (Ptype_abstract, Public, None) }
  | EQUAL core_type
      { (Ptype_abstract, Public, Some $2) }
  | EQUAL PRIVATE core_type
      { (Ptype_abstract, Private, Some $3) }
  | EQUAL constructor_declarations
      { (Ptype_variant(List.rev $2), Public, None) }
  | EQUAL PRIVATE constructor_declarations
      { (Ptype_variant(List.rev $3), Private, None) }
  | EQUAL DOTDOT
      { (Ptype_open, Public, None) }
  | EQUAL PRIVATE DOTDOT
      { (Ptype_open, Private, None) }
  | EQUAL private_flag LBRACE label_declarations RBRACE
      { (Ptype_record $4, $2, None) }
  | EQUAL core_type EQUAL private_flag constructor_declarations
      { (Ptype_variant(List.rev $5), $4, Some $2) }
  | EQUAL core_type EQUAL private_flag DOTDOT
      { (Ptype_open, $4, Some $2) }
  | EQUAL core_type EQUAL private_flag LBRACE label_declarations RBRACE
      { (Ptype_record $6, $4, Some $2) }
;
optional_type_parameters:
    /*empty*/                                   { [] }
  | optional_type_parameter                     { [$1] }
  | LPAREN optional_type_parameter_list RPAREN  { List.rev $2 }
;
optional_type_parameter:
    type_variance optional_type_variable        { $2, $1 }
;
optional_type_parameter_list:
    optional_type_parameter                              { [$1] }
  | optional_type_parameter_list COMMA optional_type_parameter    { $3 :: $1 }
;
optional_type_variable2:
    QUOTE ident                                 { Ptyp_var $2 }
  | UNDERSCORE                                  { Ptyp_any }
;
optional_type_variable:
    mktyp(optional_type_variable2) { $1 }
;

type_parameter:
    type_variance type_variable                   { $2, $1 }
;
type_variance:
    /* empty */                                 { Invariant }
  | PLUS                                        { Covariant }
  | MINUS                                       { Contravariant }
;
type_variable:
    mktyp(QUOTE ident { Ptyp_var $2 }) { $1 }
;
type_parameter_list:
    type_parameter                              { [$1] }
  | type_parameter_list COMMA type_parameter    { $3 :: $1 }
;
constructor_declarations:
  | BAR                                                  { [  ] }
  | constructor_declaration                              { [$1] }
  | bar_constructor_declaration                          { [$1] }
  | constructor_declarations bar_constructor_declaration { $2 :: $1 }
;
constructor_declaration:
  | mkrhs(constr_ident) generalized_constructor_arguments attributes
    { let args,res = $2 in
      let loc = make_loc $symbolstartpos $endpos in
      let info = symbol_info $endpos in
      Type.constructor $1 ~args ?res ~attrs:$3 ~loc ~info }
;
bar_constructor_declaration:
  | BAR mkrhs(constr_ident) generalized_constructor_arguments attributes
    { let args,res = $3 in
      let loc = make_loc $symbolstartpos $endpos in
      let info = symbol_info $endpos in
      Type.constructor $2 ~args ?res ~attrs:$4 ~loc ~info }
;
str_exception_declaration:
  | sig_exception_declaration                    { $1 }
  | EXCEPTION ext_attributes mkrhs(constr_ident) EQUAL mkrhs(constr_longident) attributes
    post_item_attributes
    { let (ext,attrs) = $2 in
      let loc = make_loc $symbolstartpos $endpos in
      let docs = symbol_docs $symbolstartpos $endpos in
      Te.mk_exception ~attrs:$7
        (Te.rebind $3 $5 ~attrs:(attrs @ $6) ~loc ~docs)
      , ext }
;
sig_exception_declaration:
  | EXCEPTION ext_attributes mkrhs(constr_ident) generalized_constructor_arguments
    attributes post_item_attributes
      { let args, res = $4 in
        let (ext,attrs) = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let docs = symbol_docs $symbolstartpos $endpos in
        Te.mk_exception ~attrs:$6
          (Te.decl $3 ~args ?res ~attrs:(attrs @ $5) ~loc ~docs)
        , ext }
;
let_exception_declaration:
    mkrhs(constr_ident) generalized_constructor_arguments attributes
      { let args, res = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        Te.decl $1 ~args ?res ~attrs:$3 ~loc }
;
generalized_constructor_arguments:
    /*empty*/                     { (Pcstr_tuple [],None) }
  | OF constructor_arguments      { ($2,None) }
  | COLON constructor_arguments MINUSGREATER simple_core_type
                                  { ($2,Some $4) }
  | COLON simple_core_type
                                  { (Pcstr_tuple [],Some $2) }
;

constructor_arguments:
  | core_type_list                   { Pcstr_tuple (List.rev $1) }
  | LBRACE label_declarations RBRACE { Pcstr_record $2 }
;
label_declarations:
    label_declaration                           { [$1] }
  | label_declaration_semi                      { [$1] }
  | label_declaration_semi label_declarations   { $1 :: $2 }
;
label_declaration:
    mutable_flag mkrhs(label) COLON poly_type_no_attr attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let info = symbol_info $endpos in
        Type.field $2 $4 ~mut:$1 ~attrs:$5 ~loc ~info }
;
label_declaration_semi:
    mutable_flag mkrhs(label) COLON poly_type_no_attr attributes SEMI attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let info =
          match rhs_info $endpos($5) with
          | Some _ as info_before_semi -> info_before_semi
          | None -> symbol_info $endpos
       in
       Type.field $2 $4 ~mut:$1 ~attrs:($5 @ $7) ~loc ~info }
;

/* Type Extensions */

str_type_extension:
  TYPE ext_attributes
  with_loc(nonrec_flag) optional_type_parameters mkrhs(type_longident)
  PLUSEQ private_flag str_extension_constructors post_item_attributes
      { let (ext, attrs) = $2 in
        if fst $3 <> Recursive then not_expecting (snd $3) "nonrec flag";
        let docs = symbol_docs $symbolstartpos $endpos in
        Te.mk $5 (List.rev $8) ~params:$4 ~priv:$7 ~attrs:(attrs@$9) ~docs
        , ext }
;
sig_type_extension:
  TYPE ext_attributes
  with_loc(nonrec_flag) optional_type_parameters mkrhs(type_longident)
  PLUSEQ private_flag sig_extension_constructors post_item_attributes
      { let (ext, attrs) = $2 in
        if fst $3 <> Recursive then not_expecting (snd $3) "nonrec flag";
        let docs = symbol_docs $symbolstartpos $endpos in
        Te.mk $5 (List.rev $8) ~params:$4 ~priv:$7 ~attrs:(attrs@$9) ~docs
        , ext }
;
str_extension_constructors:
    extension_constructor_declaration                     { [$1] }
  | bar_extension_constructor_declaration                 { [$1] }
  | extension_constructor_rebind                          { [$1] }
  | bar_extension_constructor_rebind                      { [$1] }
  | str_extension_constructors bar_extension_constructor_declaration
      { $2 :: $1 }
  | str_extension_constructors bar_extension_constructor_rebind
      { $2 :: $1 }
;
sig_extension_constructors:
    extension_constructor_declaration                     { [$1] }
  | bar_extension_constructor_declaration                 { [$1] }
  | sig_extension_constructors bar_extension_constructor_declaration
      { $2 :: $1 }
;
extension_constructor_declaration:
  | mkrhs(constr_ident) generalized_constructor_arguments attributes
      { let args, res = $2 in
        let loc = make_loc $symbolstartpos $endpos in
        let info = symbol_info $endpos in
        Te.decl $1 ~args ?res ~attrs:$3 ~loc ~info }
;
bar_extension_constructor_declaration:
  | BAR mkrhs(constr_ident) generalized_constructor_arguments attributes
      { let args, res = $3 in
        let loc = make_loc $symbolstartpos $endpos in
        let info = symbol_info $endpos in
        Te.decl $2 ~args ?res ~attrs:$4 ~loc ~info }
;
extension_constructor_rebind:
  | mkrhs(constr_ident) EQUAL mkrhs(constr_longident) attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let info = symbol_info $endpos in
        Te.rebind $1 $3 ~attrs:$4 ~loc ~info }
;
bar_extension_constructor_rebind:
  | BAR mkrhs(constr_ident) EQUAL mkrhs(constr_longident) attributes
      { let loc = make_loc $symbolstartpos $endpos in
        let info = symbol_info $endpos in
        Te.rebind $2 $4 ~attrs:$5 ~loc ~info }
;

/* "with" constraints (additional type equations over signature components) */

with_constraints:
    with_constraint                             { [$1] }
  | with_constraints AND with_constraint        { $3 :: $1 }
;
with_constraint:
    TYPE optional_type_parameters mkrhs(label_longident) with_type_binder
    core_type_no_attr constraints
      { let loc = make_loc $symbolstartpos $endpos in
        let lident = Location.{ $3 with txt = Longident.last $3.txt } in
        Pwith_type
          ($3,
           (Type.mk lident
              ~params:$2
              ~cstrs:(List.rev $6)
              ~manifest:$5
              ~priv:$4
              ~loc)) }
    /* used label_longident instead of type_longident to disallow
       functor applications in type path */
  | TYPE optional_type_parameters mkrhs(label_longident) COLONEQUAL core_type_no_attr
      { let loc = make_loc $symbolstartpos $endpos in
        let lident = Location.{ $3 with txt = Longident.last $3.txt } in
        Pwith_typesubst
         ($3,
           (Type.mk lident
              ~params:$2
              ~manifest:$5
              ~loc)) }
  | MODULE mkrhs(mod_longident) EQUAL mkrhs(mod_ext_longident)
      { Pwith_module ($2, $4) }
  | MODULE mkrhs(mod_longident) COLONEQUAL mkrhs(mod_ext_longident)
      { Pwith_modsubst ($2, $4) }
;
with_type_binder:
    EQUAL          { Public }
  | EQUAL PRIVATE  { Private }
;

/* Polymorphic types */

typevar_list:
        QUOTE mkrhs(ident)                      { [$2] }
      | typevar_list QUOTE mkrhs(ident)         { $3 :: $1 }
;
poly_type:
        core_type
          { $1 }
      | mktyp(typevar_list DOT core_type
          { Ptyp_poly(List.rev $1, $3) })
          { $1 }
;
poly_type_no_attr:
        core_type_no_attr
          { $1 }
      | mktyp(typevar_list DOT core_type_no_attr
          { Ptyp_poly(List.rev $1, $3) })
          { $1 }
;

/* Core types */

core_type:
    core_type_no_attr
      { $1 }
  | core_type attribute
      { Typ.attr $1 $2 }
;
core_type_no_attr:
    core_type2 %prec MINUSGREATER
      { $1 }
  | mktyp(core_type2 AS QUOTE ident
      { Ptyp_alias($1, $4) })
      { $1 }
;
core_type3:
    QUESTION LIDENT COLON extra_core_type2 MINUSGREATER core_type2
      { Ptyp_arrow(Optional $2, $4, $6) }
  | OPTLABEL extra_core_type2 MINUSGREATER core_type2
      { Ptyp_arrow(Optional $1 , $2, $4) }
  | LIDENT COLON extra_core_type2 MINUSGREATER core_type2
      { Ptyp_arrow(Labelled $1, $3, $5) }
  | extra_core_type2 MINUSGREATER core_type2
      { Ptyp_arrow(Nolabel, $1, $3) }
;
core_type2:
    simple_core_type_or_tuple
      { $1 }
  | mktyp(core_type3)
      { $1 }
;
%inline extra_core_type2: core_type2 { extra_rhs_core_type $1 ~pos:$endpos($1) };

simple_core_type:
    simple_core_type2  %prec below_HASH
      { $1 }
  | LPAREN core_type_comma_list RPAREN %prec below_HASH
      { match $2 with [sty] -> sty | _ -> raise Parsing.Parse_error }
;

simple_core_type3:
    QUOTE ident
      { Ptyp_var $2 }
  | UNDERSCORE
      { Ptyp_any }
  | mkrhs(type_longident)
      { Ptyp_constr($1, []) }
  | simple_core_type2 mkrhs(type_longident)
      { Ptyp_constr($2, [$1]) }
  | LPAREN core_type_comma_list RPAREN mkrhs(type_longident)
      { Ptyp_constr($4, List.rev $2) }
  | LESS meth_list GREATER
      { let (f, c) = $2 in Ptyp_object (f, c) }
  | LESS GREATER
      { Ptyp_object ([], Closed) }
  | HASH mkrhs(class_longident)
      { Ptyp_class($2, []) }
  | simple_core_type2 HASH mkrhs(class_longident)
      { Ptyp_class($3, [$1]) }
  | LPAREN core_type_comma_list RPAREN HASH mkrhs(class_longident)
      { Ptyp_class($5, List.rev $2) }
  | LBRACKET tag_field RBRACKET
      { Ptyp_variant([$2], Closed, None) }
/* PR#3835: this is not LR(1), would need lookahead=2
  | LBRACKET simple_core_type RBRACKET
      { Ptyp_variant([$2], Closed, None) }
*/
  | LBRACKET BAR row_field_list RBRACKET
      { Ptyp_variant(List.rev $3, Closed, None) }
  | LBRACKET row_field BAR row_field_list RBRACKET
      { Ptyp_variant($2 :: List.rev $4, Closed, None) }
  | LBRACKETGREATER opt_bar row_field_list RBRACKET
      { Ptyp_variant(List.rev $3, Open, None) }
  | LBRACKETGREATER RBRACKET
      { Ptyp_variant([], Open, None) }
  | LBRACKETLESS opt_bar row_field_list RBRACKET
      { Ptyp_variant(List.rev $3, Closed, Some []) }
  | LBRACKETLESS opt_bar row_field_list GREATER name_tag_list RBRACKET
      { Ptyp_variant(List.rev $3, Closed, Some (List.rev $5)) }
  | extension
      { Ptyp_extension $1 }
;
simple_core_type2:
    mktyp(simple_core_type3)
      { $1 }
  | LPAREN MODULE ext_attributes package_type RPAREN
      { let loc = make_loc $symbolstartpos $endpos in
        wrap_typ_attrs ~loc (reloc_typ ~loc $4) $3 }
;
package_type:
    mktyp(module_type
      { Ptyp_package (package_type_of_module_type $1) })
      { $1 }
;
row_field_list:
    row_field                                   { [$1] }
  | row_field_list BAR row_field                { $3 :: $1 }
;
row_field:
    tag_field                                   { $1 }
  | simple_core_type                            { Rinherit $1 }
;
tag_field:
    mkrhs(name_tag) OF opt_ampersand amper_type_list attributes
      { let info = symbol_info $endpos in
        Rtag ($1, add_info_attrs info $5, $3, List.rev $4) }
  | mkrhs(name_tag) attributes
      { let info = symbol_info $endpos in
        Rtag ($1, add_info_attrs info $2, true, []) }
;
opt_ampersand:
    AMPERSAND                                   { true }
  | /* empty */                                 { false }
;
amper_type_list:
    core_type_no_attr                           { [$1] }
  | amper_type_list AMPERSAND core_type_no_attr { $3 :: $1 }
;
name_tag_list:
    name_tag                                    { [$1] }
  | name_tag_list name_tag                      { $2 :: $1 }
;
simple_core_type_or_tuple:
    simple_core_type { $1 }
  | mktyp(simple_core_type STAR core_type_list
      { Ptyp_tuple($1 :: List.rev $3) })
      { $1 }
;
core_type_comma_list:
    core_type                                   { [$1] }
  | core_type_comma_list COMMA core_type        { $3 :: $1 }
;
core_type_list:
    simple_core_type                            { [$1] }
  | core_type_list STAR simple_core_type        { $3 :: $1 }
;
meth_list:
    field_semi meth_list
      { let (f, c) = $2 in ($1 :: f, c) }
  | inherit_field_semi meth_list
      { let (f, c) = $2 in ($1 :: f, c) }
  | field_semi                                  { [$1], Closed }
  | field                                       { [$1], Closed }
  | inherit_field_semi                          { [$1], Closed }
  | simple_core_type                            { [Oinherit $1], Closed }
  | DOTDOT                                      { [], Open }
;
field:
  mkrhs(label) COLON poly_type_no_attr attributes
    { let info = symbol_info $endpos in
      Otag ($1, add_info_attrs info $4, $3) }
;

field_semi:
  mkrhs(label) COLON poly_type_no_attr attributes SEMI attributes
    { let info =
        match rhs_info $endpos($4) with
        | Some _ as info_before_semi -> info_before_semi
        | None -> symbol_info $endpos
      in
      ( Otag ($1, add_info_attrs info ($4 @ $6), $3)) }
;

inherit_field_semi:
  simple_core_type SEMI { Oinherit $1 }

label:
    LIDENT                                      { $1 }
;

/* Constants */

constant:
  | INT          { let (n, m) = $1 in Pconst_integer (n, m) }
  | CHAR         { Pconst_char $1 }
  | STRING       { let (s, d) = $1 in Pconst_string (s, d) }
  | FLOAT        { let (f, m) = $1 in Pconst_float (f, m) }
;
signed_constant:
    constant     { $1 }
  | MINUS INT    { let (n, m) = $2 in Pconst_integer("-" ^ n, m) }
  | MINUS FLOAT  { let (f, m) = $2 in Pconst_float("-" ^ f, m) }
  | PLUS INT     { let (n, m) = $2 in Pconst_integer (n, m) }
  | PLUS FLOAT   { let (f, m) = $2 in Pconst_float(f, m) }
;

/* Identifiers and long identifiers */

ident:
    UIDENT                                      { $1 }
  | LIDENT                                      { $1 }
;
val_ident:
    LIDENT                                      { $1 }
  | LPAREN operator RPAREN                      { $2 }
  | only_loc(LPAREN) operator only_loc(error)   { unclosed "(" $1 ")" $3 }
  | LPAREN only_loc(error)                      { expecting $2 "operator" }
  | LPAREN MODULE only_loc(error)               { expecting $3 "module-expr" }
;
operator:
    PREFIXOP                                    { $1 }
  | INFIXOP0                                    { $1 }
  | INFIXOP1                                    { $1 }
  | INFIXOP2                                    { $1 }
  | INFIXOP3                                    { $1 }
  | INFIXOP4                                    { $1 }
  | DOTOP LPAREN RPAREN                         { "."^ $1 ^"()" }
  | DOTOP LPAREN RPAREN LESSMINUS               { "."^ $1 ^ "()<-" }
  | DOTOP LBRACKET RBRACKET                     { "."^ $1 ^"[]" }
  | DOTOP LBRACKET RBRACKET LESSMINUS           { "."^ $1 ^ "[]<-" }
  | DOTOP LBRACE RBRACE                         { "."^ $1 ^"{}" }
  | DOTOP LBRACE RBRACE LESSMINUS               { "."^ $1 ^ "{}<-" }
  | HASHOP                                      { $1 }
  | BANG                                        { "!" }
  | PLUS                                        { "+" }
  | PLUSDOT                                     { "+." }
  | MINUS                                       { "-" }
  | MINUSDOT                                    { "-." }
  | STAR                                        { "*" }
  | EQUAL                                       { "=" }
  | LESS                                        { "<" }
  | GREATER                                     { ">" }
  | OR                                          { "or" }
  | BARBAR                                      { "||" }
  | AMPERSAND                                   { "&" }
  | AMPERAMPER                                  { "&&" }
  | COLONEQUAL                                  { ":=" }
  | PLUSEQ                                      { "+=" }
  | PERCENT                                     { "%" }
;
constr_ident:
    UIDENT                                      { $1 }
  | LBRACKET RBRACKET                           { "[]" }
  | LPAREN RPAREN                               { "()" }
  | LPAREN COLONCOLON RPAREN                    { "::" }
  | FALSE                                       { "false" }
  | TRUE                                        { "true" }
;

val_longident:
    val_ident                                   { Lident $1 }
  | mod_longident DOT val_ident                 { Ldot($1, $3) }
;
constr_longident:
    mod_longident       %prec below_DOT         { $1 }
  | mod_longident DOT LPAREN COLONCOLON RPAREN  { Ldot($1,"::") }
  | LBRACKET RBRACKET                           { Lident "[]" }
  | LPAREN RPAREN                               { Lident "()" }
  | LPAREN COLONCOLON RPAREN                    { Lident "::" }
  | FALSE                                       { Lident "false" }
  | TRUE                                        { Lident "true" }
;
label_longident:
    LIDENT                                      { Lident $1 }
  | mod_longident DOT LIDENT                    { Ldot($1, $3) }
;
type_longident:
    LIDENT                                      { Lident $1 }
  | mod_ext_longident DOT LIDENT                { Ldot($1, $3) }
;
mod_longident:
    UIDENT                                      { Lident $1 }
  | mod_longident DOT UIDENT                    { Ldot($1, $3) }
;
mod_ext_longident:
    UIDENT                                      { Lident $1 }
  | mod_ext_longident DOT UIDENT                { Ldot($1, $3) }
  | mod_ext_longident LPAREN mod_ext_longident RPAREN { lapply $1 $3 }
;
mty_longident:
    ident                                       { Lident $1 }
  | mod_ext_longident DOT ident                 { Ldot($1, $3) }
;
clty_longident:
    LIDENT                                      { Lident $1 }
  | mod_ext_longident DOT LIDENT                { Ldot($1, $3) }
;
class_longident:
    LIDENT                                      { Lident $1 }
  | mod_longident DOT LIDENT                    { Ldot($1, $3) }
;

/* Toplevel directives */

toplevel_directive:
    HASH ident                 { Ptop_dir($2, Pdir_none) }
  | HASH ident STRING          { Ptop_dir($2, Pdir_string (fst $3)) }
  | HASH ident INT             { let (n, m) = $3 in
                                  Ptop_dir($2, Pdir_int (n ,m)) }
  | HASH ident val_longident   { Ptop_dir($2, Pdir_ident $3) }
  | HASH ident mod_longident   { Ptop_dir($2, Pdir_ident $3) }
  | HASH ident FALSE           { Ptop_dir($2, Pdir_bool false) }
  | HASH ident TRUE            { Ptop_dir($2, Pdir_bool true) }
;

/* Miscellaneous */

name_tag:
    BACKQUOTE ident                             { $2 }
;
rec_flag:
    /* empty */                                 { Nonrecursive }
  | REC                                         { Recursive }
;
nonrec_flag:
    /* empty */                                 { Recursive }
  | NONREC                                      { Nonrecursive }
;
direction_flag:
    TO                                          { Upto }
  | DOWNTO                                      { Downto }
;
private_flag:
    /* empty */                                 { Public }
  | PRIVATE                                     { Private }
;
mutable_flag:
    /* empty */                                 { Immutable }
  | MUTABLE                                     { Mutable }
;
virtual_flag:
    /* empty */                                 { Concrete }
  | VIRTUAL                                     { Virtual }
;
private_virtual_flags:
    /* empty */  { Public, Concrete }
  | PRIVATE { Private, Concrete }
  | VIRTUAL { Public, Virtual }
  | PRIVATE VIRTUAL { Private, Virtual }
  | VIRTUAL PRIVATE { Private, Virtual }
;
override_flag:
    /* empty */                                 { Fresh }
  | BANG                                        { Override }
;
opt_bar:
    /* empty */                                 { () }
  | BAR                                         { () }
;
opt_semi:
  | /* empty */                                 { () }
  | SEMI                                        { () }
;
subtractive:
  | MINUS                                       { "-" }
  | MINUSDOT                                    { "-." }
;
additive:
  | PLUS                                        { "+" }
  | PLUSDOT                                     { "+." }
;

/* Attributes and extensions */

single_attr_id:
    LIDENT { $1 }
  | UIDENT { $1 }
  | AND { "and" }
  | AS { "as" }
  | ASSERT { "assert" }
  | BEGIN { "begin" }
  | CLASS { "class" }
  | CONSTRAINT { "constraint" }
  | DO { "do" }
  | DONE { "done" }
  | DOWNTO { "downto" }
  | ELSE { "else" }
  | END { "end" }
  | EXCEPTION { "exception" }
  | EXTERNAL { "external" }
  | FALSE { "false" }
  | FOR { "for" }
  | FUN { "fun" }
  | FUNCTION { "function" }
  | FUNCTOR { "functor" }
  | IF { "if" }
  | IN { "in" }
  | INCLUDE { "include" }
  | INHERIT { "inherit" }
  | INITIALIZER { "initializer" }
  | LAZY { "lazy" }
  | LET { "let" }
  | MATCH { "match" }
  | METHOD { "method" }
  | MODULE { "module" }
  | MUTABLE { "mutable" }
  | NEW { "new" }
  | NONREC { "nonrec" }
  | OBJECT { "object" }
  | OF { "of" }
  | OPEN { "open" }
  | OR { "or" }
  | PRIVATE { "private" }
  | REC { "rec" }
  | SIG { "sig" }
  | STRUCT { "struct" }
  | THEN { "then" }
  | TO { "to" }
  | TRUE { "true" }
  | TRY { "try" }
  | TYPE { "type" }
  | VAL { "val" }
  | VIRTUAL { "virtual" }
  | WHEN { "when" }
  | WHILE { "while" }
  | WITH { "with" }
/* mod/land/lor/lxor/lsl/lsr/asr are not supported for now */
;

attr_id:
  mkloc(
      single_attr_id { $1 }
    | single_attr_id DOT attr_id { $1 ^ "." ^ $3.txt }
  ) { $1 }
;
attribute:
  LBRACKETAT attr_id payload RBRACKET { ($2, $3) }
;
post_item_attribute:
  LBRACKETATAT attr_id payload RBRACKET { ($2, $3) }
;
floating_attribute:
  LBRACKETATATAT attr_id payload RBRACKET
      { mark_symbol_docs $symbolstartpos $endpos;
        ($2, $3) }
;
post_item_attributes:
    /* empty */  { [] }
  | post_item_attribute post_item_attributes { $1 :: $2 }
;
attributes:
    /* empty */{ [] }
  | attribute attributes { $1 :: $2 }
;
ext_attributes:
    /* empty */  { None, [] }
  | attribute attributes { None, $1 :: $2 }
  | PERCENT attr_id attributes { Some $2, $3 }
;
extension:
  LBRACKETPERCENT attr_id payload RBRACKET { ($2, $3) }
;
item_extension:
  LBRACKETPERCENTPERCENT attr_id payload RBRACKET { ($2, $3) }
;
payload:
    structure { PStr $1 }
  | COLON signature { PSig $2 }
  | COLON core_type { PTyp $2 }
  | QUESTION pattern { PPat ($2, None) }
  | QUESTION pattern WHEN seq_expr { PPat ($2, Some $4) }
;
%%
