# blip — agent brief

blip is a Lisp dialect implemented in V: a CEK-style machine with an
explicit heap stack, real tail calls, and errors as values. This file is
the repo map and the non-discoverable gotchas. Process and workflow live
in `CONTRIBUTING.md`, the plan in `docs/010-roadmap.md`, history in
`CHANGELOG.md` — read the one your task needs, not all of them.

## Layout

- `blip.v` — CLI entry. `vlib/blip/` — the implementation: `reader/`,
  `machine/`, `prims/` (hand-written plus generated `gen_*.v`, which are
  never hand-edited), `repl/`, `printer/`, `host/`.
- `lib/std.lip` — prelude, loaded before every program. Ordinary blip.
- `examples/` — the six spec programs. `programs/` — real programs
  (brainfuck, json), each ending with an `"<name> ok"` marker.
- `tests/` — suites run with `v run` directly; files are `*.v`, so
  `v test` finds nothing.
- `tools/` — `.vsh` scripts: `genprims` (prims from vlib, with `--check`),
  `check_playground` (builds, serves, and checks the playground API).
  `server.v` (playground backend) and `reader_probe.v` sit at the root.
- `site/` — `build.lip` (the generator, run by pages.yml), `layout.html`,
  `content/*.md`, `assets/`; `playground.html` is served locally by root
  `server.v`. `site_out/` is generated, never edit it.

## Build and test

- Toolchain: vlang/v master at the `V_COMMIT` pinned in
  `.github/workflows/ci.yml`, `-cc gcc` on every build. On Linux also
  `V_MACOS_V3_NO_FALLBACK=1` (the V3 fallback resolves modules
  differently; see roadmap §7.1a).
- `v -cc gcc -o blip.exe blip.v`, then `v run tests/<suite>.v`.
  Suites (the set CI builds and runs): tail_calls, non_tail, loop_forms,
  binding_forms, embedding, repl_golden, examples_run, programs_run,
  genprims, unit, api_coverage, emit_js, lsp, hostile, multi_use,
  value_to_datum, macros_gate. Zero `FAIL` lines.
- `v -cc gcc run tools/genprims.vsh --check` must pass (generated prims
  match the pinned compiler); without `--check` it regenerates. DATED
  2026-10-27: the tool once shelled out to bare `v` — whichever build was
  on PATH — for BOTH the `v ast` signatures and the header version stamp,
  so "generated at the pin" depended on the operator's machine. Now both
  calls use `@VEXE` (the compiler running the script), and `--check`
  strips the header `at V ...` stamp, comparing content only. The
  controls, if anyone edits `strip_stamp`: corrupting ONLY the header
  stamp must still pass; corrupting a body line must fail. A stale check
  after a compiler sync still means regenerate and review the diff.

## Gotchas that cost sessions

- `.lip` files must be BOM-free: the `write` tool adds a BOM, which the
  reader takes as part of the first token. Seed new `.lip` files by
  copying an existing one and editing the copy.
- `(define ...)` never evaluates its body. To trigger a body error in a
  probe, call the function.
- `vlib/blip/prims/gen_*.v` are generated; the one-line
  `register_gen_*` call in `table()` is the only hand touchpoint.
- Shell is Windows PowerShell 5.1: edit with the edit/write tools, use
  `.vsh` scripts (not shell one-liners) for anything reusable, and quote
  accordingly. `v test` finds nothing; `v run` is the runner.
- `make ... VFLAGS=-d use_bundled_libgc` is BROKEN, and the Dockerfiles
  show the fix: quote it (`VFLAGS="-d use_bundled_libgc"`). Unquoted make
  reads `VFLAGS=-d` and treats `use_bundled_libgc` as a second goal; V
  then dies with `option '-d' requires a value` and make prints
  `Makefile:33: v Error 1`. Three CI runs were lost to this before the
  PR #17 `build.log` diagnostic captured the real error text.
- Never run `tests/*.v` files through `.\blip.exe run` — they are V
  programs for `v run`, and the blip reader chokes on `module main`.
  Gates report with `ok  `/`PASS`/`macros_gate:` lines; only a literal
  `FAIL` line (CI greps `^FAIL` from the joined output) means a check
  failed.
