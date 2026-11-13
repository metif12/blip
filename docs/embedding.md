# Embedding blip

One import, one struct. `blip/embed` owns the machine (which owns its
arena), loads the prelude, and keeps per-interpreter hosts and limits.

```v
import blip.embed
import blip.host

h := host.new_capture()
mut e := embed.new(h)
v := e.eval('(+ 1 2)')!          // definitions accumulate across evals
println(embed.show(v))            // => 3
```

## Customising

```v
mut e := embed.new_with_config(h, embed.Config{
    max_steps: 10000
    prelude:   .none             // or .file with prelude_path
})!
e.load_prelude()!                 // embedded lib/std.lip, no path needed
e.load('prog.lip')!               // through the host, into this machine
```

## Calling from V

```v
f := e.lookup('quad')!
v := e.call(f, [blip.integer(3)])!
same := e.call_named('quad', [blip.integer(4)])!
```

## Extending

Pure functions see only their args; context functions also see the machine
(host, env, limits). Either replaces the same-named entry.

```v
e.register_prim('my-double', my_double)
e.register_ctx_prim('my-steps', fn (mut m machine.Machine, _ []blip.Value) !blip.Value {
    return blip.integer(i64(m.steps))
})
e.unregister_prim('my-double')
```

## Sandboxing untrusted code

```v
removed := e.restrict_to(['+', '-', '*', 'print'])
// read-file, write-file, load paths: gone. Builtins handled inside the
// machine (apply/error/...) stay; everything else must be kept by name.
```

Machine-level API without the facade: `machine.new_standalone(h)`,
`m.call_value(f, args)`, `m.register_prim/register_ctx_prim/unregister_prim`,
`m.has_prim/m.prim_names/m.restrict_to`. `tests/embed_api.v` exercises both
layers; `tests/embedding.v` proves machines stay independent.

## Values across the boundary

Construct with `blip.string/integer/float/boolean/vector/table/...`, read
with `embed.to_bool/to_int/to_float/to_str/to_strs`, build with
`embed.from_strs/from_table`, render with `embed.show`. Results use the
`(ok v)` / `(err why)` shapes: `embed.is_ok/is_err/ok_value/err_message`.

## Errors

Errors are strings. Classify with `embed.is_unbound_error/is_limit_error/
is_parse_error`. Parse errors carry `line:col` from `blip.format_error`;
limits are `step limit exceeded` / `continuation too deep`.

## From C instead of V

`clib/blip.h` exposes the same surface through a stable C ABI (opaque
handle, string in, string out): `blip_new/blip_eval/blip_call/blip_load`,
print capture, `blip_restrict` sandboxing, limits, version. Full guide,
build/link commands for Linux/Windows/macOS, and troubleshooting:
`docs/c-lib.md`. The worked example is `clib/example_eval.c`.
