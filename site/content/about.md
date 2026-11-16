# About blip

blip is a Lisp dialect implemented in V. Evaluation is a CEK machine whose stack is an ordinary heap array, which is what makes tail calls structural: a tail call is a loop iteration, not a stack mutation.

## Design points

- **Errors are values.** A failure is an `(err ...)` value the program can match on, not an exception that unwinds past it.
- **Flat chains.** `use` binds a call's result for the body that follows, so four nested calls read as four flat lines.
- **Atomic matching.** `match*` destructures several values at once; a clause matches only if every pattern does.
- **Embeddable.** The machine is a library with no global state, so a V program can drive it — including as a `veb` request handler.

## Not yet

Full fiber suspension (parking and resuming continuations) and the WASM backend. Both are tracked in the roadmap with their gates.

## Source

The source is at [github.com/metif12/blip](https://github.com/metif12/blip).
