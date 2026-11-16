module main

// veb bridge gate: a blip handler closure can be registered and dispatched.

import os
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
	mut m := machine.new_standalone(host.new_capture())
	std := os.read_file('lib/std.lip') or { '' }
	if std != '' { m.load(std) or {} }
	// Register a handler that echoes the path and body.
	m.run_str('(veb-route "/" (fn [req] (string-append "got: " (get req :path) " " (get req :body))))') or {
		s.fail('register handler', err.msg())
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	// Dispatch a request.
	req := machine.veb_to_value('GET', '/', 'hello')
	resp := m.veb_dispatch('/', req)
	body := machine.value_to_veb_body(resp)
	if body == 'got: / hello' {
		s.ok('veb dispatch', body)
	} else {
		s.fail('veb dispatch', 'got ${body}')
	}
	// Unknown path returns an error value.
	resp2 := m.veb_dispatch('/nope', req)
	if resp2.tag == .pair {
		s.ok('veb unknown path', 'error value returned')
	} else {
		s.fail('veb unknown path', 'expected error value, got ${resp2.tag}')
	}
	// Re-registering from V works too: the stored closure keeps serving.
	if '/' !in m.veb_handlers {
		s.fail('re-register', 'no handler stored for /')
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	m.veb_route('/echo', m.veb_handlers['/'])
	resp3 := m.veb_dispatch('/echo', req)
	body3 := machine.value_to_veb_body(resp3)
	if body3 == 'got: / hello' {
		s.ok('veb re-route', body3)
	} else {
		s.fail('veb re-route', 'got ${body3}')
	}
	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('veb_bridge: all checks passed')
}
