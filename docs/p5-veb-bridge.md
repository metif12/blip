# P5 option 2 — veb calls blip (design note)

Status: design phase (2026-10-30). Option 1 (blip calls veb) is already in
place: `html-escape` and the filesystem prims let a blip program generate
the static site. Option 2 is the hard half: a blip closure becomes a veb
handler, so a V HTTP server can route a request into a blip closure and get
a response back. That is the embedding proof.

## What is needed

### 1. Green continuations (fibers)

The machine runs to completion today. A handler must be able to:
- receive a request value,
- run until it produces a response,
- suspend (yield) so veb can send the response and accept the next request,
- resume on the next request with a fresh value.

The CEK machine already keeps its continuation on an explicit heap stack
(`kstack`), and `m.ret()` pops one. A fiber is a *saved* `kstack` plus
`env` plus `form`, swapped in and out. Concretely:

- `Machine` gains a `fibers []Fiber` stack and a `current int`.
- `run_str` / `drive` operate on the current fiber.
- A new primitive `yield` (or `resume`) saves the current fiber's kstack/env/form
  into a Fiber record and swaps in the next runnable one.
- `new_standalone` creates the main fiber; a handler is a fiber whose entry
  closure is the handler function.

This is the "fibers later with no redesign" the roadmap promised: the explicit
heap stack is exactly what makes saving/restoring a continuation cheap.

### 2. The veb bridge

A V function `veb_handler(req veb.Request) veb.Response` that:

1. Takes the parked handler fiber.
2. Injects `req` as the fiber's pending value (the value `yield` returns).
3. Drives the fiber until it calls `yield` again (producing a response).
4. Converts the response Value back to a veb.Response.
5. Parks the fiber again.

The bridge lives in `vlib/blip/host/veb_bridge.v` (new). It needs:
- `veb_to_value(req)` — V request -> blip.Value (a table of fields)
- `value_to_veb(resp)` — blip.Value -> V response
- `parked_fiber` — the machine + fiber handle the bridge resumes

### 3. Value<->HTTP mapping

A request becomes a table `{:method "GET" :path "/x" :body "..." :headers {...}}`.
A response becomes a table `{:status 200 :body "..." :headers {...}}` or a
string (body only, status 200). The host primitive `respond` could also be a
blip function that calls back into veb.

### 4. Registration

A blip program registers a handler:
```
(veb-route "/" (fn [req] (respond 200 "hello")))
```
The bridge stores the closure in a map path -> Fiber. veb's router calls the
bridge function for that path.

## Order of work

1. Fiber support in the machine (suspend/resume) — gated by a new test
   `tests/fibers.v` that proves a `yield` round-trips a value.
2. `veb_to_value` / `value_to_veb` in host/veb_bridge.v.
3. `veb-route` primitive + a parked machine.
4. A tiny V server example that routes one request through blip. (Done:
   `programs/veb_server.v` routes three pages through blip handlers.)
5. The site itself served by blip handlers (replaces the static `build.lip`
   output for dynamic content).

## Gate

A V program that starts a veb server, registers one blip handler, makes an
HTTP request to it, and asserts the response body. Runs under `v run` with
`-cc gcc`.

## What this is NOT

- Not a full web framework. Only request/response round-trip.
- Not concurrent: one fiber at a time, veb's own thread model drives.
- Not streaming: full response body before return.
