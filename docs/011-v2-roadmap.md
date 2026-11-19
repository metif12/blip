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
   edits — **done**: `Table` carries insertion `order` (literals, datum,
   `put`/`remove`/`put!`/`dissoc!` maintain it; updates keep position),
   `keys()`/printer/`table_keys`/node printer follow it, `=` stays
   order-insensitive on both engines (backend gained table equality),
   `sort-table` is ordinary std over `sort`. One exception to "no comment
   edits": `02_data` line 79 pinned sorted `vals` (`(1 2)`), which the v2
   direction changes to insertion (`(2 1)`), plus a `sort-table` line.
   Pins: `unit` (order, update/remove/sort/equality/source-location),
   `emit_js` (literal order + equality parity, `02_data`/`08_test`
   transcripts), `blip test` 155 expectations green.
2. **Verbatim `print` plus `println`** (§10.3, implemented once then
   reverted). `print` becomes verbatim (no trailing newline), `println`
   is the old `print`, `display` is bare plus no newline (Scheme
   spelling). Migration: every line-ending `print` becomes `println`;
   `blip test` comparisons catch the rest. Gate: `tests/embedding.v`,
   `tests/emit_js.v` (both engines agree), `programs_run` hello-world,
   re-blessed goldens — **done**: machine routes `print`/`display`
   through `host_write` and `println` through `host_print` (`m.out` one
   fragment per call either way); emitter prelude splits the same way and
   gains `display`/`println`; corpus migrated (15 files); `blip test`
   comparisons unchanged (fragments join); pins in `embedding` (transcript
   vs lines), `emit_js` (verbatim/println/bare parity), `repl_golden`
   (golden input uses `println`, fixture byte-identical).
3. **Nested `;=>`** (§10.2, opt-in first). `blip test` checks only
   top-level forms today. Changing it turns decorative nested comments
   (e.g. `04_errors.blip`) into failures. Gate: a nested-vs-top-level
   fixture pinning the rule, then an opt-in flag before any default flip —
   **done**: `tests/nested_ignored.blip` (wrong nested arrows, green by
   default) + `tests/nested_checked.blip` (true nested arrows, green under
   `--nested`), pins in `repl_golden` (exit codes both modes); `--nested`
   walks the pristine pre-eval tree (post-eval rewrites carry no lines;
   shared subtrees guarded by a seen-set; quoted data skipped, same-line
   forms share the outer arrow), pairing nested prints with fragments in
   order (dual reading: fragment or answered value) and failing any other
   nested arrow loudly. Corpus fallout under `--nested` is exactly one
   line: `05_pipelines.blip:88`, a `match*` clause — the blocker list the
   gate asked for, and why the default stays put.
4. **Toolchain sync** (§10.4, §7.1). The pinned-compiler procedure is
   history; the stock-release workflow (`install.sh`/`install.ps1`)
   needs its own procedure, plus the two stale notes in
   `site/content/getting-started.md` and the CI comment — **done**:
   verified current, not rewritten. `getting-started.md`, `ci.yml`,
   both install scripts, `docker/*`, and `CONTRIBUTING.md` all name
   stock V 0.5.2 from the release archive (unpin landed in `38ac7af`;
   `unit.v` pins no `V_COMMIT`/clone in the install scripts and
   `V_VERSION` in every Dockerfile); §7.1 was already the
   stock-release procedure, repaired where it had rotted
   (`examples\*.lip` → `*.blip`, "both workflows" → every workflow).

### A2. Removals (agreed: dialect-pleasing spellings go)

Each removal deletes the compatibility spelling from the core. The docs
give a 3-line alias recipe instead (user pastes it into their own file
if they want the old spelling back). Error messages name the canonical
spelling only.

| Removed | Canonical | Alias recipe location |
|---|---|---|
| `lambda`, `λ` | `fn` | tour appendix "from Racket/Scheme?" — **done**: machine errors, `check` reports, emitter refuses, pins in `tail_calls` (both spellings), `contracts`, `emit_js` |
| `define` | `def` | tour appendix "from Racket/Scheme?" (`define/contract` kept for now; becomes `def/contract` later, `defc` rejected: contract must read as definition) — **done**: machine errors, `check` reports, emitter refuses, struct codegen emits `def`, corpus+tests+tour use `def`, `tail_calls`/`contracts`/`emit_js` pin the removal (prim alias recipes verified working; special forms cannot be aliased back) |
| `first` / `rest` | `car` / `cdr` | same appendix — **done**: prims error, `check` reports, emitter refuses by name, pins in `tail_calls`/`contracts`/`emit_js` |
| `.lip` / `.vl` loader | `.blip` only | loader errors with a migration line instead of a warning — **done**: `Machine.load` refuses `.lip`/`.vl` naming `.blip`, `resolve_module` entry is `blip.blip`, corpus renamed (18 files), `blip migrate` renames alongside rewriting (conflict errors instead of overwriting), `embedding.v` pins both refusals, `unit.v` pins the rename |
| `do` | `begin` | same appendix (macro expansions emit `begin`) — **done**: machine errors, `check` reports, emitter refuses, `05_pipelines`/tour/`blip_in_y_min` emit `begin`, pins in `tail_calls`/`contracts`/`emit_js` |
| `when` (bare) | `#:when` | guard appendix — **done**: machine errors, `check` reports, emitter refuses, pins in `tail_calls`/`contracts`/`emit_js` |
| `case` | `match` with literals | `cond` stays (condition chains read better than `match #t`); `case` goes because literal-`match` does the same job with destructuring — **done**: machine errors, `check` reports, emitter refuses, pins in `tail_calls`/`contracts`/`emit_js` |

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

**Blocked (2026-11-19, probe-verified, not assumed):** a `defmacro`
called under `run` never expands — the machine evaluates the arguments
(a `(println ...)` body runs) and applies the macro body as a plain
function, discarding the expansion (probe: `(defmacro my-when (test
body) (list 'quote 'macro-ran))` + `(my-when #t (println "expanded"))`
prints `"expanded"` instead of answering `macro-ran`; only `macex` and
the emitter pre-pass expand). Control-flow std-macros (`loop`,
`dotimes`, `cond` branches, `as->` steps) would therefore run every
branch eagerly — the same finding that forced D6 into functions
(`unit` pins "test framework uses functions, not macros"). Shrinking
the core this way needs a language-level decision first (auto-expansion
in eval, or a new macro protocol), not std work. `struct-out`/`provide`
move with the modules-as-data design (Track E), independent of macros.

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
   on the machine and under node — **done**: `blip build` writes
   deterministic bytes (same source twice → identical output, pinned);
   the one real V→blip→JS program is the `interp-API parity` check in
   `emit_js` (public `embed.Interp` evals with the embedded prelude,
   `emit.compile` compiles the same source, node runs it, transcripts
   compared); every example is machine-vs-node compared by
   `check_example`; the sandbox is pinned (`embed_api` restrict_to,
   `embedding` per-machine step limits).
2. **Error pipelines: `Result` + `use` + `match*` + `let assert`.**
   Gleam has `use` without `match*`; Racket has `match*` without the
   `Result` convention. Together they make flat fallible pipelines
   (`05_pipelines`) without nesting. Missing piece is std: move
   `map-result`/`unwrap-or`/`flatten`/`all-results`/`lazy_*` from the
   tour into `lib/std.blip`. Gate: pipeline example with asserts on
   every branch (ok path, err path, miss-falls-through) — **done**
   (with D1): the six combinators are ordinary std; `05_pipelines`
   §"result pipelines" asserts ok/err/miss on the machine AND under
   node via `check_example`; `unit` pins the std source-location.
3. **Deterministic tooling that agrees with itself.**
   `check`/`fmt`/`test`/`doc`/`lsp` share one reader position source;
   `lsp` diagnostics equal `blip run` diagnostics. `check` gains
   `match*` arity plus light exhaustiveness (warning by default, error
   under `#:strict`). Gate: `contracts.v` + `lsp` additions, `emit_js`
   both-engines-agree — **done**: `check` reports `match*`
   pattern/subject count mismatches as errors (clauses are vectors --
   the old `.list`-only walk never descended into them, so bodies went
   unchecked too); a `match` without `else`/catch-all warns
   (`warning: ` prefix, exit 0) and `blip check --strict` errors (exit
   1); the LSP runs the same `check_text` (severity 1/2 mapped) so the
   editor and the gate agree. Pins: `contracts` arity/ok/warn/else/
   catch-all/all-symbols/strict, `lsp` severity mapping + else-clean,
   `emit_js` unchanged 45 green (runtime untouched).
4. **Fibers.** Janet has them now; Gleam has processes, Racket threads.
   blip sits on a CEK machine with a heap stack, so cheap fibers are the
   natural step, not OS threads. Pairs with `use` + `Result`. Gate:
   a bounded-step fiber fixture plus `examples_run` green — **done**:
   `spawn`/`resume`/`yield`/`fiber-status`/`fiber-done?` machine
   builtins; fibers are saved CEK control state (kstack + registers),
   `resume` save/swap/drives/harvests with an optional step budget
   (`paused` status, continues on the next resume), errors mark the
   fiber `failed` with the message; `yield` across a V-stack boundary
   (map callback, macro expansion, generated code) is refused loudly
   via a depth guard instead of corrupting, and a budget waits for
   open code the same way. Nested resume works; ids are never reused.
   Machine-only by construction: the emitter refuses all five by name.
   Pins: `fibers` (round-trip, interleave, budget-pause-and-finish,
   five refusals, boundary guard), `emit_js` machine-only refusals,
   tour section with probe-verified claims.
5. **PEGs as data.** Janet is PEG-only; Racket is regex+PEG. Proposal:
   PEG as a data structure (Janet shape), since `match` covers structure
   and PEG covers text. Gate: a grammar fixture independent of `match` —
   **done**: `peg-match`/`peg-parse` plus eleven rule forms
   (`lit`/`any`/`one-of`/`range`/`seq`/`choice`/`star`/`plus`/`opt`/
   `not`/`look`/`cap`/`ref`) as ordinary `lib/std.blip` over wired
   prims (`string-slice` wired through the emitter for it: names,
   prelude with machine-matching clamps, parity pins); failures are
   `(err {:expected … :at pos})` Results with furthest-position choice;
   `programs/peg.blip` parses a sectioned config with asserts on every
   combinator and contains no `match` forms; `unit` pins the std
   source-location; `programs_run` checks the `peg ok` marker.
6. **Exhaustiveness for `match`.** Gleam has it; no Lisp in the table
   does. Follows from the current `check` (which already reads `def`).
   Default warning, error under `#:strict` (open question in
   `000-blip-design.md`). Gate: `tests/contracts.v` additions — **done
   with B3** (same rule, same pins; the design question is closed:
   warning by default, `blip check --strict` errors).
4. **Minimal numeric tower.** Racket exact, Clojure bigint, Janet
   int/float/rational. Proposal is minimal: `int`/`i64` + `rational` +
   `float` with explicit promotion, not a CL tower. Gate: promotion
   table fixture — **done**: rationals are real values now (before: read
   and printed, evaluated to `nil`) — a normalized `RatPayload`
   (denominator positive, pair reduced, `2/4` reads as `1/2`),
   reader/assembler/match-literal/printer/`=` (exact, representation-
   strict: `2` is not `2/1`)/`compare` (exact cross-multiplication with
   a documented range note) support; `+ - * /` exact without floats
   (float contaminates; int/int `/` keeps its exact-or-float rule);
   `inc`/`dec`/`sqrt` (perfect-square rationals stay exact)/`expt`
   (exact for integer exponents) extended; `number?` includes rats,
   new `rational?` wired both engines; node prelude mirrors with
   normalized `[n d]` pairs (`blip_add2` family, exact `blip_cmp`,
   rat-aware `blip_equal`/`sqrt`/`zero?`-family/`min`/`max`, which are
   newly routed); emitter refuses nothing new. Pins: `unit`
   `numeric_tower` (48-row printed promotion table incl. error rows),
   `emit_js` 20 parity rows.
5. **Modules as data.** Racket `require`/`provide` with
   `only-in`/`prefix-in`; Janet `module/*` as data. Proposal follows
   Janet (fits the existing `@` tables/prototypes). Gate: a
   `module/paths` fixture — **done**: `(module-paths)` answers the
   loaded set as an ordinary list of paths, in load order (a machine
   builtin reading `m.loaded`, so `require` twice still records once);
   the emitter notes each inlined require with
   `blip.note_module_loaded` at the require point, so mid-evaluation
   queries agree too; tour documents it. Pins: `unit` (fresh machine
   empty, loaded file named), `emit_js` machine-vs-node transcript
   parity on a requiring snippet.

## Track C — tooling (non-breaking, continuous)

- `blip check`: `match*` arity plus light exhaustiveness — **done** (B3).
- `fmt -w`: stable normalization (reader keeps no trivia) — **done**:
  `pp_form`/`write_datum` render every datum tag back to re-parseable
  source (the `@{...}` buffer shape fell through to `#<datum>`, which
  neither re-parses nor repeats -- `fmt` of any buffer file was not a
  fixed point); `unit` pins buffer round-trips plus a corpus-wide
  fixed-point gate (`fmt_is_stable`: format twice is format once, and
  the normalized text re-parses cleanly, over every `.blip` file).
  Comments are trivia the reader drops, so `fmt -w` strips them; that
  is the documented tradeoff, not a bug.
- `doc`: from `;;` comments; site gains API references — **done**:
  `blip doc`'s signature parser matches nested parens (annotated
  multi-param signatures printed truncated before); `tests/doc_demo.blip`
  covers every shape plus the ignore-rules with a byte-exact golden
  (`tests/golden/doc_demo.md`); `site/content/api.md` is
  `blip doc lib/std.blip` under a fixed header, rendered by
  `site/build.blip`, linked from the nav, listed in the pages gate;
  `repl_golden.v` pins the golden and the api.md freshness (std edit
  without regenerating fails).
- `lsp`: parity with `blip run` diagnostics (today 26 checks) — **done**
  (29 checks; editor and CLI report the same diagnostics).
- `build`: `emit-js` is done; `.wasm` waits on V wasm32 stdlib
  (`docs/p8-wasm.md`). Until then stabilize `build -o .js` — **done**
  (B1: deterministic bytes + interp-API parity).

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
   — **done**: the six combinators are ordinary `lib/std.blip`
   definitions; the machine keeps only construction and observation
   (`ok`, `err`, `ok?`, `err?`, `ok-value`, `err-value`), and the emitter
   prefers program definitions over runtime helpers (with a `remember`
   pre-pass extended to function names), so both engines run the same
   code. Rest parameters compile to `...r` (a bare array reads as a blip
   list); misplaced dots and rest-with-keywords refuse instead of
   miscompiling. Gate: `05_pipelines` result section asserts ok/err/miss
   on both engines, `unit` pins the std source-location, the emitter
   routing, and the rest rules.
2. `seq`: `map`/`filter`/`fold`/`keep`/`zip`/`enumerate`/`partition`.
   — **done** (subset): `zip`, `enumerate` (plus `enumerate-from`),
   and `partition` are ordinary `lib/std.blip` definitions over lists;
   `map`/`filter`/`fold` stay machine builtins (they already serve every
   container polymorphically). `keep` stays OUT: v2 removed it as a
   duplicate of `filter`, and `(def keep filter)` in your own file is the
   alias recipe -- the std will not carry both spellings. Wiring found
   along the way: `drop` was a machine-only prim (the emitter had no
   runtime for it), so it is routed to a `blip.drop` helper like `take`.
   Gate: `05_pipelines` seq section with asserts on every branch on both
   engines, `unit` pins the std source locations, the `drop` routing,
   and `keep` staying unbound.
3. `string`: `split`/`trim`/`join`/`starts-with?`/`ends-with?`/`pad`.
   — **done**: `string-split`/`trim` were already wired; `join`,
   `string-repeat`, `string-start-with?` and the new
   `string-ends-with?` prim are wired through the emitter now (they
   emitted calls to undefined names before, the same gap `drop` had);
   `pad`/`pad-left` are ordinary std over them. Gate: `02_data`
   asserts (single-line `;=>` plus `assert` where whitespace defeats
   `;=>` chunking) on both engines, `unit` pins the std source
   locations, the emitter routing, and the answers.
4. `table`: `get-in`/`merge`/`select-keys`/`keys`/`vals`.
   — **done**: `get-in` (nil on a miss or a wrong turn), variadic
   `merge` over a binary worker (later keys win), `select-keys` (absent
   keys skipped), and `vals` (key order, like the printer) are ordinary
   std; `keys` stays the `table-keys` prim it always was. Vector paths
   and key sets work through one `as-list` normalization. Gate: new
   `02_data` asserts on both engines, `unit` pins the std source
   locations plus `get-in`/`merge`/`select-keys` behavior.
5. `fs`/`time`/`json`/`csv`: promote logic already inside `programs/`.
   — **done**: `csv->table` and friends, `parse-line`/`read-config`/
   `tmp-dir`, and the whole JSON parser/emitter moved into std;
   `programs/csv_to_table.blip`, `config.blip`, and `json.blip` keep
   only their demos and self-tests, which run unchanged against the
   moved code (the fail-without proof: deleting a std def breaks its
   program). `now` (unix seconds, core like the other small builtins)
   covers `time`. Along the way: `drop`, `string-join`,
   `string-repeat`, `string-start/end-with?`, and `now` are wired
   through the emitter (they were machine-only prims emitting calls
   to undefined names); `row->table` forced `->` mangling plus
   collision refusals instead of silent merges. Gate: programs green
   on std, `unit` pins the std source locations, `emit_js`
   node-parity, and the new emitter routing.
   — **done**: csv (`split-line`, `trim-cell`, `csv-rows`, `header-row`,
   `row->table`, `csv->table`), fs/config (`parse-line`, `read-config`,
   `tmp-dir`), the whole json parser+emitter (`json-parse`, `json-emit`
   and friends), and `elapsed` over the new `now` prim (unix seconds,
   core like the other small builtins) now live in `lib/std.blip`;
   `programs/csv_to_table.blip`, `config.blip`, and `json.blip` keep
   only their demos and self-tests, which run unchanged against the
   moved code. Gate: programs run green on the std definitions (the
   fail-without proof: deleting a std def breaks its program), `unit`
   pins the std source locations, `now` answers an integer, and the
   emitter routes it.
6. `test`: `deftest`/`is` in the Racket shape, over the existing `assert`.
   — **done**, with the shape changed by evidence: FUNCTIONS, not macros.
   The machine never auto-expands a bare macro call (only `macex` and the
   emitter pre-pass expand), so a `defmacro` `is` would evaluate its
   argument and return the expansion as a value -- a test that cannot fail
   -- and a `defmacro` `deftest` dies with `unbound identifier` under `run`.
   Hence `(deftest 'name (fn [] ...))` (quoted name, explicit thunk) and
   `(is test msg)` with an explicit message defaulting to a generic one.
   `is` raises through `error` rather than wrapping `assert`, because
   `assert` renders its message from source and a wrapper would report the
   wrapper's parameter name. `run-tests` answers the count; a failure raises
   past it. `examples/08_test.blip` demos it with `;=>` expectations.
   Along the way: symbol table keys are unwrapped in the emitter's `keyof`
   (every symbol key collapsed to `"[object Object]"`), and call arguments
   are `tramp`-driven (an `if` with calls in its branches reached the callee
   as a thunk object). Gate: `unit` pins std locations, the no-macros rule,
   counts, messages, and emitter acceptance; `emit_js` runs 08 plus both
   parity snippets on node.

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

## Track E — embedder surface (agreed)

Track B1 covers *running* blip embedded. This track covers *seeing into
and reshaping* it: reading the AST and inner data, switching features off,
and composing the implementation from modules. All three share one
`blip.mod` manifest format, specced once (below) and implemented separately.

### The manifest (specced once, E2/G1/G5 share it)

`blip.mod` is blip data, parsed with the ordinary reader. v1 stanzas:

```blip
(module myapp)              ; required: the module name
(blip 2)                    ; required: the manifest/toolchain version
(features (fibers #f))      ; optional: capability switches, default on
(deps (owner/repo "1.2.3")) ; optional: version requirements (G1)
(tools (greet "tool.blip")) ; optional: runnable tools for install (G3)
(workspace (members a b))   ; optional: local members (G5)
```

Rules: unknown stanzas are errors (a manifest must be exact; typos must
fail, not silently pass; the known set is module, blip, features, deps,
tools, workspace). `features` names are validated when the
capability exists (E2); version strings are validated on resolution (G1).
`blip.manifest` parses and validates; nothing evaluates the manifest.

### E1. AST and inner data are readable and rewritable by embedders

The pieces exist (`reader.read_all` + arenas, `value_to_datum`, the
span-anchored rewrites in `blip.migrate`) but there is no declared API
boundary: embedders reach into internals that A3 core-shrink may move.
E1 declares it — what is stable `pub` vs internal — and freezes the
reader/arena/datum surface. v2 scope is pre-eval read/rewrite (parse,
inspect, rewrite, evaluate); live machine-state mutation (envs,
continuations) is a follow-up, not a promise. Gate: a fixture that uses
only the public API to parse, inspect, and rewrite a form before
evaluation, plus an `api_coverage` rule that fails when a new `pub`
item has no stability note. — **done**: every one of the 287 `pub fn`
items carries a `stability:` note (`stable` = frozen v2 promise,
`internal` = may move); the frozen surface is the reader/arena/datum
modules, value constructors and readers, `new_machine`/`run_str`/`run`/
`eval_one`/`check_text`/`datum_to_value`, the host interface and capture
host, the manifest parser, and the whole `embed` facade. Gate pins:
`api_coverage` fails any `pub fn` without a note (negative-controlled),
`unit` `public_api_boundary` parses, inspects, rewrites (`40` → `41`
through the arena reference), and evaluates (`43`) through stable calls
only, plus pins each used marker; `site/content/embedding.md`
documents the contract.

### E2. Features configurable via `blip.mod`

`restrict_to` already lets embedders drop prim groups; E2 extends that
mechanism to named capabilities instead of inventing a second one. v2
scope is the mechanism plus two switches (fibers once B4 lands, and
FS/network prims); the full switch list grows with the capabilities.
Using a disabled feature is a clean error, and `blip check`
understands the manifest. Precedence: manifest < embedder code (an
embedder's explicit `restrict_to` wins over the file). Gate: a fixture
manifest with a capability off, asserting the clean error on use and a
`check` diagnostic naming the manifest line. — **done**: `apply_manifest`
removes the gated prims (use fails as `unbound identifier`);
`prim_capability` lets `check` report `read-file is disabled by
blip.mod:<line> (feature 'fs' is off)`; the CLI auto-applies `./blip.mod`
in `run`/`test`/`check` (after the prelude loads) and warns in `repl`.
Pins: `contracts.v` manifest check cases, `hostile.v` CLI auto-apply
from a project dir, `embedding.v` runtime refusals.

### E3. Modular core

Concrete definition or it is un-gateable: prim groups registered per
module behind the existing `Host`-style seams, so a minimal core (no
IO/FFI) builds and passes a subset gate. No new plugin ABI in v2; the
gate is the subset run, not a diagram. — **done**: `prims.core_table`
plus `register_fs`/`register_env` (with `fs_prim_names`/`env_prim_names`)
is the single source of group membership; `table()` is core plus both.
`machine.capabilities`/`capability_prims` is the registry `apply_manifest`
and embedders share; `new_standalone_core` starts without IO,
`enable_fs`/`enable_env` re-add a capability (manifest < code preserved).
`embed.Config` carries `fs`/`env` (default on) and `apply_manifest` is
reachable through the facade. The hot path (`call_primitive` fast path)
does one fewer hash probe per prim call (ctx-miss + prims-hit, instead
of `!in` + `in` + index). Gate: `unit.modular_core` (core lacks fs/env,
table has them, core runs arithmetic and refuses IO, enable restores) +
`embed_api` no-io config and facade `apply_manifest`.

## Track F — release packaging (agreed, incremental)

`release.yml` today ships a linux tarball, a windows zip, the site, and
the C-library dist. v2 adds formats one at a time, each gated the same
way: CI produces the artifact AND a smoke step runs it (`blip version`
minimum, plus the `clib_smoke` marker where a library ships). v2
must-haves are the current set plus DEB, MSI, and RPM; Snap, Flatpak,
AppImage, DMG, and the rest follow as their gates clear, each in its
own change. Signing/notarization (DMG, MSI) is called out now because
it is the known blocker, not because v2 promises it.

- DEB — **done**: `packaging/deb/` holds the control template, the
  MIT copyright (Format 1.0), and a `build.sh` that lays out
  `/usr/bin/blip` + `/usr/share/blip/{lib,programs}` + docs and runs
  `dpkg-deb`; `main.v resource_path` gains a Linux-only
  `/usr/share/blip` candidate (a tree next to the binary still wins,
  so development never reads installed files); CI builds the package
  from the tag version (dry runs use `0.0.0-dryrun`), installs it with
  `dpkg -i`, and smokes version + run + `blip test`, then publishes the
  `.deb` with checksums. Verified end to end in WSL Ubuntu 24.04 with
  the pinned stock toolchain: build, `dpkg-deb --build`, install,
  smoke (version, run, and `blip test` of an example against the
   installed prelude), uninstall.
- MSI — **done**: `packaging/msi/blip.wxs` (WiX v4, fixed UpgradeCode,
   stable component GUIDs, per-machine install to Program Files with
   PATH registration, no UI, unsigned per the known blocker); CI
   installs with `msiexec /qn`, smokes version/run/test plus
   PATH-registration and clean uninstall, and publishes with
   checksums. Verified locally: `wix build`, MSI table inspection,
   admin-install extraction, and binary smoke from the extracted tree.
 - RPM — **done**: `packaging/rpm/` (spec template, `AutoReqProv: no` —
   the binary is self-contained C and rpm auto-deps name deb-provided
   libraries the rpm database cannot resolve — plus a `build.sh`
   staging the same tree as the .deb); CI builds from the tag version,
   installs with `rpm -i`, smokes version/run/`blip test`/uninstall,
   and publishes with checksums. Verified end to end in WSL Ubuntu
   with the pinned stock toolchain (stock-release `blip` binary
   rebuilt there, not the Windows one).

## Track G — packages, tools, workspaces (agreed, registry later)

Grows the `blip pkg` seed (`install`/`list`/`remove` + `blip.lock` +
`blip_modules/`) into real package and tool management. Git-addressed
packages suffice for v2; a central registry/index is a follow-up.

1. **G1 version resolution.** `blip.mod` declares requirements, `pkg
   update` resolves and re-pins `blip.lock` deterministically. Gate: a
   fixture with two conflicting requirements resolving to one pin. —
   **done**: `pkg.update` resolves the root plus workspace universe to
   max satisfying tags (`=`, `>=`, literal), rewrites the lock sorted;
   `tests/pkg_cli.v` pins three requesters (`>=1.0.0`, `=1.2.0`,
   `>=1.1.0`) resolving to one `v1.2.0` pin with byte-identical locks
   across runs.
2. **G2 verified installs.** Checksums in the lockfile, verified on
   install; a tampered package fails loudly. Gate: a tampered-package
   fixture failing install with a checksum error. — **done**: sha256
   tree checksum recorded at install, re-checked by `pkg verify` and by
   reinstalling an installed package; `tests/pkg_cli.v` pins both
   failing on a tampered file.
3. **G3 tool installs.** `blip install <package>` puts a runnable on
   PATH (today `pkg` only yields importable libraries). Gate: install a
   fixture tool, run it from PATH in CI. — **done**: `pkg.install_tool`
   links each declared tool (or a root `tool.blip` default) into
   `.blip/bin/` as POSIX + batch wrappers around `blip run`;
   `tests/project.v` installs a fixture package and runs its tool from
   a PATH containing only the bin dir (plus the blip home).
4. **G4 toolchain self-management.** blip installs and manages itself:
   version switching and virtualenv-style isolation via `blip pkg`
   (per-project pins, shims resolving to the pinned version). Needs a
   layout decision (where versions live, how shims resolve); can start
   against the current release layout and grow with Track F. Gate: two
   blip versions side by side, per-project pin, `blip version`
   reporting the right one in each directory. — **done**: versions in
   `<home>/versions/<version>/` (`$BLIP_HOME` or `~/.blip`),
   `toolchain install` unpacks the release artifact (or `$BLIP_RELEASE_BASE`
   for fixtures/mirrors) plus a lib/programs snapshot, `use` writes the
   upward-searched `.blip-version` pin, `default`/`list`/`shim`/`remove`
   round it out with `$BLIP_VERSION` overriding everything;
   `tests/project.v` pins two versions side by side with each `blip version`
   reporting its directory's pin (including subdirs), env-over-pin, and remove.
5. **G5 monorepo / workspace / collaboration.** Multi-package repos with
   one lockfile (`workspace` stanza), path overrides for local
   development, reproducible clean-room `pkg install` for teammates.
   Gate: a fixture workspace (two local members + one remote pin)
   reproducing from scratch. — **done**: `collect_universe` folds
   member manifests (requester-relative `path:` overrides) into one
   sorted lock; `pkg install` (no args) reproduces from the lock with
   exact-sha checkouts; `tests/pkg_cli.v` pins a two-member workspace
   plus path dep reproducing an identical lock and running in a
   clean room.
6. **G6 project lifecycle.** Review/extend `blip new`, add `blip init`
   for scaffolding inside an existing directory. Gate: both produce a
   project whose `run`/`test` pass immediately. — **done**: `new`
   writes `main.blip` + `README.md` + `.gitignore` + `blip.mod` and
   refuses existing dirs; `init [name]` tops up the current dir without
   clobbering and defaults the module to the directory name;
   `tests/project.v` pins both producing projects whose `run` passes
   and `test` reports expectations passed.
7. **G7 introspection.** `blip env` (go-style: paths, versions,
   toolchain, active workspace) and `blip pkg why <package>` (who
   depends on it). Gate: golden-output fixtures. — **done**: `env`
   prints stable-order `key value` facts without evaluating anything;
   `pkg why` shows the locked pin plus every requester and req;
   `tests/pkg_cli.v` pins both against exact goldens.

Deliberately out of v2: a `scripts` stanza (`.blip` files already run;
it would duplicate them).

## Order of work (agreed)

1. Track C continuously (no version gate).
2. Track D `result` → `seq` → `string` → `table` (each shippable alone).
3. Track A as one v2.0 batch with one migration note (fixes + removals
   + core shrink together).
4. Track B all five in v2 (embedded V+JS, error pipelines, deterministic
   tooling, fibers, PEG-as-data), each behind a flag until green, plus
   exhaustiveness / numeric tower / modules-as-data to the extent their
   gates clear.
5. Track E boundary first (E1 public-API line, then the shared manifest
   spec), because A3, E2, G1, and G5 all touch or depend on it; then E2
   mechanism + G1/G2/G5 (collaboration core); G3/G6/G7 are small and
   independent in any order; E3 subset gate when the seams exist.
6. Track G4 once Track F artifacts are mature enough to install from
   (starts against the current release layout).
7. Track F formats incrementally throughout, DEB and MSI first.

## Open questions (not promises)

- `keep` vs `filter`: alias or separate semantics?
- Exhaustive-`match`: warning by default, error under `#:strict`?
- `(p.x := 5)` field syntax: macro or core?
- `Value` width (`int` vs `i64`) on 32-bit targets and tower promotion.
- `Program` IR peak memory with per-stage arenas (unmeasured).
- E2 switch list: which capabilities get flags beyond fibers and FS/network?
- G4 layout (decided): versions in `<home>/versions/<version>/`
  (`$BLIP_HOME` or `~/.blip`); shims resolve `$BLIP_VERSION`, then the
  nearest `.blip-version` walking up, then the `default` file.
- E1 live mutation (envs, continuations): in a later version, not v2.