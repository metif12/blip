# Getting started

## Install

One line (clones blip and its pinned V toolchain into `~/.blip`):

```
curl -fsSL https://metif12.github.io/blip/install.sh | bash
```

To build from a checkout instead, pin V exactly as `.github/workflows/ci.yml` does, then `v -cc gcc -o blip blip.v`. See `CONTRIBUTING.md` for the full recipe.

## First run

```
blip run examples/01_basics.lip
```

Or scaffold a project:

```
blip new myproject
cd myproject
blip run main.lip
blip test main.lip
```

## The CLI

- `blip run` evaluates files in one machine; bare `blip` starts the REPL
- `blip test` checks the `;=>` expectations in a file
- `blip build` compiles a program to a self-contained JavaScript module
- `blip fmt`, `blip vet`, `blip doc`, `blip lsp`, `blip pkg` cover formatting, linting, docs, editing and packages

Run `blip help <command>` for details on any of them.
