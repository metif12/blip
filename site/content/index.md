# blip

A Lisp dialect implemented in V: a CEK-style machine with an explicit heap stack, real tail calls, and errors as values.

```
(define (fib n)
  (if (< n 2)
    n
    (+ (fib (- n 1))
       (fib (- n 2)))))

(fib 20)          ;=> 6765
```

## What works today

- Real tail calls, including mutual recursion
- `match` and multi-subject `match*`, `cond`, `case`
- Macros (`defmacro`, `macex`), structs, modules
- Errors as values, `use` for flat call chains
- A JavaScript backend (`blip build`, `blip emit-js`)
- Tooling: `run`, `test`, `fmt`, `vet`, `doc`, `lsp`, `new`, `pkg`

## Status

Early and honest about what does not work yet: full fiber suspension and the WASM backend are still open. See the [roadmap](https://github.com/metif12/blip/blob/main/docs/010-roadmap.md) for what each phase gates on.

## Source

The source is at [github.com/metif12/blip](https://github.com/metif12/blip).
