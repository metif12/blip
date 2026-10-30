module main

// Fiber gate: yield round-trips a value through the machine.

import vlib.blip
import vlib.blip.host
import vlib.blip.machine
import vlib.blip.printer

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

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('fibers: all checks passed')
}
