module main

import os

// The hostile-input gate.
//
// blip's promise is errors as values: bad input is a value the user can read,
// never a V panic that kills the process. This suite feeds the binary wrong
// things -- wrong types, wrong arity, impossible keys, garbage source -- one
// process per case, and demands that the process ANSWER like a program
// rather than die like a library.
//
// Each case is spawned separately, because the whole point is that a hostile
// form must not take the interpreter down with it: a suite process that
// called the machine in-process would die on the first panic and never tell
// us which case did it.
//
// What this gate does NOT judge is how HELPFUL the error text is. `error:
// car expects a pair` and `error: index out of range` are both clean
// answers; `V panic:` or a dying exit code is not.

struct Case {
	name string
	src  string
	// want_ok marks the controls: programs that must run to completion, print
	// their marker, and exit 0. Without them a gate that ALSO wrongly passed
	// on "process died, nothing printed" would look green forever -- a run
	// where even `(print)` never happened had to be tellable from a run
	// where everything happened.
	want_ok bool
}

// crash_codes are the Windows codes a C process cannot recover from. V
// converts a language-level panic into a normal exit with a printed
// message, so any of these means the interpreter itself died.
const crash_codes = [i32(0xC0000005), i32(0xC00000FD), i32(0xC0000409), i32(0xC0000374), i32(3)]

const cases = [
	// controls
	Case{ name: 'a benign program still runs', src: '(print "control-ok")', want_ok: true },
	// wrong types
	Case{ name: 'car of a non-pair', src: '(car 5)' },
	Case{ name: 'cdr of a string', src: '(cdr "x")' },
	Case{ name: 'get on a number', src: '(get 5 :a)' },
	Case{ name: 'has-key? on a number', src: "(has-key? 5 'a)" },
	Case{ name: 'vector-ref out of range', src: '(vector-ref [1 2] 9)' },
	Case{ name: 'vector-length of a number', src: '(vector-length 5)' },
	Case{ name: 'map over a non-sequence', src: '(map length 5)' },
	Case{ name: 'sort of a non-sequence', src: '(sort 5)' },
	Case{ name: 'a table called on a non-key', src: '({:a 1} 5)' },
	Case{ name: 'string-upcase of a number', src: '(string-upcase 5)' },
	Case{ name: 'string-slice with wrong types', src: '(string-slice 5 1 2)' },
	// wrong arity
	Case{ name: 'car with no arguments', src: '(car)' },
	Case{ name: 'cdr with no arguments', src: '(cdr)' },
	Case{ name: 'get with one argument', src: '(get {:a 1})' },
	Case{ name: 'get positional out of range', src: '(get (list 1 2) 9)' },
	Case{ name: 'vector-ref with no index', src: '(vector-ref [1 2])' },
	Case{ name: 'a closure called with no arguments', src: '((fn [x] x))' },
	Case{ name: 'a closure called with too many args', src: '((fn [x] x) 1 2)' },
	Case{ name: 'put with a missing value', src: '(put {:a 1} :b)' },
	Case{ name: 'comparison with no arguments', src: '(=)' },
	// impossible values
	Case{ name: 'division by zero', src: '(/ 1 0)' },
	Case{ name: 'modulo by zero', src: '(modulo 5 0)' },
	Case{ name: 'format whose format is a number', src: '(format 42 "~a")' },
	Case{ name: 'raise of a non-string err payload', src: '(raise (err 42))' },
	Case{ name: 'unwrap of a one-element ok', src: '(unwrap-or (ok) 5)' },
	Case{ name: 'err-value of a one-element err', src: '(err-value (err))' },
	Case{ name: 'quoted table with an integer key', src: "'{1 :x}" },
	Case{ name: 'set! of an unknown name', src: '(set! no-such-thing 1)' },
	Case{ name: 'string->number of garbage', src: '(string->number "12abc")' },
	Case{ name: 'nested error aborted correctly', src: '((((((/ 1 0))))))' },
	// reader-level garbage
	Case{ name: 'unbalanced open paren', src: '(car 1 2' },
	Case{ name: 'unbalanced close paren', src: ')' },
	Case{ name: 'a stray unquote', src: ',x' },
	Case{ name: 'a broken table literal', src: '@{:a 1 (}' },
	// bad input met through the STANDARD prelude, because that is how a real
	// user first meets it: with std.lip already loaded
	Case{ name: 'parse-in on garbage', src: '(parse-in "key with no value")' },
	Case{ name: 'err-message of a non-err', src: '(err-message 5)' },
	Case{ name: 'fold over a non-sequence', src: '(fold + 0 5)' },
]

// The CLI itself is hostile surface: wrong flags and missing files arrive
// before any source is read.
struct CliCase {
	name      string
	cmdline   string
	want_exit int
}

const cli_cases = [
	CliCase{ name: 'run with no file', cmdline: 'run', want_exit: 2 },
	CliCase{ name: 'test with no file', cmdline: 'test', want_exit: 2 },
	CliCase{ name: 'emit-js with no file', cmdline: 'emit-js', want_exit: 2 },
	CliCase{ name: 'an unknown subcommand', cmdline: 'frobnicate', want_exit: 2 },
	CliCase{ name: 'run of a missing file', cmdline: 'run tmp/does-not-exist.lip', want_exit: 1 },
]

struct Suite {
mut:
	fails  int
	checks int
}

fn (mut s Suite) record(label string, ok bool, detail string) {
	s.checks++
	if ok {
		println('ok   ${label} => ${detail}')
	} else {
		s.fails++
		println('FAIL ${label} => ${detail}')
	}
}

fn snippet(text string) string {
	t := text.trim_space().replace('\n', ' / ')
	if t.len > 120 {
		return t[..120]
	}
	return t
}

fn crashed(res os.Result) bool {
	return res.exit_code < 0 || i32(res.exit_code) in crash_codes
		|| res.output.contains('V panic') || res.output.contains('gcc: internal')
}

// spawn_case runs one hostile source through `blip run` in a child process.
fn (mut s Suite) spawn_case(c Case, dir string, blip_bin string) {
	path := os.join_path(dir, 'case.lip')
	os.write_file(path, c.src) or {
		s.fails++
		println('FAIL ${c.name} => cannot write the case file: ${err.msg()}')
		return
	}
	res := os.execute('${blip_bin} run "${path}"')
	if crashed(res) {
		s.fails++
		s.checks++
		println('FAIL ${c.name} => CRASH: exit ${res.exit_code}, ${snippet(res.output)}')
		return
	}
	if c.want_ok {
		s.record(c.name, res.exit_code == 0 && res.output.contains('control-ok'),
			'exit ${res.exit_code}, marker ${if res.output.contains('control-ok') {
				'yes'
			} else {
				'MISSING'
			}}')
	} else {
		s.record(c.name, true, 'clean answer (exit ${res.exit_code}): ${if res.exit_code != 0 {
			snippet(res.output)
		} else {
			'(no error, printed)'
		}}')
	}
}

// spawn_cli runs one CLI case.
fn (mut s Suite) spawn_cli(c CliCase, blip_bin string) {
	res := os.execute('${blip_bin} ${c.cmdline}')
	if crashed(res) {
		s.fails++
		s.checks++
		println('FAIL ${c.name} => CRASH: exit ${res.exit_code}')
		return
	}
	s.record(c.name, res.exit_code == c.want_exit,
		'exit ${res.exit_code} (wanted ${c.want_exit}): ${snippet(res.output)}')
}

fn main() {
	mut s := Suite{}

	blip_bin := if os.exists('blip.exe') { os.real_path('blip.exe') } else { os.real_path('blip') }
	if !os.exists(blip_bin) {
		println('FAIL => no blip binary beside the suite; build it first')
		println('hostile: 0 checks, 1 FAILURE')
		return
	}

	tmp := os.join_path(os.temp_dir(), 'blip_hostile')
	os.mkdir_all(tmp) or {}

	for c in cases {
		s.spawn_case(c, tmp, blip_bin)
	}
	for c in cli_cases {
		s.spawn_cli(c, blip_bin)
	}
	os.rm(tmp) or {}

	if s.fails > 0 {
		println('${s.checks} checks, ${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('hostile: all ${s.checks} checks passed')
}
