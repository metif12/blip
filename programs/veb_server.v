module main

import veb
import net.http
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

@['/about']
pub fn (mut app App) about(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/about', machine.veb_to_value(ctx.req.method.str(), ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

@['/getting-started']
pub fn (mut app App) getting_started(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/getting-started', machine.veb_to_value(ctx.req.method.str(), ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

fn main() {
	mut m := machine.new_standalone(host.ConsoleHost{})
	m.load('lib/std.lip') or { panic(err) }
	// Register handlers. Each reads the layout template and content file,
	// then substitutes {{title}} and {{body}}.
	m.run_str('(define (render-page title body) (use (read-file "site/layout.html") (string-replace (string-replace read-file "{{title}}" title) "{{body}}" body)))') or { panic(err) }
	m.run_str('(veb-route "/" (fn [req] (use (read-file "site/content/index.md") (render-page "blip" read-file))))') or { panic(err) }
	m.run_str('(veb-route "/about" (fn [req] (use (read-file "site/content/about.md") (render-page "About" read-file))))') or { panic(err) }
	m.run_str('(veb-route "/getting-started" (fn [req] (use (read-file "site/content/getting-started.md") (render-page "Getting started" read-file))))') or { panic(err) }

	mut app := &App{ machine: m }

	for path in ['/', '/about', '/getting-started'] {
		req := http.Request{ method: .get, url: path }
		ctx := veb.render_request[App, Context](mut app, req) or { panic(err) }
		body := ctx.res.body
		// Verify the response contains the layout markers and content.
		if !body.contains('<!DOCTYPE html>') {
			panic('missing layout for ${path}')
		}
		if !body.contains('<link rel="stylesheet" href="/assets/style.css">') {
			panic('missing stylesheet link for ${path}')
		}
		println('response for ${path}: ${body.len} bytes, ok')
	}
	println('veb_server ok')
}
