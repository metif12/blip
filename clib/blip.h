// blip.h -- C embedding API for the blip Lisp dialect.
//
// One opaque handle, string in, string out. This header is the stable
// boundary: everything behind it (the V runtime, the GC, the prelude) may
// change, and programs written against this header keep working.
//
// Ownership rule (the whole contract in two lines):
//   * Every `char **out` parameter is heap-allocated by the library on return,
//     success or failure alike. Release it with blip_free_str.
//   * Nothing else returned by this library may be freed. In particular the
//     pointer from blip_version is static.
//
// Threading: an interpreter is single-threaded, like the V API underneath.
// Use one BlipInterp per thread; they share nothing.
//
// Errors: functions return BLIP_OK (0) or BLIP_ERROR (1). On BLIP_ERROR the
// out string is the same message `blip run` would print: parse errors carry
// `path:line:col`, limits read `step limit exceeded` / `continuation too
// deep`, unknown names read `unbound identifier: ...`.
//
// Values cross the boundary as source text: blip_eval takes program text and
// answers the printed value; blip_call evaluates each argv element as a blip
// expression and passes the results. So from C:
//
//   blip_call(ip, "double", (const char *[]){"21"}, 1, &out)  // => "42"
//
// Full guide with build, link, sandboxing and troubleshooting notes:
// docs/c-lib.md. V-level embedding (no C involved) is docs/embedding.md.

#ifndef BLIP_H
#define BLIP_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

#define BLIP_OK 0
#define BLIP_ERROR 1

// Opaque interpreter. One per thread; machines share nothing, not even the
// host: prints from one interpreter are never visible to another.
typedef struct BlipInterp BlipInterp;

// blip_new creates an interpreter with the embedded prelude and default
// limits. The prelude (lib/std.lip) is compiled into the library, so there
// is no file to ship and no path to configure. Never returns NULL.
BlipInterp *blip_new(void);

// blip_free_interp releases an interpreter. GC-managed memory is reclaimed
// by the runtime; this drops the reference and clears pending output.
void blip_free_interp(BlipInterp *ip);

// blip_eval evaluates src in the running machine and answers the printed
// result. Definitions accumulate across calls. On BLIP_ERROR, out holds the
// error message instead.
int blip_eval(BlipInterp *ip, const char *src, char **out);

// blip_load reads path through the host filesystem and evaluates it in the
// running machine, so definitions in the file are visible afterwards.
// Answers the last value, like blip run.
int blip_load(BlipInterp *ip, const char *path, char **out);

// blip_call resolves name and calls it with argc values. Each argv element
// is evaluated as a blip expression first, so literals and variable names
// both work: {"21"} and {"n"} are both fine. argv may be NULL when argc
// is 0.
int blip_call(BlipInterp *ip, const char *name, const char *const *argv, int argc, char **out);

// blip_set_limits bounds untrusted code. Either argument <= 0 keeps the
// current value. Defaults are generous (100M steps); set both before eval.
void blip_set_limits(BlipInterp *ip, int max_steps, int max_kont);

// blip_output drains everything print/display wrote since the last call,
// joined with newlines. Returns the line count (0 with *out == "" when
// nothing was printed).
int blip_output(BlipInterp *ip, char **out);

// blip_restrict is the sandbox: afterwards only the nkeep names still
// resolve (machine builtins such as apply/error stay; they are syntax-level
// and cannot be removed this way). Untrusted programs cannot reach file IO
// or the loader once those names are gone. Returns names removed.
int blip_restrict(BlipInterp *ip, const char *const *keep, int nkeep);

// blip_version answers the library version, e.g. "0.1.0". Static storage:
// never pass it to blip_free_str.
const char *blip_version(void);

// blip_free_str releases any string the library handed out via char **out.
void blip_free_str(char *s);

#ifdef __cplusplus
}
#endif

#endif
