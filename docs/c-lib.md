# blip as a C library

`clib/` exposes the interpreter through a stable C ABI (`clib/blib.h`), so a
non-V host — a C/C++ program, or anything with C FFI (Python ctypes, LuaJIT,
Rust, Go cgo) — can embed blip without touching V. One opaque handle, string
in, string out. V-level embedding without C is `docs/embedding.md`.

## API at a glance

```c
BlipInterp *ip = blip_new();
char *out = 0;
blip_eval(ip, "(define (double x) (* 2 x))", &out); // => "double"
blip_free_str(out);
blip_call(ip, "double", (const char *[]){"21"}, 1, &out); // => "42"
blip_free_str(out);
blip_free_interp(ip);
```

Every function is documented in `clib/blip.h`; the header is the contract.
`clib/example_eval.c` is the worked example and the CI smoke test: eval,
call, print capture, file load, errors, sandbox, limits.

## Building

Requires the pinned V toolchain (same `V_COMMIT`/`VC_COMMIT` as
`.github/workflows/ci.yml`; `install.sh` builds it). All commands run from
the repo root.

Linux (`.so`):

```sh
v -shared -cc gcc -o libblip.so clib/blip.v
gcc clib/example_eval.c -o clib_smoke -L. -lblip -Wl,-rpath,'$ORIGIN'
./clib_smoke            # expect: clib smoke: all checks passed
```

Windows (`.dll` + import library). V names the DLL image correctly under
MSVC; under gcc the PE image name comes out as `out.exe`, so always link
through an import library built from `clib/blip.def`:

```bat
v -shared -cc msvc -o blip.dll clib/blip.v
lib /def:clib/blip.def /out:blip.lib /machine:x64
cl /nologo clib/example_eval.c blip.lib /Feclib_smoke.exe
clib_smoke.exe          :: run from the repo root: blip_load reads clib/smoke_prog.lip
```

MinGW alternative, verified locally: build with `-cc gcc`, then
`dlltool -d clib/blip.def -l libblip.a`, then
`gcc clib/example_eval.c libblip.a -o clib_smoke.exe`.

macOS (expected, not CI-gated):

```sh
v -shared -cc gcc -o libblip.dylib clib/blip.v
gcc clib/example_eval.c -o clib_smoke -L. -lblip -Wl,-rpath,@loader_path
./clib_smoke
```

`wasm32` is unsupported: the V wasm target lacks the stdlib pieces blip
needs (`os`/`strconv`), same as the CLI.

## Linking into your program

- Linux: `-L<dir> -lblip -Wl,-rpath,<dir>` (or ship the `.so` beside the
  binary and set `LD_LIBRARY_PATH`).
- Windows MSVC: add `blip.lib` to the link, ship `blip.dll` next to the
  `.exe`. DLL lookup is exe-directory first, so no PATH changes are needed.
- The header has `extern "C"` guards; no name mangling to fight.

## Ownership (the whole contract)

- Every `char **out` is heap-allocated on return, success or failure alike.
  Release with `blip_free_str`. Never `free()` it yourself on one platform
  and `blip_free_str` on another: always `blip_free_str`.
- Nothing else may be freed. `blip_version` returns static storage.
- Passing NULL for `ip`, `src`, `name`, `path` or `out` is a `BLIP_ERROR`
  (or a no-op for void functions), never a crash. NULL `argv` with
  `argc == 0` is fine.

## Values, calls, output

- `blip_eval` answers the *printed* value (`embed.show`): `(define (f x) x)`
  answers `"f"`, `(print "hi")` answers `"nil"` and the text lands in the
  print buffer.
- `blip_call` evaluates each `argv` element as blip source first, so C
  callers pass literals (`"21"`, `"[1 2]"`, `":kw"`) and variable names
  with the same spelling. Arity errors come back as `BLIP_ERROR` text.
- `blip_output` drains the print buffer (`print`/`display` since the last
  call), joined with newlines; returns the line count, `""` when empty.
- `blip_load` reads through the host filesystem into the running machine;
  later evals see the definitions. Missing files are errors, not aborts.

## Sandboxing and limits

```c
const char *keep[] = {"+", "-", "*", "print"};
blip_restrict(ip, keep, 4);   // returns names removed
blip_set_limits(ip, 100000, 10000);
```

`restrict_to` keeps only named prims; machine builtins (`apply`, `error`,
...) stay — they are syntax-level. After dropping `read-file`/`load` paths,
a program cannot reach the filesystem; it fails with `unbound identifier`.
Limits abort runaway code with `step limit exceeded` / `continuation too
deep` instead of hanging the host. The smoke test proves both.

## Threading, GC, lifetime

- One interpreter per thread; interpreters share nothing. The type is not
  internally synchronized.
- Memory behind the handle is GC-managed (Boehm, non-moving: the address is
  stable). `blip_free_interp` drops the reference and clears output; the
  runtime reclaims the rest. Returned strings are the exception: plain
  `malloc` copies, which is why they need `blip_free_str`.
- Never pass V-managed memory to `free`, and never keep an `out` pointer
  across `blip_free_interp`.

## Troubleshooting

- `error: unbound identifier: read-file` after `blip_restrict`: the sandbox
  is doing its job; add the name to the keep list.
- Windows link error `unresolved external blip_*`: link the import library
  (`blip.lib`), not the DLL directly. With MinGW, generate it first:
  `dlltool -d clib/blip.def -l libblip.a`.
- Linux `./clib_smoke: error while loading shared libraries`: the loader
  cannot find `libblip.so`; re-link with `-Wl,-rpath,'$ORIGIN'` or set
  `LD_LIBRARY_PATH`.
- `blip_load` fails in the smoke test: run from the repo root, so the
  relative path `clib/smoke_prog.lip` resolves.
- Version drift: `blip_version` mirrors `const version` in `blip.v`; the
  release tarballs always pair one header with the library built from the
  same tag.

## Release artifacts

Tags publish `blip-clib-linux.tar.gz` (`blip.h`, `libblip.so`, `blip.def`,
example + fixture, this guide) and `blip-clib-windows.zip` (`blip.h`,
`blip.dll`, `blip.lib`, example + fixture, this guide), built by
`.github/workflows/release.yml` from the same tag as the binaries.
