# Getting started

Install blip, run your first program, scaffold a project. Five minutes, three commands.

## Install

The one-liner clones blip and its pinned V toolchain into `~/.blip`. macOS and Linux:

```
curl -fsSL https://metif12.github.io/blip/install.sh | bash
```

Windows (PowerShell):

```
irm https://metif12.github.io/blip/install.ps1 | iex
```

This needs stock V 0.5.2 — the official release archive, not a master build, which resolves project modules differently. To build from a checkout instead, use stock V 0.5.2 exactly as `.github/workflows/ci.yml` does, then run `v -cc gcc -path 'vlib|@vlib' -o blip main.v`. See `CONTRIBUTING.md` for the full recipe.

## First run

```
blip run examples/01_basics.lip
```

Or start the REPL with a bare `blip` and type along with the [tour](tour.html):

```
$ blip
blip:1> (+ 1 2 3)
6
```

Or scaffold a project:

```
blip new myproject
cd myproject
blip run main.lip
blip test main.lip
```

## The CLI, in brief

- `blip run` evaluates files in one machine; bare `blip` starts the REPL
- `blip test` checks the `;=>` expectations in a file
- `blip check` reports contract and type mismatches without running
- `blip build` compiles a program to a self-contained JavaScript module
- `blip fmt`, `blip vet`, `blip doc`, `blip lsp`, `blip new`, `blip pkg` cover formatting, linting, docs, editing, and packages

The full list with details is the [CLI reference](cli.html). Try the [playground](playground.html) for a zero-install taste, and read [status](status.html) for what is done and what is next.
