# Changelog

Recent changes and the work behind them, newest first. Each entry names its
gate: a change without a test that fails without it does not land. The plan
lives in `docs/010-roadmap.md`; this file is the record.

### `(defined? name)` — ask whether a var exists, as a special form

- There was no way to ask "is this name bound here?" without triggering the
  error the question exists to avoid: evaluating the name is exactly what turns
  "is this defined?" into "unbound identifier: name". `(defined? nope)` now
  answers `#f`, `(defined? d)` answers `#t` for a name `define`, `def`, a
  `let`/parameter binding — anything a bare reference resolves to — would find.
  The quoted spelling `(defined? 'nope)` compiles identically.
- A primitive cannot do this: the check is a lookup in the machine's CURRENT
  environment, and a prim never sees the machine (prims/mod.v takes no
  machine on purpose). So it is a special form, `eval_defined` in
  machine/mod.v, routing through the same `m.envs.lookup` a bare-symbol
  evaluation runs before it reports `unbound identifier`.
- The emitter gets it too, or the prelude/program gate on "refused by name"
  would reject every program that uses it: `defined_probe` compiles the name to
  `(typeof X !== 'undefined')` — `typeof` being the one construct JavaScript
  allows on a possibly-absent identifier — resolving the identifier the same
  way `symbol()` does, so the probe agrees with what the emitted program itself
  would answer by referencing the name. The stated divergence: `typeof` on a
  hoisted `function` declaration says "bound" before the declaration has run,
  where the machine says unbound until `define` proceeds — code in textual
  order does not disagree.
- Gate: `tests/binding_forms.v` gains the scope-sensitive section — unbound is
  `#f`, a global/function/prim/quoted spelling is `#t`, and the same name that
  was `#t` inside a `let` answers `#f` after it closes, which is the assertion
  the old `(set! a nil)`-style leaks would have failed — and `tests/emit_js.v`
  runs the same five snippets on both engines.

### `array-append!` — append one array onto another, in the prelude

- Arrays were mutable one value at a time: `array-push!` takes a single value,
  so appending a whole array meant a hand-rolled index loop at every call site
  (programs/json.lip and pratt.lip each carry their own). `lib/std.lip` now
  ships `(array-append! dst src)`: a wrapper that pushes every element of `src`
  onto `dst` in order and returns `dst`, over an index carried by a small
  tail-recursive helper, `array-append!-from`.
- Deliberately ordinary blip rather than a prim, and tail recursion rather than
  a `loop` form: the prelude is also compiled by the JS emitter, which refuses
  `loop` by name — a prelude the backend cannot compile would block every
  emitted program. Tail calls are so real in blip (`kont=0`) that this is also
  the loop form the language actually optimizes; and because every prim here
  crosses the interpreter once per value, `array-push!` stays the loop's body,
  which is exactly the shape the wrapper was meant to give the feature.
- Gate: `examples/02_data.lip` — the spec — gained the call plus an `assert`
  that `=` compares the mutated array contents, so `examples_run` fails without
  the prelude function; `emit_js` compiles the same file through the backend,
  which now also compiles the prelude's new definitions.

### CI and the Docker images now pass -d use_bundled_libgc to Makefile

- The `make -f Makefile v` step used the wrong static library lookup path:
  `thirdparty/tcc/lib/libgc.a`. The CI runner and Docker images installed
  libgc-dev (gcc's bundled Boehm GC) via system package managers but V looked
  in tcc's lib directory. Passing `-d use_bundled_libgc` to Makefile's VFLAGS
  tells V to build Boehm GC from the source in `thirdparty/libgc`, which is
  the expected workflow and no longer requires system libgc at a wrong path.
  Both the `test` job and the `docker-images` job now get past the "Build V"
  step.

### CI: the real Build V failure was an unquoted VFLAGS — `option '-d' requires a value`

- Three green-looking-error CI runs (`#15`, `#16`, and the pre-#17 logs) all
  said only `make: *** [Makefile:33: v] Error 1`, since swallowed. The
  `build.log` diagnostic from the previous entry captured the last line
  before the death: `option '-d' requires a value`. `make
  -f Makefile v VFLAGS=-d use_bundled_libgc` parses as *`VFLAGS` = `-d`,
  plus a second goal named `use_bundled_libgc`* — so the `v` target ran with
  a valueless `-d` and V refused it. The Dockerfiles have always quoted the
  assignment (`VFLAGS="-d use_bundled_libgc"`) and pass this exact line.
- Fixed by quoting in `ci.yml`. Also fixed there (pre-existing, found while
  reading the step closely): the `mkdir -p`/`libgc.a` copy used a
  `v/thirdparty/...` prefix *after* `cd v`, landing the copy in the
  nonexistent `v/v/thirdparty/...`; all three Dockerfiles had the same
  wrong prefix. Now relative to the checkout, with a comment on why.
- CI now builds and runs three more gates: `multi_use`, `value_to_datum`,
  `macros_gate` — previously run by hand only, which made the docs' suite
  lists lie about what was actually enforced.
- Known-open, verified from the same run's logs: `docker-images` fails only
  on the Nix image, at `nix-env -iA nixpkgs.gcc ...` (`error: Unable to
  build profile. There is a conflict...`); the Alpine and Debian images get
  deep into the V build. Not fixed in this change — needs its own
  investigation of which packages collide on the current `nixos/nix:latest`.

### Generated prims were read from a different V build (`gen_math.v` header hash)

- `tools/genprims.vsh --check` failed: the committed
  `vlib/blip/prims/gen_math.v` declared `generated ... at V 0.5.2 abcebfc`,
  while the pinned compiler's vlib math module hashes `dd6834e`. Both builds
  self-report `V 0.5.2` — the exact trap §7.1a documents about pinning
  commits instead of version strings. The only diff the regeneration
  produced is the header hash, no semantics; regenerated and committed.
- What the runner's check then exposed: the shelling-out habit went deeper
  than the stamp. Both `v version` (the stamp) and `v ast -p` (the
  signatures) called bare `v` — whichever build was on PATH. Locally that
  was a release install of another commit, so "regenerated at the pin"
  above was true of the version string and false about the compiler run.
  Fixed on both axes: the tool now uses `@VEXE` — the compiler actually
  running the script — for both calls, and `--check` strips the header
  stamp before comparing, so a check compares generated CONTENT, not the
  birthstamp of whichever build's PATH won.
- Both directions proven against the regenerated file: corrupting only the
  header stamp passes; corrupting a body line (`math.floor(a0) + 1.0`)
  fails with `stale`. An earlier own-goal caught on the way: an `${...}`
  interpolation with a nested `'`-quoted literal turned `strip_stamp` into
  a same-string tautology on both sides and the check accepted real
  corruption; rewritten as plain concatenation and the controls re-run.

### Three suites were green on Windows and blind on POSIX (runner-exposed)

- The runner's "Run the suites" step reached suites CI had never actually
  executed before the Build V fix, and three dependencies on the operator's
  machine fell over:
  - `emit_js` and the `unit` serve check shelled out to bare `blip`. cmd
    searches the current directory, so Windows runs found `blip.exe`;
    POSIX `sh` does not, so the runner died with `sh: 1: blip: not found`,
    exit 127. In `emit_js` this was worse than fast: for the example
    comparisons BOTH engines then failed with the identical error string
    and compared EQUAL — a suite that passes by comparing two identical
    failures. Both now resolve `./blip` (or `blip.exe`) the way CI builds
    it, next to the test binaries.
  - `programs/config.lip` built its demo path from `(env "TEMP")`, a
    Windows convention. Unset on the runner, `string-append` got `nil`.
    Fixed with `nil?` tests over TEMP/TMP falling back to `/tmp`. A first
    attempt used the Ruby idiom `(or (env "TEMP") fallback)` and FAILED
    the same way on a reproduced runner: blip's truthiness is R5RS-strict —
    only `#f` is false — so nil is TRUE and `or` hands it back instead of
    falling through. `or` itself is correct (proven with `#f` and a
    side-effect probe: `(or #f 2 3)` is `2`, the `3` never evaluates); the
    idiom was wrong, and it is now gated: five truthiness checks in
    `tests/binding_forms.v`, including `(or nil 2)` ➜ `nil`.
- Gates: `tests/emit_js.v` (20/20), `tests/unit.v` (174 checks incl.
  `serve answered on stdout => 124 bytes`), `tests/programs_run.v`
  (`config ok` with TEMP set AND unset),
  `tests/binding_forms.v` (94 checks, five of them new).

### Macros: `value → AST` for pure shapes; the embedded machine built and gated

- `docs/macros-design.md` called this work "deferred, no code changes"; that
  stopped being true. `vlib/blip/value_to_datum.v` now converts the eleven
  pure shapes (nil, booleans, integer, float, string, symbol, keyword,
  empty list, pairs and chains, vectors) back into `NodeId`s and refuses the
  complex ones (table, closure, primitive...) with a returned error, in line
  with the errors-as-values rule rather than a panic.
- Option 1 from the memo — embedded machine at emit time — exists as
  `vlib/blip/emit/macro_embed.v` (`expand_macro_at_embed`): a fresh
  standalone machine, source in, expanded `Value` converted back to AST.
- Neither is wired into `emit/mod.v`'s dispatch, so `defmacro` / `macex` /
  `macex1` REMAIN in `unsupported_forms` and `05_pipelines` remains refused
  by name (emit-js: 5 run, 1 refused — unchanged). An earlier edit removed
  them from the list during stub work; that edit was reverted before it
  could merge, because with no emit-time consumer a `defmacro` name falls
  through to the ordinary call path and emits `defmacro(...)` as JS —
  accepted, no output, the silent-green failure the backend gate exists to
  catch.
- Gates: `tests/macros_gate.v` (which started life as a stub that printed
  `FAIL` unconditionally, per the no-code-without-a-failing-gate rule, and
  now exercises 13 real checks) and `tests/value_to_datum.v`.

### Reading and writing configuration: `read-file`, `write-file`, `file-exists?`, `env` (`programs/config.lip`)

- blip had no way to touch the filesystem or the environment, so a "config
  language" could not read a config file. Four hand-written primitives land
  in `vlib/blip/prims/mod.v`: `read-file` and `write-file` answer Result
  values (`(ok ...)` / `(err ...)`), so a missing file is a value that
  composes with `use` rather than an abort; `file-exists?` is a boolean;
  `env` returns the variable's value or nil when it is unset.
- `programs/config.lip` exercises all four end to end: it writes a small
  key: value file, reads it back, folds the lines into a table, reports each
  value, and prints `config ok`. Registered in `tests/programs_run.v`.

### Hostile input is an error, not a process death (`tests/hostile.v`)

- The promise "errors as values" had a hole every wrong call fell through:
  V's **assert** is not recoverable, so `(car)`, `(format 42 "~a")`,
  `({:a 1} 5)`, `(raise (err 42))`, and nine more measured wrong calls
  printed `V panic:` -- or died with an index-out-of-range -- and took the
  whole `blip run` process down. A configuration language has one job above
  all: a config file that says something wrong must be able to say it as an
  error and let the user fix it, never abort a build/REPL.
- The fix has two walls and a gate. The `Value` accessors
  (`as_string/as_pair/as_vector/as_table/as_struct/as_closure/as_int/...`)
  now check with a RECOVERABLE `panic(...)` that names the accessor and the
  tag it met -- V assertions kill the process and no defer can intercept
  them, which is the measured fact this is built on. And `drive`, the one
  funnel every evaluation flows through, carries a `defer`/`recover` safety
  net exactly one frame deep: a panic anywhere inside the machine becomes
  `error: internal error: as_table: called on a integer, not a table`
  through the same source-context decoration every other machine error
  gets. The net lives NOWHERE ELSE, so the reader, the emitter, and the
  suites that call step functions directly still die loudly, and a
  machinery bug above the boundary is not hidden behind a recovered value.
- The gate is `tests/hostile.v`: 38 hostile sources + 4 CLI misuse cases,
  one child process per case (an in-process probe would die at the first
  panic and never name the culprit), asserting no crash exit code and no
  `V panic` in the output. 12/38 crashed when it was written; all 43 pass
  now. Registered in ci.yml.
- One CLI case, deliberately not a machine matter: `blip frobnicate`
  (neither subcommand nor file) said "cannot read frobnicate" and exited 1;
  it now names both readings and exits 2. The `blip file.lip` shorthand
  still runs files without `blip run`.

### The install pins the compiler, like CI does

- `install.sh` and `install.ps1` (and the `site/` copies the website hands
  out) built V from `git clone https://github.com/vlang/v` at whatever HEAD
  was that morning. That is the same unpinned-Makefile hazard CI documented
  and fixed in ci.yml, moved to the user's machine: between the pin
  `0137eb5` and upstream master sit 1123 commits, and somewhere in there the
  checker rejects source that the pinned compiler accepts -- so the install
  works on Friday and fails on Monday, with nothing in either repo to blame.
- Both scripts now build V and vc at exactly the pair ci.yml pins
  (`V_COMMIT` / `VC_COMMIT`), record the pin in a marker file so a re-run
  does not rebuild what is already right, fail fast with per-platform
  guidance when no C compiler is installed, and locate `blip`-relative things
  the same way CI does. The two pins now appear in four files; the gate
  `tests/unit.v install_pins` reads ci.yml and all four scripts and fails on
  any of them going missing or unpinned.

### The JavaScript backend, measured example by example (`blip emit-js`)

- The bar is not "it emits" -- it is that the emitted JavaScript, run on
  node, prints the SAME bytes as `blip run` on the same source. Each new
  form lands only with that comparison, because the previous failure mode
  was acceptance with no output: a green run that means nothing.
- `02_data.lip` is the first example the backend reproduces byte for byte:
  `(1 "two" :three)`, `[1 2 3]`, `{:a 1 :b [2 3]}`. It needed the table,
  array and buffer literals; `list`/`append` and the data batch
  (`array-length`, `array-ref`, `array-set!`, `array-push!`, `put!`,
  `string-split`, `string-trim`, `string-index-of`, `take`); the type
  predicates; `format`; `has-key?`; `string->number`/`number->string`;
  and two rules the emitter had no spelling for -- a KEYWORD in call
  position is a lookup (`(:a {:a 1})`, not a call to a string), and a
  keyword inside quoted data stays a keyword, not a string.
- `->`/`->>`/`|>` thread through `tramp` steps, and an inner thread
  splices into the outer one instead of nesting; `as->` and `cond->` are
  refused by name rather than emitted wrong. `match` handles literals,
  `_` and bare-symbol binding; `struct`, `even?`/`odd?` and tagged
  vectors (so the printer keeps `[1 2 3]` and `(1 2 3)` apart) are in.
- `form()` no longer spells out a call a second time: the statement path
  delegates to `application()`, so a callee routing fix cannot apply to
  expressions and miss statements -- which is exactly how the keyword
  lookup broke in one position and not the other.
`