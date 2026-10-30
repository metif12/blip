module main

import veb
import net.http
import os
import vlib.blip.machine
import vlib.blip.host

struct App {
mut:
	machine &machine.Machine
}

struct Context {
	veb.Context
}

@['/']
pub fn (mut app App) index(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/', machine.veb_to_value(ctx.req.method.str(), ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

fn main() {
	mut m := machine.new_standalone(host.ConsoleHost{})
	m.load('lib/std.lip') or { panic(err) }
	m.run_str('(veb-route "/" (fn [req] "hello from blip"))') or { panic(err) }

	mut app := &App{machine: m}
	req := http.Request{ method: .get, url: '/' }
	ctx := veb.render_request[App, Context](mut app, req) or { panic(err) }
	body := ctx.res.body
	println('response body: ${body}')
	if body != 'hello from blip' {
		panic('expected "hello from blip", got "${body}"')
	}
	println('veb_server ok')
}
