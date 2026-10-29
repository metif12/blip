module main

import os
import vlib.blip
import vlib.blip.emit
import vlib.blip.host
import vlib.blip.lsp
import vlib.blip.machine
import vlib.blip.printer
import vlib.blip.reader
import vlib.blip.repl

// blip: a Lisp dialect implemented in V.
//
//   blip                      a REPL
//   blip repl                 the same REPL, spelled out
//   blip run <file.lip> ...   evaluate files, in order, in one machine
//   blip <file.lip>           shorthand for `run`
//   blip test <file.lip> ...  evaluate and check the `;=>` expectations
//   blip lsp                  serve the language server over stdio
//   blip new <name>           scaffold a project
//   blip doc <file.lip>       generate documentation from doc comments
//   blip pkg <sub>            install, list and remove packages
//   blip version | help       about, and about a command
//
// No arguments starts a REPL because the CLI already requires a file for
// anything else, so the default costs nothing and is the thing a person wants
// most often once the language is installed.

const version = '0.1.0'

fn exit_code(code int) {
	exit(code)
}

fn usage() {
	eprintln('blip ${version} -- a Lisp dialect implemented in V

usage:
  blip                      start the REPL
  blip repl                 start the REPL
  blip run <file.lip> ...   evaluate files in order, in one machine
  blip <file.lip>           shorthand for `blip run`
  blip test <file.lip> ...  evaluate and check the `;=>` expectations
  blip lsp                  serve the language server over stdio
  blip new <name>           scaffold a project
  blip doc <file.lip>       generate documentation from doc comments
  blip pkg install <repo>   install a package from GitHub
  blip pkg list             list installed packages
  blip pkg remove <name>    remove an installed package
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
			println('blip run <file.lip> ... -- evaluate files

Several files are evaluated IN ORDER IN ONE MACHINE, so a definition made in the
first is visible in the second. That is the difference between this and running
each file separately.

The standard library is loaded first, so print and string-upcase are names
rather than something every file has to require.

blip somefile.lip is a shorthand for blip run somefile.lip.')
		}
		'test' {
			println('blip test <file.lip> ... -- evaluate and check expectations

A ;=> expected comment on the same line as a form is an expectation: the form is
evaluated and its value is compared, as text, against what follows the arrow. A
mismatch is reported with the line, the value and the expectation.

  (define (double x) (* 2 x))
  (double 21)   ;=> 42

Exit status is 0 when every expectation held and 1 when any did not, so this
works as a test gate from CI. Files without expectations are merely run.')
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

The rules live in programs/lint_commit.lip, which is also runnable on its
own: blip run programs/lint_commit.lip')
		}
		'pkg' {
			println('blip pkg -- package management

  blip pkg install <owner/repo>[@ref]   clone into blip_modules/ and record it
  blip pkg list                         what is installed, and from where
  blip pkg remove <name>                delete an installed package

A package is a git repository holding .lip files. install clones it into
blip_modules/<owner>/<repo>, records it in blip.lock with the commit that was
taken, and every later run sees it.

Once installed, a package is reachable with (import <repo>), which loads its
blip.lip entry point into the running machine -- the same thing use does for a
file, with the path resolved through blip_modules/ instead of by hand.')
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
fn std_path() string {
	exe := os.executable()
	dir := os.dir(exe)
	// The binary sits in the repository root when built with the documented
	// command, and one level up when it is put in tools/ during development.
	for candidate in [os.join_path(dir, 'lib${os.path_separator}std.lip'),
		os.join_path(os.dir(dir), 'lib${os.path_separator}std.lip')] {
		if os.exists(candidate) {
			return candidate
		}
	}
	return ''
}

fn programs_path(name string) string {
	exe := os.executable()
	dir := os.dir(exe)
	for candidate in [os.join_path(dir, 'programs${os.path_separator}${name}'),
		os.join_path(os.dir(dir), 'programs${os.path_separator}${name}')] {
		if os.exists(candidate) {
			return candidate
		}
	}
	return ''
}
fn run_files(paths []string) int {
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
	for path in paths {
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

// ---- emit-js -------------------------------------------------------------

// The standard library goes into every emitted module, in front of the program,
// because `blip run` loads it in front of the file too. Without it the emitted
// JavaScript references `lookup-sym`, `validate`, `sqrt` and every other stdlib
// name as identifiers nothing defines -- the program emits cleanly and then dies
// at the first call. The gate knows the same thing, and both go through
// `compile_program` so the knowledge is not in two places to drift.
fn emit_js(paths []string) int {
	mut code := 0
	for path in paths {
		src := os.read_file(path) or {
			eprintln('blip: cannot read ${path}')
			code = 1
			continue
		}
		res := emit.compile_program(src) or {
			eprintln('blip: ${path}: ${err.msg()}')
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

fn start_repl() int {
	mut r := repl.new(&host.ConsoleHost{})
	std := std_path()
	if std != '' {
		r.machine.load(std) or {
			eprintln('blip: cannot load the standard library: ${err.msg()}')
		}
	}
	return r.run()
}

fn main() {
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
			exit_code(run_tests(args[1..]))
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
		'lint' {
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
			prog := programs_path('lint_commit.lip')
			if prog == '' {
				eprintln('blip: cannot find programs/lint_commit.lip')
				exit_code(2)
				return
			}
			exit_code(run_files([prog]))
		}
		'vet' {
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
			prog := programs_path('lint_commit.lip')
			if prog == '' {
				eprintln('blip: cannot find programs/lint_commit.lip')
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
		'doc' {
			if args.len < 2 {
				eprintln('blip: doc needs a file')
				eprintln('run `blip help doc` for usage')
				exit_code(2)
				return
			}
			exit_code(doc_file(args[1]))
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
		'pkg' {
			exit_code(pkg_command(args[1..]))
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
			// Allow `blip file.lip` as a shorthand for `blip run file.lip`.
			// A word that is neither a subcommand nor a file fails both ways,
			// and saying only "cannot read" sends someone who mistyped a
			// subcommand hunting for a file that was never theirs.
			if !os.exists(args[0]) && !args[0].ends_with('.lip') {
				eprintln('blip: ${args[0]} is neither a subcommand nor a file')
				eprintln('run `blip help` for subcommands, or `blip run <file.lip>`')
				exit_code(2)
			}
			exit_code(run_files(args))
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

fn run_tests(paths []string) int {
	mut s := TestSuite{}
	for path in paths {
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
		m.source = path
		forms := m.arena.read_forms(src)
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
			before := m.out.len
			v := m.eval_one(id) or {
				if want.len > 0 {
					s.check(path, d.line, want, 'error: ${err.msg()}')
				}
				continue
			}
			if want.len > 0 {
				s.checks++
				if m.out.len > before {
					printed := m.out[before..].join('').trim_right('\n').trim_space()
					s.check(path, d.line, want, printed)
					continue
				}
				s.check(path, d.line, want, printer.write(v))
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

// ---- new ----------------------------------------------------------------

fn main_lip(name string) string {
	return '; ${name} -- a blip program.
;
; Run it with:  blip run main.lip
; Check it with: blip test main.lip

(define (greet who)
  (string-append "hello, " who "!"))

; print writes the line and returns nothing, so the value of the form is nil.
; The expectation below is checked by `blip test`, not by the reader.
(print (greet "world"))   ;=> nil

; A value form: this one is what the expectation compares against.
(greet "world")
'
}

fn scaffold(name string) int {
	if os.exists(name) {
		eprintln('blip: ${name} already exists')
		return 1
	}
	os.mkdir_all(name) or {
		eprintln('blip: cannot create ${name}: ${err.msg()}')
		return 1
	}
	os.write_file(os.join_path(name, 'main.lip'), main_lip(name)) or {
		eprintln('blip: cannot write main.lip: ${err.msg()}')
		return 1
	}
	readme := '# ${name}\n\nA blip project.\n\n    blip run main.lip\n    blip test main.lip\n'
	os.write_file(os.join_path(name, 'README.md'), readme) or {
		eprintln('blip: cannot write README.md: ${err.msg()}')
		return 1
	}
	os.write_file(os.join_path(name, '.gitignore'), 'blip\n*.exe\nblip_modules/\n') or {
		eprintln('blip: cannot write .gitignore: ${err.msg()}')
		return 1
	}
	println('created ${name}/')
	println('  main.lip')
	println('  README.md')
	println('  .gitignore')
	return 0
}

// ---- doc -----------------------------------------------------------------

// doc_file extracts `;;` doc comments preceding definitions and prints them
// as Markdown. A `;;` block immediately above a `(define ...)`, `(def ...)`,
// `(defmacro ...)` or `(struct ...)` form becomes that entry's documentation.
fn doc_file(path string) int {
	src := os.read_file(path) or {
		eprintln('blip: cannot read ${path}: ${err.msg()}')
		return 1
	}
	lines := src.split('\n')
	mut doc_lines := []string{}
	for i, line in lines {
		trimmed := line.trim_space()
		if trimmed.starts_with(';;') {
			doc_lines << trimmed[2..].trim_space()
			continue
		}
		// A definition line: flush the accumulated doc as an entry.
		is_def := trimmed.starts_with('(define') || trimmed.starts_with('(def ') || trimmed.starts_with('(defmacro') || trimmed.starts_with('(struct')
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

// ---- fmt ----------------------------------------------------------------

// fmt_file pretty-prints a blip source file. With write=true it overwrites
// the file; otherwise it prints to stdout.
fn fmt_file(path string, write bool) int {
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
	mut out := ''
	for i, id in res.forms {
		if i > 0 {
			out += '\n\n'
		}
		out += pp_form(res.arena, id, 0)
	}
	out += '\n'
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

fn pp_form(a &reader.Arena, id reader.NodeId, depth int) string {
	d := a.node(id)
	match d.tag {
		.nil { return 'nil' }
		.bool { return if d.i == 1 { '#t' } else { '#f' } }
		.int { return d.i.str() }
		.float { return d.f.str() }
		.str { return quote_string(d.value) }
		.sym { return d.value }
		.kw { return ':' + d.value }
		.list {
			kids := a.kids(id)
			if kids.len == 0 {
				return '()'
			}
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			line := '(' + parts.join(' ') + ')'
			if line.len <= 80 {
				return line
			}
			mut s := '('
			for i, p in parts {
				if i == 0 {
					s += p
				} else {
					s += '\n' + '  '.repeat(depth + 1) + p
				}
			}
			s += ')'
			return s
		}
		.vector {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			return '[' + parts.join(' ') + ']'
		}
		.table {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1) + ' ' + pp_form(a, kids[ki + 1], depth + 1)
				ki += 2
			}
			return '{' + parts.join(' ') + '}'
		}
		.array {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			return '@[' + parts.join(' ') + ']'
		}
		.bytes {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			return '#(' + parts.join(' ') + ')'
		}
		.quoted {
			kids := a.kids(id)
			if kids.len == 0 {
				return "'()"
			}
			return "'" + pp_form(a, kids[0], depth)
		}
		.quasi {
			kids := a.kids(id)
			if kids.len == 0 {
				return '`()'
			}
			return '`' + pp_form(a, kids[0], depth)
		}
		.unquote {
			kids := a.kids(id)
			if kids.len == 0 {
				return ',()'
			}
			return ',' + pp_form(a, kids[0], depth)
		}
		.unquote_splice {
			kids := a.kids(id)
			if kids.len == 0 {
				return ',@()'
			}
			return ',@' + pp_form(a, kids[0], depth)
		}
		else {
			return '#<datum>'
		}
	}
}

fn quote_string(s string) string {
	mut sb := '"'
	for ch in s.runes() {
		match ch {
			`"` { sb += '\\"' }
			`\\` { sb += '\\\\' }
			`\n` { sb += '\\n' }
			`\r` { sb += '\\r' }
			`\t` { sb += '\\t' }
			else { sb += ch.str() }
		}
	}
	sb += '"'
	return sb
}

// ---- doc -----------------------------------------------------------------

// doc_file extracts `;;` doc comments preceding definitions and prints them
// as Markdown.
// ---- pkg ----------------------------------------------------------------

const lock_name = 'blip.lock'

const modules_dir = 'blip_modules'

struct LockLine {
	name string
	ref  string
	sha  string
}

fn parse_pkg_spec(spec string) (string, string, string) {
	// owner/repo[@ref]
	mut ref := 'HEAD'
	mut path := spec
	at := spec.index('@') or { -1 }
	if at >= 0 {
		path = spec[..at]
		ref = spec[at + 1..]
	}
	slash := path.index('/') or { return '', '', '' }
	owner := path[..slash]
	repo := path[slash + 1..]
	if owner == '' || repo == '' || repo.contains('/') {
		return '', '', ''
	}
	return owner, repo, ref
}

fn read_lock() []LockLine {
	src := os.read_file(lock_name) or { return []LockLine{} }
	mut out := []LockLine{}
	for line in src.split_into_lines() {
		t := line.trim_space()
		if t == '' || t.starts_with('#') {
			continue
		}
		parts := t.split(' ')
		if parts.len < 3 {
			continue
		}
		out << LockLine{
			name: parts[0]
			ref:  parts[1]
			sha:  parts[2]
		}
	}
	return out
}

fn write_lock(lines []LockLine) ! {
	mut sb := '# blip.lock -- installed packages. Regenerated by `blip pkg`.\n'
	for l in lines {
		sb += '${l.name} ${l.ref} ${l.sha}\n'
	}
	os.write_file(lock_name, sb)!
}

fn head_sha(dir string) string {
	r := os.exec(['git', '-C', dir, 'rev-parse', 'HEAD'])
	if r.exit_code != 0 {
		return ''
	}
	return r.output.trim_space()
}

fn pkg_command(args []string) int {
	if args.len == 0 {
		eprintln('blip: pkg needs a subcommand')
		eprintln('  blip pkg install <owner/repo>   install from GitHub')
		eprintln('  blip pkg list                   what is installed')
		eprintln('  blip pkg remove <name>          remove a package')
		return 2
	}
	// Only install and remove take an argument. Enforcing one on `list` too is
	// how `blip pkg list` ends up reporting that it needs a subcommand.
	sub := args[0]
	if sub != 'list' && args.len < 2 {
		eprintln('blip: pkg ${sub} needs an argument')
		eprintln('run `blip help pkg` for usage')
		return 2
	}
	match sub {
		'install' {
			if args.len < 2 {
				eprintln('blip: pkg install needs <owner/repo>[@ref]')
				return 2
			}
			return pkg_install(args[1])
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
		else {
			eprintln('blip: unknown pkg subcommand `${sub}`')
			eprintln('run `blip help pkg` for usage')
			return 2
		}
	}
}

fn pkg_install(spec string) int {
	owner, repo, ref := parse_pkg_spec(spec)
	if owner == '' {
		eprintln('blip: pkg install wants <owner/repo>[@ref], got `${spec}`')
		return 2
	}
	name := '${owner}/${repo}'
	dir := os.join_path(os.join_path(modules_dir, owner), repo)
	url := 'https://github.com/${name}.git'
	if !os.is_dir(os.join_path(dir, '.git')) {
		os.mkdir_all(os.join_path(modules_dir, owner)) or {
			eprintln('blip: cannot create ${modules_dir}: ${err.msg()}')
			return 1
		}
		r := os.exec(['git', 'clone', '--quiet', url, dir])
		if r.exit_code != 0 {
			eprintln('blip: clone of ${name} failed:')
			eprintln(r.output.trim_space())
			return 1
		}
	}
	// Check the requested ref out explicitly. A shallow clone of the default
	// branch is not the same thing as the tag or commit that was asked for.
	if ref != 'HEAD' {
		r := os.exec(['git', '-C', dir, 'checkout', '--quiet', ref])
		if r.exit_code != 0 {
			eprintln('blip: ${name} has no ref `${ref}`:')
			eprintln(r.output.trim_space())
			return 1
		}
	}
	sha := head_sha(dir)
	if sha == '' {
		eprintln('blip: installed ${name} but cannot record its commit')
		return 1
	}
	mut installed := read_lock()
	mut replaced := false
	for i, l in installed {
		if l.name == name {
			installed[i] = LockLine{
				name: name
				ref:  ref
				sha:  sha
			}
			replaced = true
			break
		}
	}
	if !replaced {
		installed << LockLine{
			name: name
			ref:  ref
			sha:  sha
		}
	}
	write_lock(installed) or {
		eprintln('blip: cannot write ${lock_name}: ${err.msg()}')
		return 1
	}
	println('installed ${name} at ${sha[0..7]} (${ref})')
	return 0
}

fn pkg_list() int {
	installed := read_lock()
	if installed.len == 0 {
		println('no packages installed')
		return 0
	}
	for l in installed {
		dir := os.join_path(os.join_path(modules_dir, os.dir(l.name)), os.file_name(l.name))
		mark := if os.is_dir(dir) { '' } else { '  (missing from ${modules_dir}/)' }
		println('${l.name}  ${l.ref}  ${l.sha[0..7]}${mark}')
	}
	return 0
}

fn pkg_remove(spec string) int {
	owner, repo, _ := parse_pkg_spec(spec)
	name := if owner != '' { '${owner}/${repo}' } else { spec }
	mut found := false
	for l in read_lock() {
		if l.name == name {
			found = true
			break
		}
	}
	if !found {
		eprintln('blip: ${name} is not installed')
		return 1
	}
	owner_dir := os.join_path(modules_dir, os.dir(name))
	dir := os.join_path(owner_dir, os.file_name(name))
	if os.is_dir(dir) {
		os.rmdir_all(dir) or {
			eprintln('blip: cannot remove ${dir}: ${err.msg()}')
			return 1
		}
	}
	// Leaving an empty blip_modules/<owner>/ behind is the kind of thing that
	// makes `pkg list` report a missing package for a name nobody installed.
	if os.is_dir(owner_dir) && os.ls(owner_dir) or { [] }.len == 0 {
		os.rmdir_all(owner_dir) or {}
	}
	mut kept := []LockLine{}
	for l in read_lock() {
		if l.name != name {
			kept << l
		}
	}
	write_lock(kept) or {
		eprintln('blip: cannot write ${lock_name}: ${err.msg()}')
		return 1
	}
	println('removed ${name}')
	return 0
}
