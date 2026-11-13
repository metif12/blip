# About blip

blip is a Lisp dialect implemented in V. Evaluation is a CEK machine whose stack is an ordinary heap array, which is what makes tail calls structural: a tail call is a loop iteration, not a stack mutation.

The language is designed so ordinary programs are written **without macros** — while macros remain for the cases that genuinely need them. S-expressions and a Racket-shaped surface, plus three things modern Lisps have each solved separately and no single language has combined: `match*` for atomic multi-subject matching, `use` for flat fallible chains, and opaque types for encapsulation without a class system.

## Design points

- **Errors are values.** A failure is an `(err ...)` value the program can match on, not an exception that unwinds past it.
- **Flat chains.** `use` binds a call's result for the body that follows, so four nested calls read as four flat lines.
- **Atomic matching.** `match*` destructures several values at once; a clause matches only if every pattern does.
- **Embeddable.** The machine is a library with no global state, so a V program can drive it — including as a `veb` request handler.
- **Erased, not absent, types.** Annotations carry intent for `blip check` and vanish before running; nothing is proven, but real mismatches are named.

## Not yet

Full fiber suspension (parking and resuming continuations) and the WASM backend. Both are tracked in the roadmap with their gates; see [status](status.html).

## Source

The source is at [github.com/metif12/blip](https://github.com/metif12/blip). The tour, the CLI reference, and the embedding guide are the fastest way in.
