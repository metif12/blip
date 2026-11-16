# P8 — WASM backend and `blip build`

Status: design phase (2026-10-30). `blip build <file>` already emits a
self-contained JavaScript module (P6). The `.wasm` target is the next step.

## What is needed

### 1. A WASM codegen for blip

blip's emit backend (vlib/blip/emit/) is a hand-written JS transpiler that
walks the reader's AST. A WASM backend would need the same walk producing
WASM instructions instead of JS. Two options:

- **Option A: reuse V's WASM backend.** Compile blip itself (the
  interpreter) to WASM, then embed the program as data. The interpreter runs
  the program in-browser. This is the "client-side playground" proof: the
  whole blip VM in a .wasm module, evaluating .lip source at runtime.
  Heavy (~MBs of WASM) but reuses everything.

- **Option B: a WASM codegen in emit/.** Mirror emit/mod.v but emit WASM
  text/binary. Much smaller output but duplicates the emitter and needs a
  WASM runtime for the primitives (print, read-file, etc.).

Option A is the honest first step: it proves embedding (blip runs in a
browser) without rewriting the emitter. Option B is an optimization for
later.

### 2. `blip build --target wasm`

`blip build <file> --target wasm` should produce a .wasm module. With
Option A, this means: compile blip.v + the program to WASM using V's
`-b wasm` backend, embedding the program source. The current blocker is
that blip.v uses OS-specific functions (`os.executable`, `os.path_separator`,
`os.exists`) that V's WASM backend does not support. These need `$if wasm`
guards with WASM-compatible alternatives (or compile-time defaults).

### 3. Client-side playground

A web page that loads the .wasm module, takes .lip source, and evaluates it.
This is the proof that blip is embedded in the strongest sense.

## First concrete step

Guard the OS-specific code in blip.v with `$if !wasm` so `v -b wasm`
can compile blip. Then `blip build --target wasm` can invoke V's WASM
backend. Estimated: small changes to blip.v (std_path, programs_path).

## Gate

`v -b wasm -o blip.wasm blip.v` succeeds, and the resulting module evaluates
`(print "hello")` in a WASM runtime (node --experimental-wasm-modules or
browser).

## What does NOT transfer

V's WASM backend is incomplete (no full os module, no network). So the
WASM build of blip will be a subset: no file I/O, no LSP, no subprocess.
The REPL and `run` work on in-memory source; `emit-js` works (it's pure).
`blip build --target wasm` is for embedding the interpreter, not for
compiling arbitrary .lip programs to standalone .wasm.

## Findings (2026-10-30)

The first concrete step (guarding OS-specific code) is done: every os.* call in
blip.v and the six vlib/blip/* modules that use os is now behind
` $if !wasm32 ` / ` $if wasm32 ` guards, and the os import itself is
conditional. `blip.v` no longer fails on `os.executable`/`os.read_file`.

What still blocks `v -b wasm -o blip.wasm blip.v` is V's own standard
library, not blip code:

- `strconv` (`format_int`, `atof64`, `AtoF64Param`) does not compile
  for wasm32. Used by the reader (number parsing) and printer (number
  formatting).
- `recover` (used in machine/mod.v for error handling) is not available
  for wasm32.
- `v/embed_file` uses `os.read_bytes`, which is missing for wasm32.

These are V toolchain limitations. Until V's wasm32 backend provides them,
blip cannot be compiled to wasm. The guards are in place so that once V
catches up, `v -b wasm -o blip.wasm blip.v` will succeed without further
blip changes.

`blip build --target wasm` reports this status honestly.