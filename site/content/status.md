# Status

`main` moves only when a milestone's gate is met. Each milestone below names what it delivered; the plan lives in `docs/010-roadmap.md`, the record in `CHANGELOG.md`.

## Done

- **M0 — skeleton, value representation, benchmarks.** The representation was decided by experiment: a boxed sum type cannot hold a pair in V, and a `voidptr` payload is not a GC root. Typed payloads it is.
- **M1 — reader.** Lexer and S-expression parser with spans and collected diagnostics. Now 1.3–8x faster with byte-identical output.
- **M2 — values, printer, equality, hashing.**
- **M3 — CEK machine.** The gate: 250k self tail calls, 20k mutual, 100k through `cond`, with the continuation count ending at zero.
- **M4 — special forms, core forms, 100+ primitives.**
- **M5 — macros.** `defmacro`, `gensym`, quasiquote, `macex1`/`macex`.
- **M6 — modules.** `require`/`provide`, `only-in`, `prefix-in`. (`for-syntax` deferred.)
- **M7 — standard library in blip.** `lib/std.lip`, growing.
- **M8 — ergonomics.** `match`, `match*`, `use`, pipes, labelled args, `Result`, opaque types. Gate program: `programs/json.lip`, macro-free.
- **M9 — tooling.** REPL with golden tests, span-carrying errors, formatter. (`assert` as doc-tests not implemented.)
- **M10 — contracts and erased annotations.** `define/contract` checks at call time, `(x Type)` erases, `blip check` reports mismatches without running. Gate: `tests/contracts.v`.

## Verified numbers

A stack depth of zero at the end of a quarter-million tail calls is the whole point: the frame in tail position is reused rather than pushed.

```
ok   self tail call 250k => 250000   (steps=7000020, kont=0)
ok   mutual tail call 2e4 => pong   (steps=400020,  kont=0)
ok   tail in cond 1e5 => 100000     (steps=2900021,  kont=0)
ok   non-tail fib => 6765           (steps=503488,   kont=0)
```

Twenty-two suites run in CI with zero `FAIL` lines, plus the reader probe over every example, the prelude, and both proof programs — and a C smoke test over the embedding library.

## Next

- **Full fiber suspension**: parking and resuming continuations. `yield` exists as an identity hook; the heap stack is already shaped for it.
- **WASM backend**: running blip programs in the browser without a server.
- **`for-syntax`** imports, and **`assert` as doc-tests**.
- A growing prelude: every new `lib/std.lip` name is ordinary blip, or the feature is missing.

---

Start with [getting started](getting-started.html), learn the language in the [tour](tour.html), or try it live in the [playground](playground.html).
