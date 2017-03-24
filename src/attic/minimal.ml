(******************************************************************************)
(*                                                                            *)
(*                                   Menhir                                   *)
(*                                                                            *)
(*                       François Pottier, Inria Paris                        *)
(*              Yann Régis-Gianas, PPS, Université Paris Diderot              *)
(*                                                                            *)
(*  Copyright Inria. All rights reserved. This file is distributed under the  *)
(*  terms of the GNU General Public License version 2, as described in the    *)
(*  file LICENSE.                                                             *)
(*                                                                            *)
(******************************************************************************)

(* See the commit entitled:
   Removed the analysis [MINIMAL] and moved [CompletedNatWitness] and [Seq] to the attic.
*)

(* ------------------------------------------------------------------------ *)
(* For every nonterminal symbol [nt], compute a word of minimal length
   generated by [nt]. This analysis subsumes [NONEMPTY] and [NULLABLE].
   Indeed, [nt] produces a nonempty language if only if the minimal length is
   finite; [nt] is nullable if only if the minimal length is zero. *)

(* This analysis is in principle more costly than the [NONEMPTY] and
   [NULLABLE], so it is performed only on demand. In practice, it seems
   to be very cheap: its cost is not measurable for any of the grammars
   in our benchmark suite. *)

module MINIMAL =
  GenericAnalysis
    (struct
      include CompletedNatWitness
      type property = Terminal.t t
     end)
    (struct
      open CompletedNatWitness
      (* A terminal symbol has length 1. *)
      let terminal = singleton
      (* The length of an alternative is the minimum length of any branch. *)
      let disjunction = min_lazy
      (* The length of a sequence is the sum of the lengths of the members. *)
      let conjunction _ = add_lazy
      (* The epsilon sequence has length 0. *)
      let epsilon = epsilon
     end)

let () =
  Error.logG 2 (fun f ->
    for nt = Nonterminal.start to Nonterminal.n - 1 do
      Printf.fprintf f "minimal(%s) = %s\n"
        (Nonterminal.print false nt)
        (CompletedNatWitness.print Terminal.print (MINIMAL.nonterminal nt))
    done
  )

