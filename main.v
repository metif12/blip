module main

$if !wasm32 {
	import os
}
import blip
import blip.emit
import blip.host
import blip.lsp
import blip.machine
import blip.manifest
import blip.migrate
import blip.pkg
import blip.printer
import blip.reader
import blip.repl
import blip.toolchain
import strings

// blip: a Lisp dialect implemented in V.
//
//   blip                      a REPL
//   blip repl                 the same REPL, spelled out
//   blip run <file.blip> ...   evaluate files, in order, in one machine
//   blip <file.blip>           shorthand for `run`
//   blip test <file.blip> ...  evaluate and check the `;=>` expectations
//   blip check <file.blip> ... report contract/type mismatches without running
//   blip emit-js <file.blip>   compile a file to a JavaScript module on stdout
//   blip build <file> [-o out.js]  compile a file to a self-contained .js module
//   blip fmt [-w] <file.blip>  pretty-print (normalize) a file, write back with -w
//   blip doc <file.blip>       generate documentation from doc comments
//   blip lint [file]          check a commit message (default COMMIT_EDITMSG)
//   blip vet [file]           same as lint, the linter hook
//   blip lsp                  serve the language server over stdio
//   blip new <name>           scaffold a project
//   blip init [name]          scaffold inside the current directory
//   blip install <repo>       install package tools onto PATH
//   blip env                  print project facts (versions, paths)
//   blip toolchain <sub>      manage blip itself (install, use, default)
//   blip pkg <sub>            install, list and remove packages
//   blip version | help       about, and about a command
//
// No arguments starts a REPL because the CLI already requires a file for
// anything else, so the default costs nothing and is the thing a person wants
// most often once the language is installed.

// version is the blip version `blip version` reports. The fixture build
// (`v -d fixture_version_2`) recompiles with a second version so two
// toolchains can sit side by side in the G4 gate.
$if fixture_version_2 {
	const version = '0.2.0-fixture'
} $else {
	const version = '0.1.0'
}

fn exit_code(code int) {
	exit(code)
}

fn usage() {
	eprintln('blip ${version} -- a Lisp dialect implemented in V

usage:
  blip                      start the REPL
  blip repl                 start the REPL
  blip run <file.blip> ...   evaluate files in order, in one machine
  blip <file.blip>           shorthand for `blip run`
  blip test <file.blip> ...  evaluate and check the `;=>` expectations
  blip check <file.blip> ... report contract/type mismatches without running
  blip emit-js <file.blip>   compile a file to a JavaScript module on stdout
  blip build <file> [-o out.js]  compile a file to a self-contained .js module
  blip fmt [-w] <file.blip>  pretty-print (normalize) a file, write back with -w
  blip doc <file.blip>       generate documentation from doc comments
  blip lint [file]          check a commit message (default COMMIT_EDITMSG)
  blip vet [file]           same as lint, the linter hook
  blip lsp                  serve the language server over stdio
  blip migrate [--check] <file|dir>  rewrite v1 spellings to v2 (`def`, `fn`, `begin`...)
  blip new <name>           scaffold a project
  blip init [name]          scaffold inside the current directory
  blip install <repo>       install package tools onto PATH
  blip env                  print project facts (versions, paths)
  blip toolchain <sub>      manage blip itself (install, use, default)
  blip pkg install [repo]      install the lock, or a package from GitHub
  blip pkg update               re-resolve ./blip.mod to fresh pins
  blip pkg verify               check the tree against the lock
  blip pkg list                 list installed packages
  blip pkg remove <name>        remove an installed package
  blip version              print the version
  blip help [command]       help for a command

run `blip help <command>` for details.')
}

fn help_for(command string) {
	match command {
		'repl' {
			println('blip repl -- start the interactive REPL

Bare blip does the same thing. The REPL keeps one machine for the whole session,
so definitions accumulate. A line that opens a bracket is held until the depth
returns to zero, and the prompt shows how deep it is: blip:1> at the top level,
blip:2> inside one bracket.

Commands, at the start of a line:
  ,l PATH   load a file into the running machine
  ,r        reload the last file loaded with ,l
  ,h        this help
  ,q        quit')
		}
		'run' {
			println('blip run <file.blip> ... -- evaluate files

Several files are evaluated IN ORDER IN ONE MACHINE, so a definition made in the
first is visible in the second. That is the difference between this and running
each file separately.

The standard library is loaded first, so print and string-upcase are names
rather than something every file has to require.

blip somefile.blip is a shorthand for blip run somefile.blip.')
		}
		'test' {
			println('blip test <file.blip> ... -- evaluate and check expectations

A ;=> expected comment on the same line as a form is an expectation: the form is
evaluated and its value is compared, as text, against what follows the arrow. A
mismatch is reported with the line, the value and the expectation. Only
top-level forms are checked: a ;=> nested inside a body is documentation,
not a test. `--nested` additionally checks nested print/println/display
forms: a nested print arrow holds when it names either the fragment the
print wrote or the value the print answered (usually nil), and fails
otherwise; any other nested ;=> (a match clause, a quoted datum) cannot run
on its own, so it fails loudly, naming the line. That loud list is what
still blocks making nested the default.

  (def (double x) (* 2 x))
  (double 21)   ;=> 42

Exit status is 0 when every expectation held and 1 when any did not, so this
works as a test gate from CI. Files without expectations are merely run.')
		}
		'check' {
			println('blip check <file.blip> ... -- report mismatches without running

The static checker for erased annotations (M10). Functions defined with
annotated `def` -- (def (add (x int) (y int)) int ...) -- have their
call sites judged: wrong arity and literal arguments of the wrong type are
reported as file:line:col: message, one per mismatch. So is a body whose
known type contradicts a declared return, and a ->/c outside
define/contract.

Anything the checker has no signature for -- unannotated functions, the
prelude, macros -- is unknown, and unknown unifies with everything. A file
that passes is not proven correct; a file that fails names a real
mismatch. Nothing is evaluated, so checking a hostile file is safe.

Exit status is 0 when nothing was found and 1 when any diagnostic was
reported.')
		}
		'lsp' {
			println('blip lsp -- serve the language server

Speaks JSON-RPC 2.0 over standard input and output, the way LSP specifies. The
editor extension launches this; there is normally no reason to run it by hand.

What it does today is publish reader diagnostics: every file that is opened is
read, and anything the reader reports -- an unclosed bracket, a stray close, an
unterminated string -- becomes a diagnostic at the position the reader itself
reported. There is no type checking and no go-to-definition yet.')
		}
		'lint' {
			println('blip lint [file] -- lint a commit message

Reads the message from <file> (or COMMIT_EDITMSG in the current directory
when no file is given) and checks the subject length, the blank line after
the subject, and the body width. Exits 0 when the message is clean and 1
when it is not, so it works as a git commit-msg hook:

  blip lint .git/COMMIT_EDITMSG

The rules live in programs/lint_commit.blip, which is also runnable on its
own: blip run programs/lint_commit.blip')
		}
		'new', 'init' {
			println('blip new <name> / blip init [name] -- scaffold a project

`new` creates <name>/ with main.blip (which runs and tests clean),
README.md, .gitignore, and blip.mod, and refuses when the directory
exists. `init` writes the same files into the current directory without
touching what is there, taking the name from the directory when none is
given -- the way to turn an existing folder into a project. Both end in
a project whose `blip run main.blip` and `blip test main.blip` pass.')
		}
		'install' {
			println('blip install <owner/repo>[@ref] -- install a package tools onto PATH

Installs the package like `pkg install`, then links every tool it
declares into .blip/bin/ as a wrapper around `blip run`. The package
lists them in its blip.mod `(tools (name "file.blip") ...)` stanza; with
no stanza, a root tool.blip is the default tool, named after the repo.
Add .blip/bin to PATH once and every installed tool is a command.')
		}
		'env' {
			println('blip env -- print project facts

One `key value` per line, in stable order: the blip version, the project
directory, the manifest (or none), the module, the lock, the modules and
bin directories, the package mirror, and the workspace members. Nothing
is evaluated; this is safe anywhere, project or not.')
		}
		'toolchain' {
			println('blip toolchain -- manage blip itself

Versions live in <home>/versions/<version>/ (home is $BLIP_HOME when set,
else ~/.blip); <home>/bin/blip is a shim that resolves the version per
directory and execs it.

  blip toolchain install <version>  fetch and unpack a release
  blip toolchain list               installed versions
  blip toolchain use <version>      pin this directory (.blip-version)
  blip toolchain default <version>  set the fallback
  blip toolchain shim               install the bin/ shims
  blip toolchain remove <version>   delete a version

Resolution is $BLIP_VERSION, then the nearest .blip-version walking up,
then the default file. $BLIP_RELEASE_BASE retargets the release download
at a local directory (offline fixtures); without it, releases come from
github. Installing starts from the current release layout -- a bare
binary -- so lib/ and programs/ snapshot from the running blip beside it.')
		}
		'pkg' {
			println('blip pkg -- package management

  blip pkg install [owner/repo[@ref]]  install the lock, or one package
  blip pkg update                      re-resolve ./blip.mod to fresh pins
  blip pkg verify                      check the tree against the lock
  blip pkg list                        what is installed, and from where
  blip pkg remove <name>               delete an installed package
  blip pkg why <name>                  who depends on it, and what each asked for

A package is a git repository holding .blip files. install clones it into
blip_modules/<owner>/<repo>, records it in blip.lock with the commit that was
taken plus a content checksum, and every later run sees it.

`pkg install` with no arguments reproduces the lock (the clean-room path:
exact-sha checkouts, checksums verified). `pkg update` re-resolves every
requirement in ./blip.mod -- plus every workspace member manifest -- to
the newest tag that satisfies all requesters, and rewrites the lock.
`pkg verify` recomputes the tree checksums and fails loudly on tampering.

Versions live in the manifest: (deps (acme/db ">=1.0.0")) pins the newest
tag meeting every requester; (deps (shop/shared "path:../shared")) copies
a local directory in for development. BLIP_PKG_MIRROR=<dir> retargets the
github URL at <dir>/<owner>/<repo> (private mirrors, offline fixtures).

Once installed, a package is reachable with (import <repo>), which loads its
blip.blip entry point into the running machine -- the same thing use does for a
file, with the path resolved through blip_modules/ instead of by hand.')
		}
		'migrate' {
			println('blip migrate [--check] <file|dir> -- rewrite v1 spellings to v2

Rewrites (define ...) to (def ...), (lambda (p) ...) to (fn [p] ...),
(do ...) to (begin ...), first/rest to car/cdr, keep to filter, (case ...)
to (match ...), and (when ...) to (if ...). Quote is untouched, quasiquote
is left with a warning, define/contract is kept with a warning.

With --check nothing is written; exit 1 when anything would change.')
		}
		'version' {
			println('blip version -- print the version

Prints the version and the compiler it was built with.')
		}
		else {
			eprintln('blip: no help for unknown command `${command}`')
			exit_code(2)
		}
	}
}

// std_path is the standard library, loaded before every program.
//
// A language with a prelude is a language where print and string-upcase are names
// rather than something every file has to require first. The examples assume it:
// a call to parse-in is a call, and making every reader scroll past a require for
// it would be the wrong default.
//
// It is loaded into the same machine as the program, so a program can rebind any
// of it and the change is visible to a later file.
// resource_path finds a file shipped beside the binary: the standard library
// or a program. Both live next to the executable (`lib/std.blip`,
// `programs/<name>`), with one directory up as the fallback for running from
// source layouts. One helper, not two copies of the same probe.
fn resource_path(rel string) string {
	$if wasm32 {
		return rel
	} $else {
		exe := os.executable()
		dir := os.dir(exe)
		for candidate in [os.join_path(dir, rel), os.join_path(os.dir(dir), rel)] {
			if os.exists(candidate) {
				return candidate
			}
		}
		return ''
	}
}

// std_path is the standard library, loaded before every program.
//
// A language with a prelude is a language where print and string-upcase are names
// rather than something every file has to require first. The examples assume it:
// a call to parse-in is a call, and making every reader scroll past a require for
// it would be the wrong default.
//
// It is loaded into the same machine as the program, so a program can rebind any
// of it and the change is visible to a later file.
fn std_path() string {
	return resource_path('lib${os.path_separator}std.blip')
}

fn programs_path(name string) string {
	return resource_path('programs${os.path_separator}${name}')
}

// need_blip_ext enforces the v2 source extension (roadmap A2): only
// `.blip` files evaluate. `Machine.load` guards `require`/`,l`/imports,
// but `run`/`test`/`check` read through `run_str`, so every command that
// takes a file path enforces it here too. `migrate` is exempt: it reads
// v1 input on purpose.
fn need_blip_ext(path string) ! {
	if path.ends_with('.lip') || path.ends_with('.vl') {
		return error('blip: ${path}: v2 loads .blip files only; rename to .blip and run `blip migrate` on it')
	}
}

// auto_manifest applies ./blip.mod when a command runs inside a project
// directory (roadmap E2b). No manifest is the common case and stays silent.
// A manifest that will not parse, or names an unknown feature, fails the
// command instead of running with the wrong capabilities: the file declares
// intent, and running past a broken declaration would be the typo that
// silently passes which the manifest format exists to prevent.
//
// The prelude always loads first with full prims: std.blip is trusted
// infrastructure, and a project switch must gate user code, not the
// library the error messages are written in.
fn auto_manifest(mut m machine.Machine) bool {
	if !os.exists('blip.mod') {
		return true
	}
	src := os.read_file('blip.mod') or {
		eprintln('blip: cannot read blip.mod: ${err.msg()}')
		return false
	}
	mf := manifest.parse(src) or {
		eprintln(err.msg())
		return false
	}
	m.apply_manifest(mf) or {
		eprintln(err.msg())
		return false
	}
	return true
}

fn run_files(paths []string) int {
	$if wasm32 {
		println('blip: run not available in wasm build')
		return 1
	} $else {
		h := &host.ConsoleHost{}
		mut m := machine.new_standalone(h)
		mut code := 0
		std := std_path()
		if std != '' {
			m.load(std) or {
				eprintln('blip: cannot load the standard library: ${err.msg()}')
				code = 1
			}
		}
		if !auto_manifest(mut m) {
			return 1
		}
		for path in paths {
			need_blip_ext(path) or {
				eprintln(err.msg())
				code = 1
				continue
			}
			src := os.read_file(path) or {
				eprintln('blip: cannot read ${path}')
				code = 1
				continue
			}
			m.source = path
			m.run_str(src) or {
				eprintln(err.msg())
				code = 1
			}
		}
		return code
	}
}

// ---- emit-js -------------------------------------------------------------

// The standard library goes into every emitted module, in front of the program,
// because `blip run` loads it in front of the file too. Without it the emitted
// JavaScript references `lookup-sym`, `validate`, `sqrt` and every other stdlib
// name as identifiers nothing defines -- the program emits cleanly and then dies
// at the first call. The gate knows the same thing, and both go through
// `compile_program` so the knowledge is not in two places to drift.
fn emit_js(paths []string) int {
	$if wasm32 {
		println('blip: emit-js not available in wasm build')
		return 1
	} $else {
		mut code := 0
		for path in paths {
			res := compile_one(path) or {
				eprintln(err.msg())
				code = 1
				continue
			}
			if res.blocked.len > 0 {
				// Refusal is reported, not hidden: silently emitting `undefined`
				// for a form the engine does not understand is how a backend ends
				// up wrong in a way nobody can see.
				eprintln('blip: ${path}: not emitted: ${res.blocked.join(', ')}')
				code = 1
			}
			println(res.js)
		}
		return code
	}
}

fn start_repl() int {
	$if wasm32 {
		println('blip: wasm build')
		return 0
	} $else {
		mut r := repl.new(&host.ConsoleHost{})
		std := std_path()
		if std != '' {
			r.machine.load(std) or {
				eprintln('blip: cannot load the standard library: ${err.msg()}')
			}
		}
		// A broken manifest warns rather than refusing the session: the REPL
		// is where a user fixes the file, and locking them out of the tool
		// they fix it with would be the wrong strictness.
		auto_manifest(mut r.machine)
		return r.run()
	}
}

fn main() {
	$if wasm32 {
		println('blip wasm: ready')
		return
	} $else {
		args := os.args[1..]
		if args.len == 0 {
			exit_code(start_repl())
		}
		match args[0] {
			'repl' {
				exit_code(start_repl())
			}
			'run' {
				if args.len < 2 {
					eprintln('blip: run needs a file')
					eprintln('run `blip help run` for usage')
					exit_code(2)
				}
				exit_code(run_files(args[1..]))
			}
			'test' {
				if args.len < 2 {
					eprintln('blip: test needs a file')
					eprintln('run `blip help test` for usage')
					exit_code(2)
				}
				exit_code(run_tests_nested(args[1..]))
			}
			'check' {
				if args.len < 2 {
					eprintln('blip: check needs a file')
					eprintln('run `blip help check` for usage')
					exit_code(2)
				}
				exit_code(check_files(args[1..]))
			}
			'emit-js' {
				if args.len < 2 {
					eprintln('blip: emit-js needs a file')
					eprintln('run `blip help emit-js` for usage')
					exit_code(2)
				}
				exit_code(emit_js(args[1..]))
			}
			'lsp' {
				lsp.serve()
			}
			'lint', 'vet' {
				mut file := 'COMMIT_EDITMSG'
				if args.len >= 2 {
					file = args[1]
				}
				if !os.exists(file) {
					eprintln('blip: cannot read ${file}')
					exit_code(2)
					return
				}
				os.setenv('BLIP_LINT_FILE', file, true)
				prog := programs_path('lint_commit.blip')
				if prog == '' {
					eprintln('blip: cannot find programs/lint_commit.blip')
					exit_code(2)
					return
				}
				exit_code(run_files([prog]))
			}
			'fmt' {
				mut write := false
				mut file := ''
				for a in args[1..] {
					if a == '-w' {
						write = true
					} else {
						file = a
					}
				}
				if file == '' {
					eprintln('blip: fmt needs a file')
					eprintln('run `blip help fmt` for usage')
					exit_code(2)
					return
				}
				exit_code(fmt_file(file, write))
			}
			'migrate' {
				mut target := ''
				mut check_only := false
				for a in args[1..] {
					if a == '--check' {
						check_only = true
					} else if target == '' {
						target = a
					} else {
						eprintln('blip: migrate takes one path: `blip migrate [--check] <file|dir>`')
						exit_code(2)
						return
					}
				}
				if target == '' {
					eprintln('blip: migrate needs a file or directory')
					eprintln('usage: blip migrate [--check] <file|dir>')
					exit_code(2)
					return
				}
				exit_code(migrate_cmd(target, check_only))
			}
			'doc' {
				if args.len < 2 {
					eprintln('blip: doc needs a file')
					eprintln('run `blip help doc` for usage')
					exit_code(2)
					return
				}
				exit_code(doc_file(args[1]))
			}
			'build' {
				mut target := 'js'
				mut out := ''
				mut file := ''
				mut i := 1
				for i < args.len {
					a := args[i]
					if a == '-o' && i + 1 < args.len {
						out = args[i + 1]
						i += 2
						continue
					}
					if a == '--target' && i + 1 < args.len {
						target = args[i + 1]
						i += 2
						continue
					}
					if file == '' {
						file = a
					}
					i++
				}
				if file == '' {
					eprintln('blip: build needs a file')
					eprintln('run blip help build for usage')
					exit_code(2)
					return
				}
				if target == 'wasm' {
					eprintln('blip: WASM backend is not yet available (P8).')
					eprintln('V wasm32 target lacks os/strconv/recover, which blip needs.')
					eprintln('Use blip build file for a JavaScript module instead.')
					exit_code(2)
					return
				}
				if out == '' {
					out = file.replace('.blip', '.js')
				}
				exit_code(build_file(file, out))
			}
			'new' {
				if args.len < 2 {
					eprintln('blip: new needs a name')
					eprintln('run `blip help new` for usage')
					exit_code(2)
					return
				}
				exit_code(scaffold(args[1]))
			}
			'init' {
				name := if args.len >= 2 { args[1] } else { os.file_name(os.getwd()) }
				println('initializing ${os.getwd()}/')
				exit_code(scaffold_into('.', name))
			}
			'install' {
				if args.len < 2 {
					eprintln('blip: install needs <owner/repo>[@ref]')
					eprintln('run `blip help install` for usage')
					exit_code(2)
					return
				}
				exit_code(install_tool(args[1]))
			}
			'env' {
				exit_code(env_cmd())
			}
			'pkg' {
				exit_code(pkg_command(args[1..]))
			}
			'toolchain' {
				exit_code(toolchain_command(args[1..]))
			}
			'version', '-V', '--version' {
				println('blip ${version}')
			}
			'-h', '--help', 'help' {
				if args.len >= 2 {
					help_for(args[1])
				} else {
					usage()
				}
			}
			else {
				// Allow `blip file.blip` as a shorthand for `blip run file.blip`.
				// A word that is neither a subcommand nor a file fails both ways,
				// and saying only "cannot read" sends someone who mistyped a
				// subcommand hunting for a file that was never theirs.
				if !os.exists(args[0]) && !args[0].ends_with('.blip') {
					eprintln('blip: ${args[0]} is neither a subcommand nor a file')
					eprintln('run `blip help` for subcommands, or `blip run <file.blip>`')
					exit_code(2)
				}
				exit_code(run_files(args))
			}
		}
	}
}

// ---- test ----------------------------------------------------------------

// expectation returns the `;=>` expectation written after a form on line `lineno`,
// or the empty string when there is none.
//
// Both spellings the examples actually use are accepted. A test that rejects the
// one it did not think of is a test that fails on the repo it is testing.
fn expectation(lines []string, lineno int) string {
	if lineno < 1 || lineno > lines.len {
		return ''
	}
	line := lines[lineno - 1]
	mut idx := line.index(';=>') or { -1 }
	mut width := 3
	if idx < 0 {
		idx = line.index('; =>') or { -1 }
		width = 4
	}
	if idx < 0 {
		return ''
	}
	// A doubled semicolon is a prose comment, not an expectation. `;; => true`
	// documents a fact about the line above it -- `0 ;=> true` under a heading
	// saying only #f is false is prose about truthiness, not a value -- and it
	// still contains `; =>`, which is why the marker alone is not enough and
	// the delimiter in front of it has to be checked.
	if idx > 0 && line[idx - 1] == `;` {
		return ''
	}
	return first_chunk(line[idx + width..])
}

// first_chunk returns the expected value and drops the prose that follows it.
//
// The examples write `;=> 6      variadic` -- the value, then a gap, then why --
// and `;=> [1 4 9]` with single spaces inside the value. So the split is on a
// run of two or more whitespace characters, never on one: a vector prints with
// single spaces and must survive intact, while six spaces are always prose.
fn first_chunk(s string) string {
	t := s.trim_space()
	mut run := 0
	for i := 0; i < t.len; i++ {
		c := t[i]
		if c == ` ` || c == `\t` {
			run++
			if run >= 2 {
				return t[..i - 1].trim_space()
			}
		} else {
			run = 0
		}
	}
	return t
}

fn (mut s TestSuite) check(path string, lineno int, want string, got string) {
	if got == want {
		return
	}
	s.fails++
	eprintln('${path}:${lineno}: expected ${want}, got ${got}')
}

struct TestSuite {
mut:
	fails  int
	checks int
}

// NestedExpect is one nested `;=>` found by the --nested walk: the line it
// sits on, the text after the arrow, and whether the form is a print-family
// call (checkable: true of its fragment or of its answer) or anything else
// (not runnable on its own: documentation by construction).
struct NestedExpect {
	line int
	want string
	head string
}

// collect_nested walks the forms under `id` in source order, skipping `id`
// itself (the top-level form, checked by the normal path). Quoted data is
// not code: `quote`/`quasiquote` bodies and `quoted`/`quasi` datum subtrees
// are skipped, descending only into `unquote`, which does run. Macro
// templates that merely CONTAIN a print are therefore never mistaken for a
// print that ran.
//
// A nested form that STARTS on its parent's line shares that line's arrow
// with it (`(map (fn [x] ...) ...) ;=> ...` annotates the map, not the fn;
// the inner lists of a match clause share the clause's line the same way),
// so only a form starting on its own line is a candidate: attribution
// needs its own line. A nested NON-print on the top form's LAST line is
// likewise skipped: the top-level rule keys on the first line, so a
// last-line arrow is the top form's orphaned annotation, and --nested does
// not invent a check the default never ran. But a nested PRINT on the last
// line is checked: its fragment is real output with its own arrow
// (`(println "all good")) ;=> "all good"`), and pairing it is exactly what
// the flag is for. `seen` guards the walk because the machine shares
// transformed subtrees between parents, and a naive recursion revisits
// them exponentially.
fn collect_nested(arena &reader.Arena, id blip.NodeId, lines []string, parent_line int, top_last int, mut out []NestedExpect, mut seen map[blip.NodeId]bool) {
	if id in seen {
		return
	}
	seen[id] = true
	own_line := arena.node(id).line
	for kid in arena.kids(id) {
		d := arena.node(kid)
		if d.tag == .quoted || d.tag == .quasi {
			for sub in arena.kids(kid) {
				sd := arena.node(sub)
				if sd.tag == .unquote || sd.tag == .unquote_splice {
					collect_nested(arena, sub, lines, d.line, top_last, mut out, mut seen)
				}
			}
			continue
		}
		if (d.tag == .list || d.tag.is_collection()) && d.line != own_line {
			kk := arena.kids(kid)
			if kk.len > 0 {
				h := arena.node(kk[0])
				if h.tag == .sym && h.value in ['print', 'println', 'display'] {
					want := expectation(lines, d.line)
					if want != '' {
						out << NestedExpect{d.line, want, h.value}
					}
				} else if h.tag == .sym && h.value in ['quote', 'quasiquote'] {
					continue
				} else if d.line != top_last {
					want := expectation(lines, d.line)
					if want != '' {
						out << NestedExpect{d.line, want, ''}
					}
				}
			}
		}
		collect_nested(arena, kid, lines, own_line, top_last, mut out, mut seen)
	}
}

// pair_nested runs the --nested comparison for one top-level form. A nested
// print arrow is TRUE when it names either what the print wrote (its
// fragment, in order) or what the print answered (usually nil): `;=> nil`
// after a println can only mean the value, `;=> "all good"` can only mean
// the fragment, and the flag accepts either true reading. An arrow false
// under both is stale and fails with the line attached. Extra fragments
// (prints without their own arrow) are fine -- the top-level check already
// compared the join. A nested print with no fragment means a branch did not
// run, and any other nested arrow is decorative by construction, so both
// fail with the line attached.
fn pair_nested(mut s TestSuite, path string, found []NestedExpect, frags []string, top_val string) {
	mut fi := 0
	for ne in found {
		s.checks++
		if ne.head == '' {
			s.fails++
			eprintln('${path}:${ne.line}: nested expectation here is documentation, not a test (--nested only checks print/println/display)')
			continue
		}
		if fi >= frags.len {
			s.fails++
			eprintln('${path}:${ne.line}: nested ${ne.head} printed nothing (a branch that did not run has no fragment to compare)')
			continue
		}
		if frags[fi] == ne.want || top_val == ne.want {
			fi++
			continue
		}
		s.check(path, ne.line, ne.want, frags[fi])
		fi++
	}
}

fn run_tests_nested(args []string) int {
	mut nested := false
	mut paths := []string{}
	for a in args {
		if a == '--nested' {
			nested = true
		} else {
			paths << a
		}
	}
	if paths.len == 0 {
		eprintln('blip: test needs a file')
		eprintln('run `blip help test` for usage')
		return 2
	}
	return run_tests(paths, nested)
}

fn run_tests(paths []string, nested bool) int {
	$if wasm32 {
		println('blip: test not available in wasm build')
		return 1
	} $else {
		mut s := TestSuite{}
		for path in paths {
			need_blip_ext(path) or {
				eprintln(err.msg())
				s.fails++
				continue
			}
			src := os.read_file(path) or {
				eprintln('blip: cannot read ${path}')
				s.fails++
				continue
			}
			// Read the diagnostics first, on a scratch arena, so a broken file is
			// reported as a syntax error rather than half-evaluated. The forms then
			// go into the MACHINE's arena, because a NodeId means nothing in any
			// other: evaluating nodes from a different arena reads arbitrary memory.
			probe := reader.read_all(src)
			if probe.diags.len > 0 {
				d := probe.diags[0]
				eprintln('${path}:${d.line}:${d.col}: ${d.msg}')
				s.fails++
				continue
			}
			h := host.new_capture()
			std := std_path()
			if std != '' {
				// The capture host serves NO files until it is given one, and the
				// standard library is loaded through the host like anything else.
				// Without this the prelude silently fails and every expectation in
				// the file is checked against a machine with no names in it.
				std_src := os.read_file(std) or { '' }
				if std_src != '' {
					h.give_file(std, std_src)
				}
			}
			mut m := machine.new_standalone(h)
			if std != '' {
				m.load(std) or { eprintln('blip: cannot load the standard library: ${err.msg()}') }
			}
			if !auto_manifest(mut m) {
				s.fails++
				continue
			}
			m.source = path
			forms := m.arena.read_source(src, path)
			lines := src.split('\n')
			for id in forms.forms {
				d := m.arena.node(id)
				want := expectation(lines, d.line)
				// What the form PRINTED is the answer when it printed anything.
				// `(print (greeting "world"))` returns nil, so comparing the value
				// against a `;=> "Hello, world."` expectation is comparing nil
				// against a string and calling that a failure -- while the program
				// printed exactly what it was documented to print. The machine
				// already routes print through the host, so the output is here.
				// --nested (roadmap A1.3, opt-in) collects here, BEFORE evaluation:
				// the machine rewrites match/cond/let bodies as it runs, and
				// the rewritten nodes carry no source lines, so a post-eval
				// walk would see nothing to attribute.
				mut nested_found := []NestedExpect{}
				if nested {
					mut seen := map[blip.NodeId]bool{}
					top_last := 1 + src[..d.origin.end].count('\n')
					collect_nested(m.arena, id, lines, d.line, top_last, mut nested_found, mut seen)
				}
				before := m.out.len
				v := m.eval_one(id) or {
					if want.len > 0 {
						s.check(path, d.line, want, 'error: ${err.msg()}')
					}
					if nested {
						pair_nested(mut s, path, nested_found, m.out[before..], '')
					}
					continue
				}
				// The top form's own answer, for the dual-meaning last line
				// below: what it printed when it printed, else its value.
				printed := m.out.len > before
				top_got := if printed {
					m.out[before..].join('').trim_right('\n').trim_space()
				} else {
					printer.write(v)
				}
				top_val := printer.write(v)
				if want.len > 0 {
					s.checks++
					s.check(path, d.line, want, top_got)
				}
				// --nested (roadmap A1.3, opt-in): nested print-family forms
				// carrying their own `;=>` are checked per-fragment, in
				// source order, against what the top-level form printed.
				// Anything else nested with a `;=>` fails LOUDLY, naming
				// the line: that is the list of what still blocks the
				// default flip, and why the default stays top-level-only.
				if nested {
					pair_nested(mut s, path, nested_found, m.out[before..], top_val)
				}
			}
		}
		if s.checks == 0 {
			println('${paths.len} file(s) ran, 0 expectations')
			return if s.fails > 0 { 1 } else { 0 }
		}
		if s.fails > 0 {
			println('${s.checks} expectations, ${s.fails} FAILED')
			return 1
		}
		println('${s.checks} expectations passed')
		return 0
	}
}

// ---- check ---------------------------------------------------------------

// check_files runs `blip check` over files: parse each one, run the static
// checker for erased annotations, and report every mismatch as
// `path:line:col: message`. Nothing is evaluated, so checking is safe on
// files that would misbehave at run time. Unknown names are not errors --
// the checker judges only what it has signatures for -- so a reader
// diagnostic is the one hard failure: without a parse there is nothing to
// check against.
fn check_files(paths []string) int {
	$if wasm32 {
		println('blip: check not available in wasm build')
		return 1
	} $else {
		mut fails := 0
		for path in paths {
			need_blip_ext(path) or {
				eprintln(err.msg())
				fails++
				continue
			}
			src := os.read_file(path) or {
				eprintln('blip: cannot read ${path}')
				fails++
				continue
			}
			h := host.new_capture()
			mut m := machine.new_standalone(h)
			if !auto_manifest(mut m) {
				fails++
				continue
			}
			forms := m.arena.read_source(src, path)
			if forms.diags.len > 0 {
				d := forms.diags[0]
				println('${path}:${d.line}:${d.col}: syntax: ${d.msg}')
				fails++
				continue
			}
			for dg in m.check_source(forms.forms) {
				println('${path}:${dg.line}:${dg.col}: ${dg.msg}')
				fails++
			}
		}
		if fails > 0 {
			eprintln('blip check: ${fails} problem(s)')
			return 1
		}
		return 0
	}
}

// ---- new / init ------------------------------------------------------------

fn main_blip(name string) string {
	return '; ${name} -- a blip program.
;
; Run it with:  blip run main.blip
; Check it with: blip test main.blip

(def (greet who)
  (string-append "hello, " who "!"))

; print writes the line and returns nil -- but `blip test` compares what the
; form PRINTED when it printed anything (see run_tests), so the expectation
; names the printed line, not the value.
(print (greet "world"))   ;=> "hello, world!"

; A value form with no expectation: merely run, not checked.
(greet "world")
'
}

// clean_module_name keeps a directory name usable as a `(module ...)`
// symbol: letters, digits, `-` and `_` survive, spaces become `-`, the
// rest is dropped. An empty result means the name said nothing at all,
// so it becomes `app`.
fn clean_module_name(raw string) string {
	mut sb := []u8{}
	for c in raw.bytes() {
		if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
			|| c == `-` || c == `_` {
			sb << c
		} else if c == ` ` {
			sb << `-`
		}
	}
	if sb.len == 0 {
		return 'app'
	}
	return sb.bytestr()
}

// scaffold_into writes the missing project files into dir without touching
// what is there: `new` starts from an absent dir, `init` tops up an
// existing one, and neither ever overwrites a file the user owns.
fn scaffold_into(dir string, name string) int {
	$if wasm32 {
		println('blip: scaffold not available in wasm build')
		return 1
	} $else {
		mod := clean_module_name(name)
		files := {
			'main.blip':  main_blip(name)
			'README.md':  '# ${name}\n\nA blip project.\n\n    blip run main.blip\n    blip test main.blip\n'
			'.gitignore': 'blip\n*.exe\nblip_modules/\n'
			'blip.mod':   '; ${name} -- blip module manifest.\n(module ${mod})\n(blip 2)\n'
		}
		mut made := 0
		mut names := files.keys()
		names.sort()
		for f in names {
			path := os.join_path(dir, f)
			if os.exists(path) {
				println('  kept ${f}')
				continue
			}
			os.write_file(path, files[f]) or {
				eprintln('blip: cannot write ${f}: ${err.msg()}')
				return 1
			}
			println('  created ${f}')
			made++
		}
		if made == 0 {
			println('${dir} is already a blip project')
		}
		return 0
	}
}

fn scaffold(name string) int {
	$if wasm32 {
		println('blip: new not available in wasm build')
		return 1
	} $else {
		if os.exists(name) {
			eprintln('blip: ${name} already exists')
			return 1
		}
		os.mkdir_all(name) or {
			eprintln('blip: cannot create ${name}: ${err.msg()}')
			return 1
		}
		println('created ${name}/')
		return scaffold_into(name, name)
	}
}

// ---- install / env --------------------------------------------------------

// install_tool installs a package's runnable tools onto PATH (Track G3):
// the package lands in blip_modules/ like any other, and each tool becomes
// a wrapper in .blip/bin/ around `blip run`. Add that dir to PATH once and
// every installed tool is a command.
fn install_tool(spec string) int {
	$if wasm32 {
		println('blip: install not available in wasm build')
		return 1
	} $else {
		tools := pkg.install_tool('.', spec) or {
			eprintln(err.msg())
			return 1
		}
		for t in tools {
			println('installed ${t.name} -> ${t.sh}')
		}
		println('add .blip/bin to PATH to run them')
		return 0
	}
}

// env_cmd prints the project facts go-style, one `key value` per line
// (Track G7): versions, paths, mirror, workspace. Stable order, so the
// golden test can compare it line for line after normalizing the root.
fn env_cmd() int {
	$if wasm32 {
		println('blip: env not available in wasm build')
		return 1
	} $else {
		root := os.getwd()
		println('blip.version ${version}')
		println('blip.dir ${root}')
		mod_path := os.join_path(root, 'blip.mod')
		if !os.exists(mod_path) {
			println('blip.manifest none')
			println('blip.module none')
		} else {
			println('blip.manifest ${mod_path}')
			src := os.read_file(mod_path) or { '' }
			m := manifest.parse(src) or {
				println('blip.module (unreadable: ${err.msg()})')
				println('blip.workspace none')
				println('blip.lock ${os.join_path(root, lock_name)}')
				println('blip.modules ${os.join_path(root, modules_dir)}')
				println('blip.bin ${os.join_path(os.join_path(root, '.blip'), 'bin')}')
				mirror := os.getenv('BLIP_PKG_MIRROR')
				println('blip.mirror ${if mirror == '' { 'default (github)' } else { mirror }}')
				return 0
			}
			println('blip.module ${m.name}')
			if m.workspace.len == 0 {
				println('blip.workspace none')
			} else {
				println('blip.workspace ${m.workspace.join(',')}')
			}
		}
		println('blip.lock ${os.join_path(root, lock_name)}')
		println('blip.modules ${os.join_path(root, modules_dir)}')
		println('blip.bin ${os.join_path(os.join_path(root, '.blip'), 'bin')}')
		mirror := os.getenv('BLIP_PKG_MIRROR')
		println('blip.mirror ${if mirror == '' { 'default (github)' } else { mirror }}')
		return 0
	}
}

// ---- doc -----------------------------------------------------------------

// doc_file extracts `;;` doc comments preceding definitions and prints them
// as Markdown. A `;;` block immediately above a `(define ...)`, `(def ...)`,
// `(defmacro ...)` or `(struct ...)` form becomes that entry's documentation.
fn doc_file(path string) int {
	$if wasm32 {
		println('blip: doc not available in wasm build')
		return 1
	} $else {
		need_blip_ext(path) or {
			eprintln(err.msg())
			return 1
		}
		src := os.read_file(path) or {
			eprintln('blip: cannot read ${path}: ${err.msg()}')
			return 1
		}
		lines := src.split('\n')
		mut doc_lines := []string{}
		for _, line in lines {
			trimmed := line.trim_space()
			if trimmed.starts_with(';;') {
				doc_lines << trimmed[2..].trim_space()
				continue
			}
			// A definition line: flush the accumulated doc as an entry.
			is_def := trimmed.starts_with('(def ') || trimmed.starts_with('(defmacro')
				|| trimmed.starts_with('(struct')
			if is_def {
				// Extract the name: second token after the opening paren.
				mut name := ''
				mut rest := trimmed.trim_left('(').trim_space()
				// skip keyword
				space_idx := rest.index(' ') or { -1 }
				if space_idx >= 0 {
					rest = rest[space_idx + 1..].trim_space()
				}
				// name is the next token, possibly parenthesized signature
				if rest.starts_with('(') {
					mut end := rest.index(')') or { -1 }
					if end >= 0 {
						sig := rest[1..end]
						parts := sig.split(' ')
						if parts.len > 0 {
							name = parts[0]
						}
						println('## ' + name)
						println('')
						println('```blip')
						println('(${name} ${parts[1..].join(' ')})')
						println('```')
						println('')
					}
				} else {
					mut end := rest.index(' ') or { rest.len }
					if end < 0 { end = rest.len }
					name = rest[..end]
					println('## ' + name)
					println('')
				}
				// Print doc text (skip empty leading lines).
				mut started := false
				for dl in doc_lines {
					if dl == '' {
						if started { println('') }
						continue
					}
					started = true
					println(dl)
				}
				if started { println('') }
				doc_lines = []
				continue
			}
			// Non-doc, non-def line resets the doc buffer (blank lines keep it).
			if trimmed == '' {
				// keep doc_lines (blank line inside doc is already stored as '')
			} else {
				doc_lines = []
			}
		}
		// Trailing doc with no definition: ignore.
		return 0
	}
}

// ---- fmt ----------------------------------------------------------------

// fmt_file pretty-prints a blip source file. With write=true it overwrites
// the file; otherwise it prints to stdout.
// ---- migrate -------------------------------------------------------------

// migrate_cmd runs `blip migrate [--check] <file|dir>`: every .lip/.blip
// file is rewritten and every .lip renamed to .blip unless --check is set
// (report-only, exit 1 if anything would change). blip.mod stamping and
// version enforcement land with the module-manifest change, next.
fn migrate_cmd(target string, check_only bool) int {
	$if wasm32 {
		println('blip: migrate not available in wasm build')
		return 1
	} $else {
		reports := migrate.migrate_path(target, check_only) or {
			eprintln(err.msg())
			return 1
		}
		mut changed := 0
		mut code := 0
		for r in reports {
			for w in r.warnings {
				println('${r.path}: ${w}')
			}
			if r.changed {
				changed++
				if check_only {
					if r.renamed {
						println('${r.path}: would migrate and rename to .blip')
					} else {
						println('${r.path}: would migrate')
					}
				} else {
					if r.renamed {
						println('${r.path}: migrated and renamed to .blip')
					} else {
						println('${r.path}: migrated')
					}
				}
			}
		}
		if check_only && changed > 0 {
			code = 1
		}
		if reports.len == 0 {
			println('blip migrate: nothing to migrate under ${target}')
		}
		return code
	}
}

fn fmt_file(path string, write bool) int {
	$if wasm32 {
		println('blip: fmt not available in wasm build')
		return 1
	} $else {
		need_blip_ext(path) or {
			eprintln(err.msg())
			return 1
		}
		src := os.read_file(path) or {
			eprintln('blip: cannot read ${path}: ${err.msg()}')
			return 1
		}
		res := reader.read_all(src)
		if res.diags.len > 0 {
			d := res.diags[0]
			eprintln('${path}:${d.line}:${d.col}: ${d.msg}')
			return 1
		}
		mut sb := strings.new_builder(res.forms.len * 64)
		for i, id in res.forms {
			if i > 0 {
				sb.write_string('\n\n')
			}
			sb.write_string(printer.pp_form(res.arena, id, 0))
		}
		sb.write_string('\n')
		out := sb.str()
		if write {
			os.write_file(path, out) or {
				eprintln('blip: cannot write ${path}: ${err.msg()}')
				return 1
			}
		} else {
			print(out)
		}
		return 0
	}
}

// ---- doc -----------------------------------------------------------------

// doc_file extracts `;;` doc comments preceding definitions and prints them
// as Markdown.
// ---- build ---------------------------------------------------------------

// compile_one reads one file and returns its compilation result. The refusal
// rule lives with the caller: `build` treats a blocked form as a hard error,
// while `emit-js` prints the partial module and reports the refusal alongside
// it, so a refusal is visible rather than a silent `undefined`.
fn compile_one(path string) !emit.Result {
	need_blip_ext(path)!
	src := os.read_file(path) or { return error('blip: cannot read ${path}') }
	return emit.compile_program(src) or { return error('blip: ${path}: ${err.msg()}') }
}

// build_file compiles a blip program to a JavaScript module and writes it
// to out. This is the first half of `blip build`: a single self-contained
// .js file that runs under node. A .wasm backend is the next step (P8).
fn build_file(input string, out string) int {
	$if wasm32 {
		println('blip: build not available in wasm build')
		return 1
	} $else {
		res := compile_one(input) or {
			eprintln(err.msg())
			return 1
		}
		if res.blocked.len > 0 {
			eprintln('blip: ${input}: not emitted: ${res.blocked.join(', ')}')
			return 1
		}
		os.write_file(out, res.js) or {
			eprintln('blip: cannot write ${out}: ${err.msg()}')
			return 1
		}
		println('built ${out} (${res.js.len} bytes)')
		return 0
	}
}

// ---- pkg ----------------------------------------------------------------
//
// `blip pkg` is the project-facing half of Track G; the mechanism lives in
// `blip.pkg` so it stays unit-testable, and these wrappers only translate
// results into messages and exit codes. Three commands, three promises:
// `install` reproduces the lock, `update` re-resolves it, `verify` checks
// the tree against it.

const lock_name = 'blip.lock'

const modules_dir = 'blip_modules'

fn pkg_command(args []string) int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		if args.len == 0 {
			eprintln('blip: pkg needs a subcommand')
			eprintln('  blip pkg install [owner/repo]  install the lock, or one package')
			eprintln('  blip pkg update                 re-resolve ./blip.mod to fresh pins')
			eprintln('  blip pkg verify                 check the tree against the lock')
			eprintln('  blip pkg list                   what is installed')
			eprintln('  blip pkg remove <name>          remove a package')
			eprintln('  blip pkg why <name>             who depends on it')
			return 2
		}
		sub := args[0]
		match sub {
			'install' {
				// No spec installs the locked universe (the clean-room path);
				// a spec adds one package ad hoc, no manifest needed.
				if args.len < 2 {
					return pkg_install_all()
				}
				return pkg_install(args[1])
			}
			'update' {
				return pkg_update()
			}
			'verify' {
				return pkg_verify()
			}
			'list' {
				return pkg_list()
			}
			'remove' {
				if args.len < 2 {
					eprintln('blip: pkg remove needs <owner/repo>')
					return 2
				}
				return pkg_remove(args[1])
			}
			'why' {
				if args.len < 2 {
					eprintln('blip: pkg why needs <owner/repo>')
					return 2
				}
				return pkg_why(args[1])
			}
			else {
				eprintln('blip: unknown pkg subcommand `${sub}`')
				eprintln('run `blip help pkg` for usage')
				return 2
			}
		}
	}
}

fn pkg_install(spec string) int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		p := pkg.install_one('.', spec) or {
			eprintln(err.msg())
			return 1
		}
		short := if p.sha.len >= 7 { p.sha[..7] } else { p.sha }
		println('installed ${p.name} at ${short} (${p.ref})')
		return 0
	}
}

// pkg_install_all reproduces the locked universe (G5 clean-room path): no
// resolving, just exact-sha checkouts plus checksum verification.
fn pkg_install_all() int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		pins := pkg.install('.') or {
			eprintln(err.msg())
			return 1
		}
		_ = pins
		locked := pkg.read_lock('.')
		println('installed ${locked.len} package(s) from ${lock_name}')
		return 0
	}
}

// pkg_update re-resolves ./blip.mod (plus workspace members) to fresh pins
// and installs them (G1). The lock is rewritten sorted and deterministic.
fn pkg_update() int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		pins := pkg.update('.') or {
			eprintln(err.msg())
			return 1
		}
		if pins.len == 0 {
			println('nothing to update')
			return 0
		}
		for p in pins {
			short := if p.sha.len >= 7 { p.sha[..7] } else { p.sha }
			println('pinned ${p.name} at ${short} (${p.ref})')
		}
		return 0
	}
}

// pkg_verify checks the installed tree against the lock checksums (G2).
fn pkg_verify() int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		mismatches := pkg.verify('.') or {
			eprintln(err.msg())
			return 1
		}
		if mismatches.len > 0 {
			for m in mismatches {
				eprintln(m)
			}
			return 1
		}
		println('all packages verified')
		return 0
	}
}

fn pkg_list() int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		installed := pkg.read_lock('.')
		if installed.len == 0 {
			println('no packages installed')
			return 0
		}
		for l in installed {
			dir := os.join_path(os.join_path(modules_dir, os.dir(l.name)), os.file_name(l.name))
			mark := if os.is_dir(dir) { '' } else { '  (missing from ${modules_dir}/)' }
			short := if l.sha.len >= 7 { l.sha[..7] } else { l.sha }
			println('${l.name}  ${l.ref}  ${short}${mark}')
		}
		return 0
	}
}

fn pkg_remove(spec string) int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		name := pkg.remove_one('.', spec) or {
			eprintln(err.msg())
			return 1
		}
		println('removed ${name}')
		return 0
	}
}

// pkg_why reports who depends on a package (Track G7): the locked pin if
// there is one, then every manifest that requests it and what each asked
// for. A name nobody requests is an error, not an empty answer, because an
// empty answer reads as "nothing" and hides a typo.
fn pkg_why(spec string) int {
	$if wasm32 {
		println('blip: pkg not available in wasm build')
		return 1
	} $else {
		u := pkg.collect_universe('.') or {
			eprintln(err.msg())
			return 1
		}
		mut name := spec
		if name !in u.reqs {
			mut hits := []string{}
			for n in u.dep_names() {
				if os.file_name(n) == spec {
					hits << n
				}
			}
			if hits.len != 1 {
				eprintln('blip: no manifest requires ${spec}')
				return 1
			}
			name = hits[0]
		}
		if p := pkg.pin_of(pkg.read_lock('.'), name) {
			println('${name} ${p.ref}')
		} else {
			println(name)
		}
		for f in u.reqs[name] {
			println('  ${f.requester} wants ${f.req}')
		}
		return 0
	}
}

// ---- toolchain ------------------------------------------------------------
//
// `blip toolchain` manages blip itself (Track G4): versions live in
// <home>/versions/<version>/, <home>/bin/blip is the shim that resolves
// the version per directory, and `.blip-version` pins a project.

fn toolchain_command(args []string) int {
	$if wasm32 {
		println('blip: toolchain not available in wasm build')
		return 1
	} $else {
		if args.len == 0 {
			eprintln('blip: toolchain needs a subcommand')
			eprintln('  blip toolchain install <version>  fetch and unpack a release')
			eprintln('  blip toolchain list               installed versions')
			eprintln('  blip toolchain use <version>      pin this directory')
			eprintln('  blip toolchain default <version>  set the fallback')
			eprintln('  blip toolchain shim               install the bin/ shims')
			eprintln('  blip toolchain remove <version>   delete a version')
			return 2
		}
		sub := args[0]
		match sub {
			'install' {
				if args.len < 2 {
					eprintln('blip: toolchain install needs a version')
					return 2
				}
				return toolchain_install(args[1])
			}
			'list' {
				return toolchain_list()
			}
			'use' {
				if args.len < 2 {
					eprintln('blip: toolchain use needs a version')
					return 2
				}
				toolchain.use_version('.', args[1]) or {
					eprintln(err.msg())
					return 1
				}
				println('pinned ${args[1]} in ${os.getwd()}')
				return 0
			}
			'default' {
				if args.len < 2 {
					eprintln('blip: toolchain default needs a version')
					return 2
				}
				toolchain.write_default(args[1]) or {
					eprintln(err.msg())
					return 1
				}
				println('default is ${args[1]}')
				return 0
			}
			'shim' {
				return toolchain_shim()
			}
			'remove' {
				if args.len < 2 {
					eprintln('blip: toolchain remove needs a version')
					return 2
				}
				toolchain.remove_version(args[1]) or {
					eprintln(err.msg())
					return 1
				}
				println('removed ${args[1]}')
				return 0
			}
			else {
				eprintln('blip: unknown toolchain subcommand `${sub}`')
				eprintln('run `blip help toolchain` for usage')
				return 2
			}
		}
	}
}

// toolchain_install fetches a release artifact and assembles it into
// <home>/versions/<version>/. The artifact comes from $BLIP_RELEASE_BASE
// when set (a directory holding v<version>/ files, for offline fixtures
// and mirrors), else the github release download. The binary layout it
// starts from is the current one -- a bare binary -- so lib/ and programs/
// snapshot from the running blip beside it.
fn toolchain_install(version string) int {
	$if wasm32 {
		println('blip: toolchain not available in wasm build')
		return 1
	} $else {
		base := os.getenv('BLIP_RELEASE_BASE')
		file := toolchain.artifact_file()
		url := toolchain.release_url(version)
		tmp := os.join_path(os.temp_dir(), 'blip_toolchain_artifact')
		os.rm(tmp) or {}
		if base != '' && !base.contains('://') {
			src := os.join_path(os.join_path(base, 'v' + version), file)
			if !os.exists(src) {
				eprintln('blip: no artifact at ${src}')
				return 1
			}
			src_bytes := os.read_file(src) or {
				eprintln('blip: cannot read ${src}: ${err.msg()}')
				return 1
			}
			os.write_file(tmp, src_bytes) or {
				eprintln('blip: cannot stage ${src}: ${err.msg()}')
				return 1
			}
		} else {
			r := os.exec(['curl', '-fsSL', '-o', tmp, url])
			if r.exit_code != 0 {
				eprintln('blip: cannot download ${url}')
				eprintln(r.output.trim_space())
				return 1
			}
		}
		dst := toolchain.install_from_artifact(version, tmp, resource_path('lib'),
			resource_path('programs')) or {
			eprintln(err.msg())
			return 1
		}
		os.rm(tmp) or {}
		println('installed ${version} in ${dst}')
		return 0
	}
}

// toolchain_list shows installed versions, marking the default and the pin
// that applies here (upward search, same as the shim resolves).
fn toolchain_list() int {
	$if wasm32 {
		println('blip: toolchain not available in wasm build')
		return 1
	} $else {
		vs := toolchain.installed_versions()
		if vs.len == 0 {
			println('no toolchains installed')
			return 0
		}
		def := toolchain.read_default() or { '' }
		pinned := toolchain.find_pin(os.getwd()) or { toolchain.Pin{ version: '', file: '' } }
		for v in vs {
			mut marks := []string{}
			if v == def {
				marks << 'default'
			}
			if v == pinned.version && pinned.version != '' {
				marks << 'pinned here'
			}
			suffix := if marks.len > 0 { ' (' + marks.join(', ') + ')' } else { '' }
			println('${v}${suffix}')
		}
		return 0
	}
}

// toolchain_shim writes the bin/ shims with this home embedded, so the one
// dir on PATH resolves every project to its version.
fn toolchain_shim() int {
	$if wasm32 {
		println('blip: toolchain not available in wasm build')
		return 1
	} $else {
		home := toolchain.home()
		bin := toolchain.bin_dir()
		os.mkdir_all(bin) or {
			eprintln('blip: cannot create ${bin}: ${err.msg()}')
			return 1
		}
		sh := os.join_path(bin, 'blip')
		bat := os.join_path(bin, 'blip.bat')
		os.write_file(sh, toolchain.shim_sh(home, toolchain.binary_name())) or {
			eprintln('blip: cannot write ${sh}: ${err.msg()}')
			return 1
		}
		os.chmod(sh, 0o755) or {}
		os.write_file(bat, toolchain.shim_bat(home, toolchain.binary_name())) or {
			eprintln('blip: cannot write ${bat}: ${err.msg()}')
			return 1
		}
		println('shims in ${bin}; add it to PATH')
		return 0
	}
}
