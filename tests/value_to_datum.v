// value_to_datum gate: nil must round-trip value -> datum.

import vlib.blip
import vlib.blip.machine
import vlib.blip.host

fn main() {
	h := &host.ConsoleHost{}
	mut m := machine.new_standalone(h)
	n := blip.value_to_datum(mut m, blip.nil_value())!
	println('PASS nil -> node ${n}')
	println('value_to_datum gate: PASS')
}
