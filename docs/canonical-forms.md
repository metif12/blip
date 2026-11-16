# Canonical forms and compatibility spellings

blip has one advertised spelling per idea. The other spellings keep working
-- removing one would break programs that use it, so compatibility spellings
are forever, not deprecated. New code should use the canonical column; old
code never has to change.

## The table

| Idea | Canonical (advertised) | Compatibility (works, not advertised) | Why both exist |
|---|---|---|---|
| Anonymous function | `(fn [x] ...)` | `(lambda (x) ...)`, `(λ [x] ...)` | Racket users reach for `λ`, Scheme/Elisp/Steel users for `lambda`; one implementation serves all three |
| Definition | `(def name ...)` | `(define name ...)` | `define` is what half of Lisp writes; `def` is shorter and reads the same |
| List head / tail | `car` / `cdr` | `first` / `rest` | same prims (`prim_car`, `prim_cdr`); the short names win |
| Source file | `.blip` only | `.lip`/`.vl` refused with a migration line (v2 A2, 2026-11-17) | v1 compat removed: the loader errors naming `.blip` |
| Old modules | (renamed to `.blip`) | gone in v2 | corpus renamed; `blip migrate` renames |

## Quiet synonyms (same meaning, no advertisement either way)

Some spellings coincide without being anyone's canonical choice, usually
because the machine never distinguished them:

- `do` is `begin` (the emitter treats them identically; `do` shows up
  mostly inside macro expansions).
- `#:when` and `when` both introduce a guard. The reader keeps the
  Racket-style `#:when`; the checker accepts either.
- `last` has no alias pair: it answers the final element, `nil` on empty.
- Error messages name the historical spelling (`define needs...`,
  `car expects...`) even when you wrote the canonical `def`/`first`.
  That is a wart in the messages, not a rule about the language.
- `blip check` reads `def` exactly like `define` (signatures, arity,
  erased types). Only `define/contract` stays `define`-only -- there is
  no `def/contract` form.

## Deliberately *not* aliases

These look interchangeable and are not. Each one is a different semantic,
so unifying them would change programs, not spellings:

- `print` vs `display`: quoted vs bare strings. (Both end the line; see the
  vNext section of `docs/010-roadmap.md` for the deferred verbatim-`print`
  proposal.)
- `->` vs `->>` vs `|>`: the value goes first, last, or "become the call".
  Different plumbing, not different names.
- `=` vs `eq?`: value equality vs identity. `(= '(1 2) '(1 2))` is `#t`;
  `eq?` on two separately built lists is not.
- `cond` vs `case` vs `match`: condition chains vs value dispatch vs
  destructuring. Related, not interchangeable.

## Open questions (not promises)

- `keep` vs `filter`: both currently keep matching elements in every tested
  example (`01_basics`, `05_pipelines`). Whether that sameness is the design
  or a bug is undecided -- do not write new code that depends on them
  differing, and do not "fix" one of them without a gate that pins the other.
- Nested `;=>`: `blip test` checks only top-level forms, so a `;=>` inside
  a body is documentation, not a test. Making the checker descend is a
  vNext item (`docs/010-roadmap.md`), not a quiet change.

## Where this is enforced

Nowhere automatically -- and that is deliberate. A linter that rejects
`define` would turn every migrated file into a patch, which is the opposite
of compatibility. The enforcement is social: examples, the tour
(`blip_in_y_min.md`), and new standard-library code use the canonical
column, so a newcomer imitates the canonical spelling without being told.
