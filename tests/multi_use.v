module main

// The multi-source gate (roadmap P1: "many sources, one machine").
//
// Definitions must cross a run_str boundary on the ONE machine: the second
// source sees what the first defined, and a definition made between the two
// is visible to the second. A machine that started fresh per load breaks
// both halves. Cross-file `use` (loading a FILE into the running machine)
// is a separate property, covered by tests/embedding.v's load checks.

import vlib.blip.host
import vlib.blip.machine
import vlib.blip.printer

fn main() {
	h := &host.ConsoleHost{}
	mut m := machine.new_standalone(h)

	// The machine API takes whole-source strings: defines in source one.
	m.run_str('(define x 42)') or {
		println('FAIL run first source: ${err.msg()}')
		exit(1)
	}
	// ...and one defined BETWEEN sources, as an interactive session would.
	m.run_str('(define between "defined after source one")') or {
		println('FAIL define between sources: ${err.msg()}')
		exit(1)
	}
	// The second source: use x from source one and between from the gap.
	v := m.run_str('(list between x)') or {
		println('FAIL run second source: ${err.msg()}')
		exit(1)
	}
	got := printer.write(v)
	// The printer keeps string quotes — the output is data, not prose.
	if got != r'("defined after source one" 42)' {
		println('FAIL second source sees earlier definitions: got ${got}')
		exit(1)
	}
	println('PASS multi-source use gate')
}
