# Macros at emit time — design memo

Status: wired into the emit backend (updated 2026-10-29). `defmacro` forms are
consumed at emit time (registered in an embedded machine, nothing emitted);
`macex`/`macex1` and registered macro calls are expanded through that machine
and re-read, so the emitter only ever sees ordinary forms. `05_pipelines`
now emits and runs end to end (emit-js: 6 run, 0 refused). `do` is handled
as a `begin` alias. Struct field access (`(p.x)`, `(p.y := 99)`) and
mutable struct mutators are emitted. `as->`, `cond->`, `loop`, `dotimes`,
`import`, `quasiquote`/`unquote` remain refused.

## What already exists (machine side)

- `datum_to_value` (`machine/mod.v` 2596) — parsed form → runtime `Value`.
- `assemble` (2625) handles `.quoted`, `.unquote`, `.unquote_splice`, `.list`, `.vector`, `.sym`, `.str`, etc.
- `quasi_to_value` (around 2650+) — evaluates `,x` / `,@xs` inside a quasiquote.
- `expand_macro_value` / `macex1` (3089) — expands one macro call at runtime.
- `is_macro_form` / `is_macro_closure` (3095) — detects `defmacro` closures.
- `quasiquote` / `unquote` / `unquote-splicing` parsed in `reader/mod.v` (tags `.quasi`, `.unquote`, `.unquote_splice`).

So the machine can expand macros and build quoted data.

## What's missing (the blocker for emit-js `defmacro` / `macex`)

To emit a macro at compile time, the emitter needs to:

1. **Take a runtime `Value`** produced by `macex1` / macro expansion.
2. **Convert it back to an AST (`reader.NodeId`)** so the emitter can render it as JS.

No such conversion exists. `datum_to_value` is one-way (node → value). The emitter has `data()` (node → JS string) and `quoted()` / `quasi()` (node → JS data), but nothing that takes a `blip.Value` (especially a list/symbol/closure) and produces the equivalent `NodeId`.

The `emit/mod.v` machinery I added in the previous session (`.quasi`, `.unquote`, `.unquote_splice` cases in `data()`, `quasi_depth` tracking, and the `unsupported_forms` removal) only handles the *quoted-form* side — rendering `(quote ...)` and `(quasiquote ...)` into JS data expressions. It does NOT handle macro expansion.

## Why this is hard

- `blip.Value` is an opaque tagged union (`pair`, `vector`, `table`, `closure`, `integer`, `string`, `symbol`, ...). A list value stores `car`/`cdr` as `Value`, not `NodeId`.
- The emitter needs `NodeId` so it can traverse kids, render quoted sub-forms, and apply `e.value()` / `e.data()` recursively.
- A `closure` value (macro definition) carries an environment and compiled body — not reproducible from its value alone without embedding a miniature machine.

## Design options (pick one at implementation time)

### Option 1: embedded machine at emit time (recommended)

Embed `machine.new_standalone()` inside the emitter. When `defmacro` is encountered at emit time:
- Load the macro definition's environment (or a minimal one with prims and std).
- Evaluate the macro call with `macex1` → get expanded `Value`.
- Then convert the expanded `Value` back to AST (see below).

This mirrors how some Lisp emitters work (compile-time macro expansion via embedded interpreter).

### Option 2: value → AST conversion (requires new module)

Add `vlib/blip/value_to_datum.v` implementing a reverse of `datum_to_value`:
`fn (mut m Machine) value_to_datum(v blip.Value, arena *Arena) blip.NodeId`

Challenges:
- Must reconstruct `NodeId` for lists (`pair` → `.list` with kids), vectors, symbols (name → `.sym`), strings (`.str`), keywords (`.kw`), booleans/nil/ints/floats.
- Must handle closures — either reject (macro bodies stay in machine) or embed a reference.
- Must handle cyclic structures (possible via `pair` recurrence).

This is cleaner for pure data, but macro bodies contain closures; Option 1 is more complete.

### Option 3: delay to runtime (current implicit behavior)

Keep `defmacro` / `macex` in `unsupported_forms`. At emit time they become `null` or raise. The machine handles them correctly at runtime. This is safe and matches the current emit-js state (only `05_pipelines` refused).

## What the `05_pipelines` refusal actually means

In `emit/mod.v`, `unsupported_forms` includes `'defmacro', 'macex', 'macex1'` (after the previous session's cleanup). The emit-js backend catches the refusal, prints `refused by name: 1 -> 05_pipelines: defmacro, macex1, macex`, and skips the file. All 20 emit-js checks pass; only the pipeline example is missing.

This is acceptable for a configuration language — macros are nice-to-have, not required for `blip lint` / file I/O / module loading.

## Recommended next step (if continuing)

1. ~~Write `value_to_datum` (Option 2) for pure data shapes~~ **Done
   (2026-10-27).** `vlib/blip/value_to_datum.v` converts the eleven pure
   shapes (nil, boolean, integer, float, string, symbol, keyword, emptylist,
   pair, vector, and pair chains) and deliberately refuses the complex ones
   (table, closure, primitive, ...) with an error, not a panic. Gates:
   `tests/macros_gate.v` (13 checks, all green) and `tests/value_to_datum.v`.
2. ~~If it passes unit tests, try Option 1 (embedded machine + conversion) for
   full macro expansion~~ **Built and gated, not wired (2026-10-27).**
   `vlib/blip/emit/macro_embed.v` exposes `expand_macro_at_embed`, which runs
   a fresh `machine.new_standalone` over the source, evaluates it, and
   round-trips the expanded `Value` through `value_to_datum`. Exercised
   end-to-end by `tests/macros_gate.v`.
3. **Done (2026-10-29)**: wired into `emit/mod.v` statement dispatch AND
   `application()` expression position, with `05_pipelines` added to the
   `emit_js` real-programs gate (6 run, 0 refused). Complex shapes
   (table/closure/primitive) still refuse in `value_to_datum`; `macex`
   over them errors at compile time rather than emitting nothing.

Two failure modes this gate protects against, both real: emitting a macro as
a plain JS identifier (acceptance with no output), and `value_to_datum`
panicking on a closure it cannot express (the machine's recoverable-panic net
turns it into an error, which is what "complex refuses" asserts).

Until then: `05_pipelines` stays refused, and emit-js remains fully working for all other examples.
