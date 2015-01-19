module Make
  (I : MenhirLib.IncrementalEngine.EVERYTHING)
  (User : sig

    (* In order to submit artificial tokens to the parser, we need a function
       that converts a terminal symbol to a token. Unfortunately, we cannot
       (in general) auto-generate this code, because it requires making up
       semantic values of arbitrary OCaml types. *)

    val terminal2token: _ I.terminal -> I.token

  end)
= struct

  open MenhirLib.General
  open I
  open User

  (* [items_current env] assumes that [env] is not an initial state (which
     implies that the stack is non-empty). Under this assumption, it extracts
     the automaton's current state, i.e., the LR(1) state found in the top
     stack cell. It then goes through [items] so as to obtain the LR(0) items
     associated with this state. *)

  let items_current env : item list =
    (* Get the current state. *)
    match Lazy.force (stack env) with
    | Nil ->
        (* If we get here, then the stack is empty, which means the parser
           is an initial state. This should not happen. *)
        invalid_arg "items_current"
    | Cons (Element (current, _, _, _), _) ->
        (* Extract the current state out of the top stack element, and
           convert it to a set of LR(0) items. Returning a set of items
           instead of an ['a lr1state] is convenient; returning [current]
           would require wrapping it in an existential type. *)
        items current

  (* [test_shift_item t item] tests whether [item] justifies a shift
     transition along the terminal symbol [t]. If so, it returns [item],
     wrapped in a singleton list. Otherwise, it returns the empty list. *)

  let test_shift_item (t : _ terminal) ((prod, index) as item) : item list =
    let rhs = rhs prod in
    let length = List.length rhs in
    assert (0 < index && index <= length);
    (* We test that there is one symbol after the bullet and this symbol
       is [t] or can generate a word that begins with [t]. (Note that we
       don't need to worry about the case where this symbol is nullable
       and [t] is generated by the following symbol. In that situation,
       we would have to reduce before we can shift [t].) *)
    if index < length && xfirst (List.nth rhs index) t then
      [ item ]
    else
      []

  (* An explanation is a description of what the parser has recognized in the
     recent past and what it expects next. For now, an explanation is just an
     item. *)

  type explanation =
      item

  let compare_explanations =
    compare_items

  (* We build lists of explanations. These explanations may originate in
     distinct LR(1) states. *)

  type explanations =
      explanation list

  (* [investigate t result] assumes that [result] has been obtained by
     offering the terminal symbol [t] to the parser. It runs the parser,
     through an arbitrary number of reductions, until the parser either
     accepts this token (i.e., shifts) or rejects it (i.e., signals an
     error). If the parser decides to shift, then the shift items found in the
     LR(1) state before the shift are used to produce new explanations. *)

  (* It is desirable that the semantic actions be side-effect free, or
     that their side-effects be harmless (replayable). *)

  let rec investigate (t : _ terminal) (result : _ result) (explanations : explanations) : explanations =
    match result with
    | Shifting (env, _, _) ->
        (* The parser is about to shift, which means it is willing to
           consume the terminal symbol [t]. In the state before the
           transition, look at the items that justify shifting [t].
           We view these items as explanations: they explain what
           we have read and what we expect to read. *)
        (* TEMPORARY might also wish to extract a start location from the stack *)
        List.fold_left (fun explanations item ->
          test_shift_item t item @ explanations
        ) explanations (items_current env)
    | AboutToReduce (_, prod) ->
        (* The parser wishes to reduce. Just follow. *)
        investigate t (resume result) explanations
    | HandlingError _ ->
        (* The parser fails, which means the terminal symbol [t] does
           not make sense at this point. Thus, no new explanations of
           what the parser expects need be produced. *)
        explanations
    | InputNeeded _
    | Accepted _
    | Rejected ->
        (* None of these cases can arise. Indeed, after a token is submitted
           to it, the parser must shift, reduce, or signal an error, before
           it can request another token or terminate. *)
        assert false

  (* [investigate result] assumes that [result] is of the form [InputNeeded _].
     For every terminal symbol [t], it investigates how the parser reacts when
     fed the symbol [t], and returns a list of explanations. *)

  let investigate (result : _ result) : explanations =
    weed compare_explanations (
      foreach_terminal_but_error (fun symbol explanations ->
        match symbol with
        | X (N _) -> assert false
        | X (T t) ->
            (* Build a dummy token for the terminal symbol [t]. *)
            let pos = Lexing.dummy_pos in
            let token = (terminal2token t, pos, pos) in
            (* Submit it to the parser. Accumulate explanations. *)
            investigate t (offer result token) explanations
      ) []
    )

  (* TEMPORARY copied from engine.ml; move/share with [Convert] *)

  type reader =
    unit -> token * Lexing.position * Lexing.position

  let wrap (lexer : Lexing.lexbuf -> token) (lexbuf : Lexing.lexbuf) : reader =
    fun () ->
      let token = lexer lexbuf in
      let startp = lexbuf.Lexing.lex_start_p
      and endp = lexbuf.Lexing.lex_curr_p in
      token, startp, endp

  (* The following is a custom version of the loop found in [MenhirLib.Engine].
     It drives the parser in the usual way, but keeps a checkpoint, which is
     the last [InputNeeded] result. If a syntax error is detected, it goes back
     to this state and analyzes it in order to produce a meaningful diagnostic. *)

  exception Error of explanations

  (* TEMPORARY why loop-style? we should offer a simplified incremental API *)

  type 'a result = {
    checkpoint: 'a I.result;
    current: 'a I.result
  }

  let rec loop (read : reader) ({ checkpoint; current } : 'a result) : 'a =
    match current with
    | InputNeeded env ->
        (* Update the checkpoint. *)
        let checkpoint = current in
        let triple = read() in
        let current = offer current triple in
        loop read { checkpoint; current }
    | Shifting _
    | AboutToReduce _ ->
        let current = resume current in
        loop read { checkpoint; current }
    | HandlingError _ ->
        (* The parser signals a syntax error. Go back to the checkpoint
           and investigate. *)
        raise (Error (investigate checkpoint))
    | Accepted v ->
        v
    | Rejected ->
        (* The parser rejects this input. This cannot happen, because
           we stop as soon as the parser reports [HandlingError]. *)
        assert false

  let entry (start : 'a I.result) lexer lexbuf =
    (* The parser cannot accept or reject before it asks for the very first
       character of input. (Indeed, we statically reject a symbol that
       generates the empty language or the singleton language {epsilon}.)
       So, [start] must be [InputNeeded _]. *)
    assert (match start with InputNeeded _ -> true | _ -> false);
    loop (wrap lexer lexbuf) { checkpoint = start; current = start }

end
