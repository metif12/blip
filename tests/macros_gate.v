module main

// The macro embedded-machine gate (docs/macros-design.md Option 1).
//
// Exercises the real path: fresh embedded machine -> run_str -> value_to_datum
// for every pure shape, plus expand_macro_at_embed end to end. Complex shapes
// (table/closure) must still refuse — that is the documented deferral, not a
// failure of this gate.

import vlib.blip
import vlib.blip.emit
import vlib.blip.host
import vlib.blip.machine

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
	h := host.new_capture()
	mut m := machine.new_standalone(h)

	// Every pure shape must convert without error.
	pure := [
		blip.nil_value(),
		blip.boolean(true),
		blip.boolean(false),
		blip.integer(42),
		blip.float(1.5),
		blip.string('hi'),
		blip.symbol('sym'),
		blip.keyword('kw'),
		blip.empty_list(),
		blip.cons(blip.integer(1), blip.empty_list()),
		blip.vector([blip.integer(1), blip.integer(2)]),
	]
	for v in pure {
		_ = blip.value_to_datum(mut m, v) or {
			s.fail('value_to_datum pure', err.msg())
			continue
		}
	}
	if s.fails == 0 {
		s.ok('value_to_datum pure shapes', '11 shapes convert')
	}

	// A complex shape must refuse with an error, not panic.
	complex := blip.table({
		'a': blip.integer(1)
	})
	mut did_refuse := false
	_ = blip.value_to_datum(mut m, complex) or {
		s.ok('value_to_datum complex refuses', err.msg())
		did_refuse = true
		blip.NodeId(0)
	}
	if !did_refuse {
		s.fail('value_to_datum complex refuses', 'table converted without error')
	}

	// End to end: embedded machine evaluates, then converts.
	res := emit.expand_macro_at_embed('(+ 1 2)', h) or {
		s.fail('expand_macro_at_embed', err.msg())
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	s.ok('expand_macro_at_embed', res)

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('macros_gate: all checks passed')
}
