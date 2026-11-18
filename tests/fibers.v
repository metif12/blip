module main

// Fiber gate: yield round-trips a value through the machine.

import blip
import blip.host
import blip.machine
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

fn (mut s Suite) check(label string, got string, want string) {
	if got == want {
		s.ok(label, got)
	} else {
		s.fail(label, 'expected ${want}, got ${got}')
	}
}

fn main() {
	mut s := Suite{}
	mut m := machine.new_standalone(host.new_capture())

	// yield passes its value through.
	v := m.run_str('(yield 42)') or {
		s.fail('yield value', err.msg())
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	got := printer.write(v)
	if got == '42' {
		s.ok('yield value', '42')
	} else {
		s.fail('yield value', 'got ${got}')
	}

	// yield with no arg yields nil.
	v2 := m.run_str('(yield)') or {
		s.fail('yield nil', err.msg())
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	got2 := printer.write(v2)
	if got2 == 'nil' {
		s.ok('yield nil', 'nil')
	} else {
		s.fail('yield nil', 'got ${got2}')
	}

	// B4: spawn runs a thunk later, resume drives it to the next yield
	// (or to the end), and the yielded and returned values come back.
	// Prints interleave with resumes: nothing runs at spawn time.
	m.run_str('(def f (spawn (fn [] (println "a") (yield 1) (println "b") 2)))') or {
		s.fail('spawn', err.msg())
		return
	}
	if printer.write(m.run_str('(fiber-status f)') or { blip.nil_value() }) != ':ready' {
		s.fail('fiber starts ready', 'wrong status')
	}
	r1 := m.run_str('(resume f)') or {
		s.fail('first resume', err.msg())
		return
	}
	s.check('first resume yields 1', printer.write(r1), '1')
	s.check('fiber suspends', printer.write(m.run_str('(fiber-status f)') or { blip.nil_value() }),
		':suspended')
	s.check('not done yet', printer.write(m.run_str('(fiber-done? f)') or { blip.nil_value() }),
		'#f')
	r2 := m.run_str('(resume f)') or {
		s.fail('second resume', err.msg())
		return
	}
	s.check('second resume returns 2', printer.write(r2), '2')
	s.check('fiber finishes', printer.write(m.run_str('(fiber-status f)') or { blip.nil_value() }),
		':done')
	s.check('done reads true', printer.write(m.run_str('(fiber-done? f)') or { blip.nil_value() }),
		'#t')
	// The prints ran in resume order: "a" before the first resume
	// returned, "b" before the second.
	s.check('prints interleave with resumes', m.out.join('|'), '"a"|"b"')

	// Two fibers interleave: each resume advances only its own fiber.
	m.run_str('(def g (spawn (fn [] (yield (quote x)) (yield (quote y)) (quote z))))') or {
		s.fail('spawn g', err.msg())
		return
	}
	m.run_str('(def h (spawn (fn [] (yield 10) 20)))') or {
		s.fail('spawn h', err.msg())
		return
	}
	s.check('g first', printer.write(m.run_str('(resume g)') or { blip.nil_value() }), 'x')
	s.check('h first', printer.write(m.run_str('(resume h)') or { blip.nil_value() }), '10')
	s.check('g second', printer.write(m.run_str('(resume g)') or { blip.nil_value() }), 'y')
	s.check('h returns', printer.write(m.run_str('(resume h)') or { blip.nil_value() }), '20')
	s.check('g returns', printer.write(m.run_str('(resume g)') or { blip.nil_value() }), 'z')

	// Bounded steps: a countdown resumed with a small budget pauses
	// instead of running away, and finishes with the same answer when
	// resumed without one. The resume count proves pausing happened;
	// the value proves nothing was lost.
	m.run_str('(def (countdown n) (if (= n 0) (quote done) (begin (yield n) (countdown (- n 1)))))') or {
		s.fail('define countdown', err.msg())
		return
	}
	m.run_str('(def c (spawn (fn [] (countdown 30))))') or {
		s.fail('spawn countdown', err.msg())
		return
	}
	mut pauses := 0
	mut last := blip.nil_value()
	for _ in 0 .. 100 {
		if printer.write(m.run_str('(fiber-done? c)') or { blip.nil_value() }) == '#t' {
			break
		}
		if printer.write(m.run_str('(fiber-status c)') or { blip.nil_value() }) == ':paused' {
			pauses++
		}
		last = m.run_str('(resume c 20)') or {
			s.fail('budgeted resume', err.msg())
			break
		}
	}
	s.check('budget pauses the fiber', if pauses > 0 { 'paused' } else { 'ran straight through' },
		'paused')
	s.check('budgeted run finishes whole', printer.write(last), 'done')

	// Errors are loud: spawning a non-function, resuming a done fiber,
	// resuming a stranger, and a fiber resuming itself.
	if _ := m.run_str('(spawn 42)') {
		s.fail('spawn refuses a non-function', 'ran clean')
	} else {
		if err.msg().contains('expects a function') {
			s.ok('spawn refuses a non-function', 'refused')
		} else {
			s.fail('spawn refuses a non-function', 'wrong error: ${err.msg()}')
		}
	}
	if _ := m.run_str('(resume f)') {
		s.fail('resume refuses a done fiber', 'ran clean')
	} else {
		if err.msg().contains('is done') {
			s.ok('resume refuses a done fiber', 'refused')
		} else {
			s.fail('resume refuses a done fiber', 'wrong error: ${err.msg()}')
		}
	}
	if _ := m.run_str('(resume 999)') {
		s.fail('resume refuses a stranger', 'ran clean')
	} else {
		if err.msg().contains('no such fiber') {
			s.ok('resume refuses a stranger', 'refused')
		} else {
			s.fail('resume refuses a stranger', 'wrong error: ${err.msg()}')
		}
	}
	m.run_str('(def me 0)') or {}
	m.run_str('(set! me (spawn (fn [] (resume me))))') or {
		s.fail('spawn self-resumer', err.msg())
		return
	}
	if _ := m.run_str('(resume me)') {
		s.fail('a fiber cannot resume itself', 'ran clean')
	} else {
		if err.msg().contains('cannot resume itself') {
			s.ok('a fiber cannot resume itself', 'refused')
		} else {
			s.fail('a fiber cannot resume itself', 'wrong error: ${err.msg()}')
		}
	}

	// Yield across a V-stack boundary is refused, not corrupted: a map
	// callback lives in a host-side loop the saved state cannot resume.
	m.run_str('(def yielder (spawn (fn [] (map (fn [x] (yield x)) [1 2 3]))))') or {
		s.fail('spawn boundary tester', err.msg())
		return
	}
	if _ := m.run_str('(resume yielder)') {
		s.fail('yield refuses the host boundary', 'ran clean')
	} else {
		if err.msg().contains('cannot cross a host boundary') {
			s.ok('yield refuses the host boundary', 'refused')
		} else {
			s.fail('yield refuses the host boundary', 'wrong error: ${err.msg()}')
		}
	}

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('fibers: all checks passed')
}
