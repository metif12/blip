# blip

A Lisp dialect implemented in V: a CEK-style machine with an explicit heap stack, real tail calls, and errors as values.

```
$ blip
blip:1> (define (fib n)
.......   (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
blip:1> (fib 20)
6765
blip:1> (count-down 1000000 0)
1000000
```

A million-deep tail call returns, because a tail call is a loop iteration, not a stack push.

## Three ideas, one language

**`match*`** destructures several values at once, atomically — no nesting one match inside another. **`use`** threads fallible calls flat instead of staircasing callbacks or early returns. **Opaque types** hide constructors behind smart constructors, with no class system and no interfaces.

```
(match* ((ok 1) 2)
  [(ok a) 2])          ;=> 2
```

One clause per combination, no nesting. Take the [tour](tour.html) for the full language, or skip to [getting started](getting-started.html).

## Errors are values

A failure is an `(err ...)` value the program matches on, not an exception that unwinds past it. Functions that can fail for an expected reason return `(ok v)` or `(err 'why)`; functions that fail for an impossible reason call `raise`. [Read more](tour.html) about choosing between them.

## Install

Stock V 0.5.2 plus one script, on macOS and Linux:

```
curl -fsSL https://metif12.github.io/blip/install.sh | bash
```

Windows (PowerShell):

```
irm https://metif12.github.io/blip/install.ps1 | iex
```

Or [build from source](getting-started.html) with the release V compiler. Docker images for three toolchains live in `docker/`.

## Beyond the REPL

- **`blip test`** checks the `;=>` expectations in a file, so examples double as tests.
- **`blip build`** compiles a program to a self-contained JavaScript module.
- **`blip check`** reports contract and type mismatches without running anything.
- **Embeddable**: drive the machine from V, serve `veb` handlers from blip closures, or link `clib/blip.h` from C.
- **Tooling**: `fmt`, `vet`, `doc`, `lsp`, `new`, `pkg`, and editor extensions for VS Code, Kate, Vim, Helix, Zed, and Emacs.

See the [CLI reference](cli.html) and [embedding guide](embedding.html).

---

Early and honest about what does not work yet: full fiber suspension and the WASM backend are still open. [Status](status.html) tracks every milestone and its gate.
