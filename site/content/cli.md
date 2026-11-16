# CLI reference

Everything the `blip` command does, on one page. Run `blip help &lt;command&gt;` for the same text in the terminal.

## Everyday

**`blip`** starts the REPL, and **`blip repl`** spells it out. The REPL keeps one machine for the whole session, so definitions accumulate. A line that opens a bracket is held until the depth returns to zero: the prompt shows it (`blip:1>` top level, `blip:2>` one deep).

```
$ blip
blip:1> (def (double x) (* x 2))
blip:1> (double 21)
42
```

REPL commands, at the start of a line: `,l PATH` loads a file into the running machine, `,r` reloads the last loaded file, `,h` prints this help, `,q` quits.

**`blip run &lt;file.blip&gt; ...`** evaluates files in order, in one machine, so a definition made in the first is visible in the second. The standard library loads first. A bare filename is shorthand: `blip prog.blip` means `blip run prog.blip`.

**`blip test &lt;file.blip&gt; ...`** evaluates and checks the `;=>` expectations on each line: the form's value, as text, must equal what follows the arrow. Exit status is 0 when every expectation holds, so this works as a CI gate. Files without expectations are merely run.

## Checking and building

**`blip check &lt;file.blip&gt; ...`** reports contract and type mismatches without running anything: wrong arity, literal arguments of the wrong type, bodies contradicting declared returns, `->/c` outside `define/contract`. Unknown names are never errors. Exit status is 0 when nothing is found.

**`blip build &lt;file&gt; [-o out.js]`** compiles a program to a self-contained JavaScript module. **`blip emit-js &lt;file.blip&gt;`** prints the same module to stdout instead of a file.

## Working with code

**`blip fmt [-w] &lt;file.blip&gt;`** pretty-prints a file; without `-w` it prints to stdout, with `-w` it writes back.

**`blip doc &lt;file.blip&gt;`** generates documentation from doc comments.

**`blip vet [file]`** is the linter hook. **`blip lint [file]`** checks a commit message — subject length, the blank line after the subject, body width — reading from a file or `.git/COMMIT_EDITMSG`, so it works as a git `commit-msg` hook:

```
blip lint .git/COMMIT_EDITMSG
```

**`blip lsp`** serves the language server over stdio (JSON-RPC 2.0): reader diagnostics per open file — unclosed brackets, stray closes, unterminated strings — at the positions the reader reports. The editor extensions launch this; there is normally no reason to run it by hand.

## Projects and packages

**`blip new &lt;name&gt;`** scaffolds a project: `main.blip` (which runs and
tests clean), `README.md`, `.gitignore`, and `blip.mod`. **`blip init
[name]`** writes the same files into the current directory without touching
what is there. Both end in a project whose `run`/`test` pass immediately.

```
blip new myproject
cd myproject
blip run main.blip
blip test main.blip
```

**`blip install &lt;owner/repo&gt;[@ref]`** installs a package's tools onto
PATH: each tool becomes a wrapper in `.blip/bin/` around `blip run`. The
package lists them in its `blip.mod` `(tools (name "file.blip"))` stanza; with
no stanza, a root `tool.blip` is the default. **`blip env`** prints project
facts go-style, one `key value` per line. **`blip pkg why &lt;name&gt;`**
reports who depends on a package and what each requester asked for.

**`blip pkg`** manages packages, which are git repositories of `.blip` files:

```
blip pkg install [owner/repo[@ref]]   install the lock, or one package
blip pkg update                       re-resolve ./blip.mod to fresh pins
blip pkg verify                       check the tree against the lock
blip pkg list
blip pkg remove <name>
```

With no arguments, install reproduces the lock (exact commits, checksums verified). `update` resolves every requirement in `./blip.mod` — plus every workspace member manifest — to the newest tag all requesters accept, and rewrites `blip.lock` with the commit plus a content checksum. `verify` recomputes the tree checksums and fails loudly on tampering. Version requirements look like `(deps (acme/db "&gt;=1.0.0"))`; `(deps (shop/shared "path:../shared"))` copies a local directory in for development. `BLIP_PKG_MIRROR=&lt;dir&gt;` retargets the github URL at `&lt;dir&gt;/&lt;owner&gt;/&lt;repo&gt;`.

Install clones into `blip_modules/&lt;owner&gt;/&lt;repo&gt;` and records the commit in `blip.lock`. A package is reachable with `(import &lt;repo&gt;)`, which loads its `blip.blip` entry point.

**`blip migrate [--check] &lt;file|dir&gt;`** rewrites v1 spellings to v2 (`def`, `fn`, `begin`, `car`/`cdr`, `match`, `if`) and renames `.lip` files to `.blip`. With `--check` nothing is written.

## About

**`blip version`** prints the version and the compiler it was built with. **`blip help [command]`** prints usage, or the full text for one command.

---

The language itself is covered in the [tour](tour.html). To drive blip from other languages, see [embedding](embedding.html).
