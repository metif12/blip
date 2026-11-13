# Embedding

The machine is a library with no global state, so a V program can drive it — and C programs can too, through a stable ABI. One interpreter per thread; interpreters share nothing.

## From V

One import, one struct. `blip/embed` owns the machine (which owns its arena), loads the prelude, and keeps per-interpreter hosts and limits.

```
import blip.embed
import blip.host

h := host.new_capture()
mut e := embed.new(h)
v := e.eval('(+ 1 2)')!          // definitions accumulate across evals
println(embed.show(v))            // => 3
```

Configuration, calling, and extending:

```
mut e := embed.new_with_config(h, embed.Config{
    max_steps: 10000
    prelude:   .none
})!
e.load_prelude()!                 // embedded lib/std.lip, no path needed
e.load('prog.lip')!               // through the host, into this machine

f := e.lookup('quad')!
v := e.call(f, [blip.integer(3)])!
same := e.call_named('quad', [blip.integer(4)])!

e.register_prim('my-double', my_double)
e.unregister_prim('my-double')
```

Pure functions see only their args; context functions also see the machine (host, env, limits). Either replaces the same-named entry.

## Sandboxing

`restrict_to` keeps only named prims; machine builtins stay, since they are syntax-level. After dropping the `read-file` and `load` paths, a program cannot reach the filesystem. Limits abort runaway code instead of hanging the host.

```
removed := e.restrict_to(['+', '-', '*', 'print'])
```

Values cross the boundary with constructors (`blip.string`, `blip.integer`, `blip.vector`, `blip.table`, ...) and readers (`embed.to_bool`, `embed.to_int`, `embed.to_str`, ...), rendered with `embed.show`. Results use the `(ok v)` / `(err why)` shapes. Errors are strings, classified with `embed.is_unbound_error`, `embed.is_limit_error`, and `embed.is_parse_error`.

## Serving the web

A blip handler closure registers and dispatches: `veb-route` binds a path, `veb-dispatch` runs it, and this very site is served that way in development. The machine-level API underneath is `machine.new_standalone(h)`, `m.call_value(f, args)`, and the `register_prim` / `register_ctx_prim` / `restrict_to` family. `tests/embed_api.v` exercises both layers.

## From C

`clib/blip.h` is the whole surface: an opaque `BlipInterp` pointer, string in, string out. The worked example is `clib/example_eval.c`, and the smoke test (`clib smoke: all checks passed`) evals, calls, captures prints, loads a file, provokes an error, sandboxes, and limits.

```
BlipInterp *ip = blip_new();
char *out = 0;
blip_eval(ip, "(+ 40 2)", &out);   // out => "42"
blip_free_str(out);
blip_free_interp(ip);
```

Every `char *out` is heap-allocated on return, success or failure alike — release with `blip_free_str`. Passing NULL for the handle, source, or out-pointer is an error, never a crash. One interpreter per thread; memory behind the handle is GC-managed, so only the returned strings need freeing.

Linking: `-L&lt;dir&gt; -lblip` on Linux (with an rpath or `LD_LIBRARY_PATH`); on Windows link the import library (`blip.lib`) and ship `blip.dll` next to the `.exe`. The header has `extern "C"` guards.

The full contract — ownership, sandboxing, limits, threading, troubleshooting — is in `docs/c-lib.md`; the V side in `docs/embedding.md`.

---

The [playground](playground.html) runs blip in the browser against a local server, and the [status](status.html) page tracks what is done and what is next.
