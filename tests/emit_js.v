module main

import os
import vlib.blip.emit
import vlib.blip.host
import vlib.blip.machine

// The JS backend gate.
//
// A backend whose output nobody ran is not a backend -- it is a claim. So this
// suite does the thing the roadmap's bar asks for: it emits JavaScript from a
// blip program, RUNS it with node, and compares the output against running the
// same program on the blip machine. If they disagree, the backend is wrong, and
// the suite says so with both texts.
//
// The check is on output rather than on the emitted text, because the emitted
// text is free to change in any way that keeps the program meaning the same.

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

fn (mut s Suite) eq(label string, got string, want string) {
	s.checks++
	if got == want {
		println('ok   ${label} => ${got}')
	} else {
		s.fails++
		println('FAIL ${label}')
		println('     got  ${got}')
		println('     want ${want}')
	}
}

// blip_output runs the source on the blip machine and returns what it printed.
fn blip_output(src string) string {
	h := host.new_capture()
	h.give_file('main.lip', src)
	mut m := machine.new_standalone(h)
	m.load('main.lip') or { return 'ERROR: ${err.msg()}' }
	return h.transcript().trim_right('\n')
}

// node_output runs the emitted JavaScript and returns what it printed.
//
// Node's output goes to a FILE and is read back, rather than captured from the
// child: capturing the output of a program that prints thousands of lines
// overflowed this test's stack, and the emitter plus the runner in one process
// is a stack depth the compiler did not accept.
fn node_output(js string) string {
	os.mkdir_all('tmp') or {}
	js_path := 'tmp/emit_check.js'
	os.write_file(js_path, js) or { return 'ERROR: cannot write ${js_path}' }
	os.rm('tmp/emit_check.out') or {}
	out_path := os.join_path(os.getwd(), 'tmp', 'emit_check.out')
	shelled := os.system('node "${js_path}" > "${out_path}" 2>&1')
	if shelled != 0 {
		got := os.read_file(out_path) or { '' }
		return 'ERROR: node exited ${shelled}: ${got.limit(200)}'
	}
	got := os.read_file(out_path) or { return 'ERROR: cannot read ${out_path}' }
	os.rm(out_path) or {}
	return got.trim_right('\n')
}

// blip_cli is the interpreter the runner built next to this test. Bare
// `blip` resolves against PATH, and POSIX sh does not check the current
// directory, so a green Windows run (cmd searches cwd) became
// `sh: 1: blip: not found`, exit 127, on the runner — and for the example
// checks both "engines" then failed identically, which compared EQUAL.
// Path it explicitly; never compare two identical failure strings.
//
// The path is ABSOLUTE in both branches. The original Windows spelling was
// `.\blip.exe`, whose backslash is a path separator only on Windows: on sh it
// reached the shell as an unresolvable command and every example comparison
// became want = got = the same 127 error, which a string comparison accepts.
// An absolute path runs from the same three shells (cmd, PowerShell, sh) and
// keeps the never-compare-two-failures rule meaningful.
fn blip_cli() string {
	cli := if os.exists('blip.exe') { 'blip.exe' } else { 'blip' }
	return os.real_path(cli)
}

// blip_file_output runs a FILE through the blip CLI, which loads lib/std.lip.
//
// The in-process `blip_output` deliberately does NOT load the standard library,
// because these checks are small snippets of primitives and a 630-line prelude
// per check is not worth it. An EXAMPLE is not a snippet: it needs stdlib on both
// sides, or the comparison is between a program and a program missing half its
// definitions. Both engines therefore get the same load order.
fn blip_file_output(path string) string {
	os.mkdir_all('tmp') or {}
	out_path := os.join_path(os.getwd(), 'tmp', 'emit_blip.out')
	os.rm(out_path) or {}
	shelled := os.system('"${blip_cli()}" run "${path}" > "${out_path}" 2>&1')
	got := os.read_file(out_path) or { '' }
	os.rm(out_path) or {}
	if shelled != 0 {
		return 'ERROR: blip exited ${shelled}: ${got.trim_space().limit(200)}'
	}
	return got.trim_right('\n')
}

// check emits the source, runs both engines on it, and compares.
fn (mut s Suite) check(label string, src string) {
	res := emit.compile(src) or {
		s.fails++
		println('FAIL ${label} => emit failed: ${err.msg()}')
		return
	}
	if res.blocked.len > 0 {
		s.fails++
		println('FAIL ${label} => refused: ${res.blocked.join(', ')}')
		return
	}
	blip := blip_output(src)
	node := node_output(res.js)
	s.eq('${label} matches', node, blip)
}

// check_example is the real bar for one example, and the one the batch above
// cannot set by itself: emit the file, run it on node, run the SAME source on
// the blip machine, and require the two transcripts to be identical. The
// difference is the thing being tested -- an example that prints the right
// shape with the wrong values would pass a golden-output check and fail this.
fn (mut s Suite) check_example(name string) {
	path := 'examples/${name}.lip'
	src := os.read_file(path) or {
		s.fails++
		println('FAIL ${name} => cannot read ${path}')
		return
	}
	res := emit.compile_file(path) or {
		s.fails++
		println('FAIL ${name} => emit failed: ${err.msg()}')
		return
	}
	if res.blocked.len > 0 {
		s.fails++
		println('FAIL ${name} => refused: ${res.blocked.join(', ')}')
		return
	}
	// Both sides run the same FILE, so both get lib/std.lip. Comparing an emitted
	// program against a snippet-only interpreter is how 03_match looked like a
	// failure of the backend when it was a missing prelude.
	s.eq('${name} output matches the interpreter', node_output(res.js), blip_file_output(path))
}

fn main() {
	mut s := Suite{}

	s.check('a define and a call', '(define (double x) (* 2 x))
(print (double 21))')

	s.check('a named function and if', '(define (fact n)
  (if (< n 2) n (* n (fact (- n 1)))))
(print (fact 5))')

	s.check('let binds and unbinds', '(print (let ([a 1] [b 2]) (+ a b)))')

	s.check('let keeps its bindings local', '(define x 1)
(print (let ([x 9]) x))
(print x)')

	s.check('car and cdr of a list', '(print (car (quote (10 20 30))))
(print (cdr (quote (10 20 30))))')

	// cons onto a LIST, not a vector: blip's cons of a vector prints (1) while
	// the runtime's prints (1 (2 3)), and that divergence is a real difference in
	// what cons does with a vector cdr rather than a bug in the emitter. It is
	// left out of v1 and recorded rather than papered over.
	s.check('cons builds a list', '(print (cons 1 (quote (2 3))))')

	s.check('string printing keeps its quotes', '(print "hello")')

	s.check('if in expression position', '(print (if #t "yes" "no"))')

	s.check('begin sequences', '(print (begin 1 2 3))')

	// `defined?` compiles to a `typeof` probe, so both engines can answer the
	// same question and the comparison is on the printed "#t"/"#f".
	s.check('defined? of an unbound name', '(print (defined? no-such-name))')
	s.check('defined? of a defined global', '(define d1 1)(print (defined? d1))')
	s.check('defined? of the quoted spelling', "(define d2 2)(print (defined? 'd2))")
	s.check('defined? of a primitive', '(print (defined? car))')
	s.check('defined? inside a let sees the binding', '(print (let ([y 2]) (defined? y)))')

	s.check('quote is a literal', '(print (quote (1 2 3)))')

	s.check('a lambda applied', '(print ((fn [x] (* x x)) 7))')

	// Threading. Each of these is prims and machine forms only, so the blip
	// side runs without the standard library -- which matters because
	// blip_output does not load it.
	s.check('thread-last through a call step', '(print (->> [1 2 3] (vector-map (fn [x] (* x 10))) vector-rev))')

	s.check('thread-last through bare pipe steps', '(print (->> "hello" |> string-upcase |> string-length))')

	s.check('thread-last sorts then reverses', '(print (->> [3 1 2] |> sort |> reverse))')

	s.check('thread-first puts the value first', '(print (-> 10 (/ 4)))')

	// A pipe inside a pipe is SPLICED, not nested: the inner steps join the
	// outer thread. Without this the inner head emits as a call to a mangled
	// name that exists nowhere.
	s.check('nested pipes splice into the outer thread', '(print (-> (quote (9)) (->> (quote (1)) (car))))')

	// 02_data is the first example the backend reproduces byte for byte: same
	// collections, same containers, same sorted-key table spelling, same
	// keyword-as-lookup rule. It is the only example checked this way, and the
	// count in `no example is accepted silently` below is what says the others
	// have not caught up.
	s.check_example('02_data')

	s.check_example('03_match')

	s.check_example('04_errors')

	s.real_programs()

	if s.fails > 0 {
		println('${s.checks} checks, ${s.fails} FAILURE(S)')
		return
	}
	println('emit-js: all ${s.checks} checks passed')
}

// ---- the real bar ---------------------------------------------------------

// The eleven checks above are small and pass. Every real example failed them
// anyway, and did so SILENTLY: the emitter reported "clean" for five of the six
// examples while the JavaScript ran and printed nothing. A green run that means
// nothing is the worst failure mode a backend has, so the honest measure is not
// the tiny programs -- it is an actual program, end to end.
//
// Each example is emitted and the emitted JavaScript is run. A program the
// backend cannot handle yet must be REFUSED by name; a program it accepts must
// produce output. Either outcome is a real result. The one that is not allowed
// is acceptance with no output, which is what this used to do.
fn (mut s Suite) real_programs() {
	examples := ['01_basics', '02_data', '03_match', '04_errors', '05_pipelines', '06_modules']
	mut silent := []string{}
	mut refused := []string{}
	mut running := []string{}
	for ex in examples {
		path := 'examples/${ex}.lip'
		src := os.read_file(path) or {
			continue
		}
		res := emit.compile_file(path) or {
			refused << '${ex}: ${err.msg()}'
			continue
		}
		if res.blocked.len > 0 {
			refused << '${ex}: ${res.blocked.join(', ')}'
			continue
		}
		out := node_output(res.js)
		if out.starts_with('ERROR') || out.trim_space() == '' {
			// Accepted and produced nothing usable: the failure this whole
			// check exists to catch.
			silent << '${ex}: ${out.trim_space().limit(90)}'
			continue
		}
		running << ex
	}
	s.checks++
	println('info examples the backend runs: ${running.join(' ')}')
	println('info examples refused by name: ${refused.len} -> ${refused.join(' | ')}')
	if silent.len == 0 {
		println('ok   no example is accepted silently => ${running.len} run, ${refused.len} refused')
		return
	}
	println('FAIL examples accepted with no output')
	for line in silent {
		println('     ${line}')
	}
	s.fails++
}
