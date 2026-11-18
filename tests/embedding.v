module main

/*
 * The embedding gate.
 *
 * The claim being tested is that a blip machine is a value: two of them can exist
 * at once, in one process, and neither can see or damage the other. That is what
 * separates an interpreter from a program that happens to have a library-shaped
 * API. It is also what makes every other test here possible -- the REPL golden
 * test, the `,l` load command, and eventually a blip program driving another
 * machine.
 *
 * The interesting failure modes are all silent, so each one is provoked on
 * purpose rather than assumed away:
 *
 *   * A second source read renumbering the first one's nodes. Closures and
 *     continuation frames hold a NodeId and nothing else, so reading into a
 *     fresh arena and swapping the pointer would make every pre-existing closure
 *     read from the wrong array -- and only for code defined before the read.
 *   * `print` writing to stdout instead of the host, which makes this file
 *     untestable and every embedder's output uncollectable.
 *   * Limits that are process-global rather than fields on the machine.
 *
 * Each check returns a bool rather than calling `return` from main: a bare `return`
 * inside `or { }` ends the whole suite, and one such early exit silently skipped
 * half this file until it was noticed.
 */

import blip
import blip.host
import blip.machine
import blip.manifest
import blip.printer

struct Suite {
mut:
	fails int
}

fn (mut s Suite) fail(label string, msg string) {
	s.fails++
	println('FAIL ${label}: ${msg}')
}

fn (mut s Suite) ok(label string, detail string) {
	println('ok   ${label} => ${detail}')
}

fn (mut s Suite) record(label string, passed bool, good string, bad string) bool {
	if passed {
		s.ok(label, good)
	} else {
		s.fail(label, bad)
	}
	return passed
}

// pair builds two independent machines with capture hosts, which is the setup
// most of these checks share.
fn pair() (&machine.Machine, &machine.Machine, &host.CaptureHost, &host.CaptureHost) {
	ha := host.new_capture()
	hb := host.new_capture()
	a := machine.new_standalone(ha)
	b := machine.new_standalone(hb)
	return a, b, ha, hb
}

fn text(v blip.Value) string {
	return printer.write(v)
}

// fails reports whether `f` returned an error.
//
// Written as a function taking a closure because `x or { ... }` reads the wrong
// way round in an assertion: the block runs when the call FAILS, so putting
// `s.fail` inside it reports the failure of the thing that was supposed to fail.
// The first version of the bad-program check said exactly that, and it "failed"
// on correct behaviour.
fn fails(f fn () !blip.Value) bool {
	f() or {
		return true
	}
	return false
}

// ---- the checks ----------------------------------------------------------

fn (mut s Suite) two_machines_are_independent() bool {
	mut a, mut b, _, _ := pair()
	a.run_str('(def x 1) (def (f) x)') or {
		s.fail('two machines are independent', 'a: ${err.msg()}')
		return false
	}
	b.run_str('(def x 2) (def (f) (* 10 x))') or {
		s.fail('two machines are independent', 'b: ${err.msg()}')
		return false
	}
	va := a.run_str('(f)') or { blip.nil_value() }
	vb := b.run_str('(f)') or { blip.nil_value() }
	return s.record('two machines are independent', text(va) == '1' && text(vb) == '20',
		'a(f)=1 b(f)=20', 'a(f)=${text(va)} b(f)=${text(vb)}')
}

fn (mut s Suite) a_definition_does_not_cross_machines() bool {
	mut a, mut b, _, _ := pair()
	a.run_str('(def only-in-a 1)') or {
		s.fail('a definition does not cross machines', 'setup: ${err.msg()}')
		return false
	}
	va := a.run_str('only-in-a') or { blip.nil_value() }
	if text(va) != '1' {
		s.fail('a definition does not cross machines', 'the defining machine lost it')
		return false
	}
	// A Result is not usable as a condition in V 0.5.2, so "this must fail" is
	// written as an `or` block that returns early. Reading it the other way round
	// is what made the first version of this file pass silently.
	b.run_str('only-in-a') or {
		return s.record('a definition does not cross machines', true,
			'bound in one, unbound in the other', '')
	}
	s.fail('a definition does not cross machines', 'the other machine resolved it')
	return false
}

fn (mut s Suite) run_str_accumulates() bool {
	_, mut m, _, _ := pair()
	m.run_str('(def a 1)') or {
		s.fail('run_str accumulates', 'setup: ${err.msg()}')
		return false
	}
	m.run_str('(def b (+ a 1)) (def (uses-both) (+ a b))') or {
		s.fail('run_str accumulates', err.msg())
		return false
	}
	got := m.run_str('(uses-both)') or {
		s.fail('run_str accumulates', err.msg())
		return false
	}
	return s.record('run_str accumulates', text(got) == '3', 'three calls, one machine, value 3',
		'expected 3, got ${text(got)}')
}

fn (mut s Suite) a_closure_survives_a_later_read() bool {
	_, mut m, _, _ := pair()
	m.run_str('(def (adder n) (fn [x] (+ x n))) (def add10 (adder 10))') or {
		s.fail('a closure survives a later read', 'setup: ${err.msg()}')
		return false
	}
	// Read a second, much larger source, so the first source's nodes are nowhere
	// near the end of the arena. If the arena were replaced rather than appended
	// to, every NodeId above would now mean something else.
	mut big := ''
	mut n := 0
	for n < 300 {
		big += '(def filler${n} ${n})\n'
		n++
	}
	m.run_str(big) or {
		s.fail('a closure survives a later read', err.msg())
		return false
	}
	got := m.run_str('(add10 5)') or {
		s.fail('a closure survives a later read', err.msg())
		return false
	}
	return s.record('a closure survives a later read', text(got) == '15',
		'value 15 after a second source of 300 definitions', 'expected 15, got ${text(got)}')
}

fn (mut s Suite) load_evaluates_into_the_running_machine() bool {
	_, mut m, _, h := pair()
	h.give_file('lib.blip',
		'(def loaded-value 41)\n(def (loaded-fn) (+ loaded-value 1))')
	m.run_str('(def before 1)') or {
		s.fail('load evaluates into the running machine', 'setup: ${err.msg()}')
		return false
	}
	m.load('lib.blip') or {
		s.fail('load evaluates into the running machine', err.msg())
		return false
	}
	got := m.run_str('(loaded-fn)') or {
		s.fail('load evaluates into the running machine', err.msg())
		return false
	}
	before := m.run_str('before') or { blip.nil_value() }
	return s.record('load evaluates into the running machine', text(got) == '42' && text(before) == '1',
		'value 42 from the file, and a definition from before the load survives',
		'loaded-fn=${text(got)} before=${text(before)}')
}

// `.vl` and `.lip` do not load in v2 (roadmap A2): the loader refuses with
// a migration line naming `.blip`, instead of the old deprecation warning.
// This pins the refusal and the message, not just failure.
fn (mut s Suite) vl_extension_load_is_refused() bool {
	_, mut m, _, h := pair()
	h.give_file('lib.vl', '(def loaded-value 41)\n')
	h.give_file('old.lip', '(def loaded-value 41)\n')
	m.load('lib.vl') or {
		if err.msg().contains('v2 loads .blip files only') {
			return s.record('a .vl load is refused with a migration line', true,
				'refused naming .blip', '')
		}
		s.fail('a .vl load is refused with a migration line', 'wrong error: ${err.msg()}')
		return false
	}
	s.fail('a .vl load is refused with a migration line', 'load returned a value')
	return false
}

fn (mut s Suite) lip_extension_load_is_refused() bool {
	_, mut m, _, h := pair()
	h.give_file('old.lip', '(def loaded-value 41)\n')
	m.load('old.lip') or {
		if err.msg().contains('v2 loads .blip files only') {
			return s.record('a .lip load is refused with a migration line', true,
				'refused naming .blip', '')
		}
		s.fail('a .lip load is refused with a migration line', 'wrong error: ${err.msg()}')
		return false
	}
	s.fail('a .lip load is refused with a migration line', 'load returned a value')
	return false
}

fn (mut s Suite) a_missing_file_is_an_error() bool {
	_, mut m, _, _ := pair()
	m.load('missing.blip') or {
		return s.record('a missing file is an error', true,
			'the host reported it and the host survived', '')
	}
	s.fail('a missing file is an error', 'load returned a value')
	return false
}

fn (mut s Suite) print_goes_to_the_host_and_to_out() bool {
	// v2 (roadmap A1.2): `print` is VERBATIM -- no trailing newline -- so it
	// reaches the host's transcript but completes no line; `println` is the
	// old `print` and completes one. `m.out` collects one fragment per call
	// either way; the newline is the host's business.
	_, mut m, _, h := pair()
	m.run_str('(print "hello" 42)') or {
		s.fail('print goes to the host', err.msg())
		return false
	}
	if h.lines().len != 0 {
		s.fail('print is verbatim', 'host.lines() = ${h.lines()}')
		return false
	}
	if h.transcript() != '"hello" 42' {
		s.fail('print goes to the host', 'transcript = ${h.transcript()}')
		return false
	}
	if m.out.len != 1 || m.out[0] != '"hello" 42' {
		s.fail('print goes to the host', 'machine.out = ${m.out}')
		return false
	}
	// `display` differs from `print` in exactly one way: no quotes on strings.
	// It is verbatim too, so it appends to the same transcript, no new line.
	m.run_str('(display "raw" :kw)') or {}
	if m.out.len != 2 || m.out[1] != 'raw :kw' {
		s.fail('display shows strings raw', 'machine.out = ${m.out}')
		return false
	}
	if h.transcript() != '"hello" 42raw :kw' {
		s.fail('display is verbatim', 'transcript = ${h.transcript()}')
		return false
	}
	// `println` ends the line: one entry in host.lines(), same fragment in out.
	m.run_str('(println "done" 7)') or {}
	if h.lines().len != 1 || h.lines()[0] != '"done" 7' {
		s.fail('println ends the line', 'host.lines() = ${h.lines()}')
		return false
	}
	if m.out.len != 3 || m.out[2] != '"done" 7' {
		s.fail('println goes to out', 'machine.out = ${m.out}')
		return false
	}
	return s.record('print goes to the host and to out', true,
		'verbatim print/display in transcript and out, println in lines', '')
}

fn (mut s Suite) output_stays_with_its_machine() bool {
	mut a, mut b, ha, hb := pair()
	a.run_str('(println "from a")') or {}
	b.run_str('(println "from b")') or {}
	ok := ha.lines().len == 1 && ha.lines()[0] == '"from a"' && hb.lines().len == 1 && hb.lines()[0] == '"from b"'
	return s.record('output stays with its machine', ok, 'each host saw only its own line',
		'a=${ha.lines()} b=${hb.lines()}')
}

fn (mut s Suite) a_step_limit_is_per_machine() bool {
	mut a, mut b, _, _ := pair()
	a.max_steps = 50
	// A loop whose test is always true, to trip the step limit.
	a.run_str('(loop i 0 #t i)') or {
		if b.max_steps == 50 {
			s.fail('a step limit is per machine', 'the other machine inherited it')
			return false
		}
		ok := b.run_str('(+ 1 2)') or { blip.nil_value() }
		return s.record('a step limit is per machine', text(ok) == '3',
			'the bounded machine stopped, the other still works', 'got ${text(ok)}')
	}
	s.fail('a step limit stops one machine', 'the unbounded loop returned a value')
	return false
}

fn (mut s Suite) a_machine_survives_a_bad_program() bool {
	_, mut m, _, _ := pair()
	m.run_str('(def good 7)') or {
		s.fail('a machine survives a bad program', 'setup: ${err.msg()}')
		return false
	}
	// Two failures in a row. The first is the interesting one: it aborts with
	// continuation frames still on the stack, and if those frames were left there
	// the SECOND evaluation would return into them instead of finishing.
	bad1 := fn [mut m] () !blip.Value {
		return m.run_str('(car 1)')
	}
	bad2 := fn [mut m] () !blip.Value {
		return m.run_str('(car 1)')
	}
	if !fails(bad1) || !fails(bad2) {
		s.fail('a machine survives a bad program', '(car 1) did not fail')
		return false
	}
	got := m.run_str('good') or {
		s.fail('a machine survives a bad program', err.msg())
		return false
	}
	// kont=0 matters as much as the value: a dirty stack is what turns the next
	// evaluation into a wrong answer rather than an error.
	return s.record('a machine survives a bad program', text(got) == '7' && m.kstack.len == 0,
		'two failures, then good is still 7 with kont=0',
		'good is now ${text(got)}, kont=${m.kstack.len}')
}

fn (mut s Suite) the_host_supplies_input() bool {
	_, _, _, h := pair()
	h.give_input(['(+ 1 2)'])
	line := h.host_read_line() or {
		s.fail('the host supplies input', 'no line')
		return false
	}
	if line != '(+ 1 2)' {
		s.fail('the host supplies input', 'got ${line}')
		return false
	}
	if h.host_read_line() != none {
		s.fail('the host supplies input', 'there should be nothing left')
		return false
	}
	return s.record('the host supplies input', true, 'one line, then end of input', '')
}

// E2a: a manifest with `fs` off removes the file prims, so a later use
// fails cleanly as `unbound identifier` instead of running. The manifest
// stays stored on the machine for E2b `blip check`.
fn (mut s Suite) manifest_fs_off_disables_file_prims() bool {
	_, mut m, _, _ := pair()
	mf := manifest.parse('(module m)\n(blip 2)\n(features (fs #f))') or {
		s.fail('fs off disables file prims', err.msg())
		return false
	}
	m.apply_manifest(mf) or {
		s.fail('fs off disables file prims', err.msg())
		return false
	}
	if m.applied_manifest.feature('fs') {
		s.fail('fs off disables file prims', 'stored manifest still has fs on')
		return false
	}
	m.run_str('(read-file "x")') or {
		if err.msg().contains('unbound identifier: read-file') {
			return s.record('fs off disables file prims', true, 'read-file unbound after apply', '')
		}
		s.fail('fs off disables file prims', 'wrong error: ${err.msg()}')
		return false
	}
	s.fail('fs off disables file prims', 'read-file still ran')
	return false
}

fn (mut s Suite) manifest_env_off_disables_env() bool {
	_, mut m, _, _ := pair()
	mf := manifest.parse('(module m)\n(blip 2)\n(features (env #f))') or {
		s.fail('env off disables env', err.msg())
		return false
	}
	m.apply_manifest(mf) or {
		s.fail('env off disables env', err.msg())
		return false
	}
	m.run_str('(env "HOME")') or {
		if err.msg().contains('unbound identifier: env') {
			return s.record('env off disables env', true, 'env unbound after apply', '')
		}
		s.fail('env off disables env', 'wrong error: ${err.msg()}')
		return false
	}
	s.fail('env off disables env', 'env still ran')
	return false
}

// E2a: an unknown capability is a hard error naming the blip.mod line,
// not a silent no-op. `fibers` does not exist until Track B4 lands.
fn (mut s Suite) manifest_unknown_feature_errors() bool {
	_, mut m, _, _ := pair()
	mf := manifest.parse('(module m)\n(blip 2)\n(features (fibers #f))') or {
		s.fail('unknown feature errors', err.msg())
		return false
	}
	m.apply_manifest(mf) or {
		if err.msg().contains('blip.mod:3') && err.msg().contains("unknown feature 'fibers'") {
			return s.record('unknown feature errors', true, 'fibers refused at blip.mod:3', '')
		}
		s.fail('unknown feature errors', 'wrong error: ${err.msg()}')
		return false
	}
	s.fail('unknown feature errors', 'apply accepted fibers')
	return false
}

// E2a: a manifest with `fs` on keeps the file prims. `file-exists?`
// answers a bool with no host setup, so it proves the prim survived.
fn (mut s Suite) manifest_fs_on_keeps_file_prims() bool {
	_, mut m, _, _ := pair()
	mf := manifest.parse('(module m)\n(blip 2)\n(features (fs #t))') or {
		s.fail('fs on keeps file prims', err.msg())
		return false
	}
	m.apply_manifest(mf) or {
		s.fail('fs on keeps file prims', err.msg())
		return false
	}
	got := m.run_str('(file-exists? "no-such-blip-file")') or {
		s.fail('fs on keeps file prims', err.msg())
		return false
	}
	return s.record('fs on keeps file prims', text(got) == '#f', 'file-exists? answered #f', 'got ${text(got)}')
}

fn main() {
	mut s := Suite{}
	s.two_machines_are_independent()
	s.a_definition_does_not_cross_machines()
	s.run_str_accumulates()
	s.a_closure_survives_a_later_read()
	s.load_evaluates_into_the_running_machine()
	s.vl_extension_load_is_refused()
	s.lip_extension_load_is_refused()
	s.a_missing_file_is_an_error()
	s.print_goes_to_the_host_and_to_out()
	s.output_stays_with_its_machine()
	s.a_step_limit_is_per_machine()
	s.a_machine_survives_a_bad_program()
	s.the_host_supplies_input()
	s.manifest_fs_off_disables_file_prims()
	s.manifest_env_off_disables_env()
	s.manifest_unknown_feature_errors()
	s.manifest_fs_on_keeps_file_prims()

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('embedding: all checks passed')
}
