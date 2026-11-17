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
item has no stability note.

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
must-haves are the current set plus DEB and MSI; RPM, Snap, Flatpak,
AppImage, DMG, and the rest follow as their gates clear, each in its
own change. Signing/notarization (DMG, MSI) is called out now because
it is the known blocker, not because v2 promises it.

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
