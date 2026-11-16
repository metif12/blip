# blip v2 roadmap (record, not schedule)

Status: agreed. v1 gate is green (`match*` fixed 2026-11-16,
`blip check` understands `def`). This file records what v2 contains,
in which order, and under which gate. Nothing here changes behavior until
it lands behind a version bump with a migration note.

Policy shift for v2 (agreed): keeping users of other dialects happy is
no longer a goal. Removals are allowed. For each removal the docs give
a 3-line alias recipe the user can paste into their own file; the core
does not carry the alias. Direction is a small but powerful language:
a minimal core plus a strong std, not a union of every dialect's
spellings.

Source of the deferred v1 items: `docs/010-roadmap.md` §10 items 1–4.
Source of the old one-spelling rule: `docs/canonical-forms.md`
(superseded by the removal table below for v2).
Source of the borrowings: `docs/000-blip-design.md` Appendix C.

## Versioning rule

- Patch: no documented behavior or accepted output changes.
- Minor: additive (new prim, new std name, new tool flag), old programs pass.
- Major (v2): any change to documented behavior or accepted output,
  batched with a migration note. The breaking batch below lands together,
  not one transcript break per release.

## Track A — breaking batch (v2.0, together)

Two halves: behavior fixes carried from `010-roadmap.md` §10, plus
removals and core-shrinking agreed for the small-language direction.
Both land in one v2.0 with one migration note, not one transcript break
per release.

### A1. Behavior fixes (carried, unchanged in meaning)

1. **Table key order** (`examples/07_config.blip`). Printer sorts keys,
   example expects insertion order. Decision for v2: insertion order
   (Janet behavior), plus an explicit `sort-table`. Printer AND emitter
   move together. Gate: `blip test` green on all examples with no comment
   edits.
2. **Verbatim `print` plus `println`** (§10.3, implemented once then
   reverted). `print` becomes verbatim (no trailing newline), `println`
   is the old `print`, `display` is bare plus no newline (Scheme
   spelling). Migration: every line-ending `print` becomes `println`;
   `blip test` comparisons catch the rest. Gate: `tests/embedding.v`,
   `tests/emit_js.v` (both engines agree), `programs_run` hello-world,
   re-blessed goldens.
3. **Nested `;=>`** (§10.2, opt-in first). `blip test` checks only
   top-level forms today. Changing it turns decorative nested comments
   (e.g. `04_errors.blip`) into failures. Gate: a nested-vs-top-level
   fixture pinning the rule, then an opt-in flag before any default flip.
4. **Toolchain sync** (§10.4, §7.1). The pinned-compiler procedure is
   history; the stock-release workflow (`install.sh`/`install.ps1`)
   needs its own procedure, plus the two stale notes in
   `site/content/getting-started.md` and the CI comment.

### A2. Removals (agreed: dialect-pleasing spellings go)

Each removal deletes the compatibility spelling from the core. The docs
give a 3-line alias recipe instead (user pastes it into their own file
if they want the old spelling back). Error messages name the canonical
spelling only.

| Removed | Canonical | Alias recipe location |
|---|---|---|
| `lambda`, `λ` | `fn` | tour appendix "from Racket/Scheme?" |
| `define` | `def` | tour appendix "from Racket/Scheme?" (`define/contract` kept for now; becomes `def/contract` later, `defc` rejected: contract must read as definition) — **done**: machine errors, `check` reports, emitter refuses, struct codegen emits `def`, corpus+tests+tour use `def`, `tail_calls`/`contracts`/`emit_js` pin the removal (prim alias recipes verified working; special forms cannot be aliased back) |
| `first` / `rest` | `car` / `cdr` | same appendix |
| `.lip` / `.vl` loader | `.blip` only | loader errors with a migration line instead of a warning — **done**: `Machine.load` refuses `.lip`/`.vl` naming `.blip`, `resolve_module` entry is `blip.blip`, corpus renamed (18 files), `blip migrate` renames alongside rewriting (conflict errors instead of overwriting), `embedding.v` pins both refusals, `unit.v` pins the rename |
| `do` | `begin` | same appendix (macro expansions emit `begin`) — **done**: machine errors, `check` reports, emitter refuses, `05_pipelines`/tour/`blip_in_y_min` emit `begin` |
| `when` (bare) | `#:when` | guard appendix |
| `case` | `match` with literals | `cond` stays (condition chains read better than `match #t`); `case` goes because literal-`match` does the same job with destructuring |

Decided against removing (different semantics, not spellings):
`print`/`display`, `->`/`->>`/`|>` (different plumbing), `=`/`eq?`,
`cond`/`match`. Quiet singletons (`last`) stay as is.

### A3. Core shrink (small but powerful)

Standing special forms shrink toward:
`def` / `fn` / `if` / `match` / `match*` / `use` / `try` /
`begin` / `quote` / `let-assert` / `import` / `defmacro`.
Candidates moved to std-as-macros or dropped: `cond` stays in core
(readability), `case`/`loop`/`dotimes`/`as->`/`cond->`/`struct-out`/
`provide` (folded into the modules-as-data design below) leave the core.
New sugar is admitted only with an example that is ugly without it.
Gate: every removed form has either a std-macro replacement or an alias
recipe, and the full gate stays green without the form.

## Track B — where blip becomes the reference (all agreed)

Not one per release anymore: all five land in v2, each behind a flag
until its gate is green. The first three are the fronts where the
current combination (`match*` + `use` + `Result`, V host + JS parity,
deterministic tooling) is already unique; fibers and PEG complete it.

1. **Embedded scripting in V with identical JS output.** No Steel /
   Janet / Racket combination has this: V host (`Host` interface,
   `max_steps`/`max_kont` sandbox) + `blip run` + `emit-js` node-parity.
   v2 products it: stable `blip build -o .js`, one real V→blip→JS
   example, sandbox fixture. Gate: same program prints the same bytes
   on the machine and under node.
2. **Error pipelines: `Result` + `use` + `match*` + `let assert`.**
   Gleam has `use` without `match*`; Racket has `match*` without the
   `Result` convention. Together they make flat fallible pipelines
   (`05_pipelines`) without nesting. Missing piece is std: move
   `map-result`/`unwrap-or`/`flatten`/`all-results`/`lazy_*` from the
   tour into `lib/std.blip`. Gate: pipeline example with asserts on
   every branch (ok path, err path, miss-falls-through).
3. **Deterministic tooling that agrees with itself.**
   `check`/`fmt`/`test`/`doc`/`lsp` share one reader position source;
   `lsp` diagnostics equal `blip run` diagnostics. `check` gains
   `match*` arity plus light exhaustiveness (warning by default, error
   under `#:strict`). Gate: `contracts.v` + `lsp` additions, `emit_js`
   both-engines-agree.
4. **Fibers.** Janet has them now; Gleam has processes, Racket threads.
   blip sits on a CEK machine with a heap stack, so cheap fibers are the
   natural step, not OS threads. Pairs with `use` + `Result`. Gate:
   a bounded-step fiber fixture plus `examples_run` green.
5. **PEGs as data.** Janet is PEG-only; Racket is regex+PEG. Proposal:
   PEG as a data structure (Janet shape), since `match` covers structure
   and PEG covers text. Gate: a grammar fixture independent of `match`.
6. **Exhaustiveness for `match`.** Gleam has it; no Lisp in the table
   does. Follows from the current `check` (which already reads `def`).
   Default warning, error under `#:strict` (open question in
   `000-blip-design.md`). Gate: `tests/contracts.v` additions.
4. **Minimal numeric tower.** Racket exact, Clojure bigint, Janet
   int/float/rational. Proposal is minimal: `int`/`i64` + `rational` +
   `float` with explicit promotion, not a CL tower. Gate: promotion
   table fixture.
5. **Modules as data.** Racket `require`/`provide` with
   `only-in`/`prefix-in`; Janet `module/*` as data. Proposal follows
   Janet (fits the existing `@` tables/prototypes). Gate: a
   `module/paths` fixture.

## Track C — tooling (non-breaking, continuous)

- `blip check`: `match*` arity plus light exhaustiveness.
- `fmt -w`: stable normalization (reader keeps no trivia).
- `doc`: from `;;` comments; site gains API references.
- `lsp`: parity with `blip run` diagnostics (today 26 checks).
- `build`: `emit-js` is done; `.wasm` waits on V wasm32 stdlib
  (`docs/p8-wasm.md`). Until then stabilize `build -o .js`.

## Track D — stdlib expansion (`lib/std.blip`)

Today ~106 lines, mostly mock/demo: `identity`, `err-message`,
`parse-in` (`key: value` only), `lookup-sym`/`validate` (two-member
table for the `match*` example), `connect`/`authenticate`/
`open-transaction`/`execute`/`commit` (hand-built tables),
`array-append!`, `*debug*`. The standing rule stays: no special form
in this file — if the library needs a feature, the feature is missing.

Order (one PR each, each with an example + asserts, never `;=>`-only):

1. `result`: `map-result`/`unwrap-or`/`flatten`/`all-results`/`lazy_*`
   (names already promised by the tour; move them from examples into std).
2. `seq`: `map`/`filter`/`fold`/`keep`/`zip`/`enumerate`/`partition`.
3. `string`: `split`/`trim`/`join`/`starts-with?`/`ends-with?`/`pad`.
4. `table`: `get-in`/`merge`/`select-keys`/`keys`/`vals`.
5. `fs`/`time`/`json`/`csv`: promote logic already inside `programs/`.
6. `test`: `deftest`/`is` in the Racket shape, over the existing `assert`.

Rules:

- Expected failure returns `(err ...)`; impossible failure calls `raise`.
- No hand-written prim for what ordinary blip can express; prims are
  for IO/FFI only.
- `keep` vs `filter` is decided here first (today both keep in every
  tested example; see `canonical-forms.md` open questions): either one
  canonical plus an alias, or separate semantics with a gate pinning both.
- Prelude stays prelude and stays versioned: old programs without
  `require` keep passing.

Gates per std PR: `examples_run` + `programs_run` green, new asserts
(fail-without proof), `emit_js` node-parity where the emitter compiles
the new code.

## Philosophy: one way per idea (v2: small but powerful)

Supersedes `docs/canonical-forms.md` "never removed" rule for v2.
v1 said one advertised spelling plus compat forever; v2 says one
spelling, period — plus an alias recipe in the docs for anyone who
wants the old spelling back in their own file. Enforcement is still
social (examples, tour, new std code use the canonical column), but
the core no longer carries the alias and error messages name the
canonical spelling only.

What looks interchangeable but is not stays separate (unifying would
change programs, not spellings): `print`/`display`, `->`/`->>`/`|>`
(different plumbing), `=`/`eq?`, `cond`/`match`. Removed as pure
spellings: see the A2 table above. Quiet singletons (`last`) stay.

For v2:

- Each idea keeps one canonical entry; new canonicals arrive only with
  a migration note and a major bump. Removals land in the v2.0 batch.
- New sugar is admitted only with an example that is ugly without it.
- `keep`/`filter` is decided as: `filter` canonical, `keep` removed
  (alias recipe), unless a gate proves separate semantics are needed.
  Nested `;=>` stays opt-in before any default flip.

## Order of work (agreed)

1. Track C continuously (no version gate).
2. Track D `result` → `seq` → `string` → `table` (each shippable alone).
3. Track A as one v2.0 batch with one migration note (fixes + removals
   + core shrink together).
4. Track B all five in v2 (embedded V+JS, error pipelines, deterministic
   tooling, fibers, PEG-as-data), each behind a flag until green, plus
   exhaustiveness / numeric tower / modules-as-data to the extent their
   gates clear.

## Open questions (not promises)

- `keep` vs `filter`: alias or separate semantics?
- Exhaustive-`match`: warning by default, error under `#:strict`?
- `(p.x := 5)` field syntax: macro or core?
- `Value` width (`int` vs `i64`) on 32-bit targets and tower promotion.
- `Program` IR peak memory with per-stage arenas (unmeasured).
