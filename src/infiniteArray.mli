(** This module implements infinite arrays. **)
type 'a t

(** [make x] creates an infinite array, where every slot contains [x]. **)
val make: 'a -> 'a t

(** [get a i] returns the element contained at offset [i] in the array [a].
   Slots are numbered 0 and up. **)
val get: 'a t -> int -> 'a

(** [set a i x] sets the element contained at offset [i] in the array
    [a] to [x]. Slots are numbered 0 and up. **)
val set: 'a t -> int -> 'a -> unit

(** [update a i f] is equivalent to [set a i (f (get a i))]. *)
val update: 'a t -> int -> ('a -> 'a) -> unit

(** [extent a] is the length of an initial segment of the array [a]
    that is sufficiently large to contain all [set] operations ever
    performed. In other words, all elements beyond that segment have
    the default value. *)
val extent: 'a t -> int

(** [domain a] is a fresh copy of an initial segment of the array [a]
    whose length is [extent a]. *)
val domain: 'a t -> 'a array
