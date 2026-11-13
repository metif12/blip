// value_to_datum gate: nil must round-trip value -> datum.

import blip
import blip.machine
import blip.host

fn main() {
	h := &host.ConsoleHost{}
	mut m := machine.new_standalone(h)
	n := m.value_to_datum(blip.nil_value())!
	println('PASS nil -> node ${n}')
	println('value_to_datum gate: PASS')
}
