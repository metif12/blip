module main

import veb
import net.http
import blip.machine
import blip.host

struct App {
mut:
	machine &machine.Machine
}

struct Context {
	veb.Context
}

@['/']
pub fn (mut app App) index(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/', machine.veb_to_value(ctx.req.method.str(), ctx.req.url,
		ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

@['/about']
pub fn (mut app App) about(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/about', machine.veb_to_value(ctx.req.method.str(),
		ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

@['/getting-started']
pub fn (mut app App) getting_started(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/getting-started', machine.veb_to_value(ctx.req.method.str(),
		ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

@['/tour']
pub fn (mut app App) tour(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/tour', machine.veb_to_value(ctx.req.method.str(),
		ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

@['/cli']
pub fn (mut app App) cli(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/cli', machine.veb_to_value(ctx.req.method.str(),
		ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

@['/embedding']
pub fn (mut app App) embedding(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/embedding', machine.veb_to_value(ctx.req.method.str(),
		ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

@['/status']
pub fn (mut app App) status(mut ctx Context) veb.Result {
	resp := app.machine.veb_dispatch('/status', machine.veb_to_value(ctx.req.method.str(),
		ctx.req.url, ctx.req.data))
	body := machine.value_to_veb_body(resp)
	return ctx.text(body)
}

fn main() {
	mut m := machine.new_standalone(host.ConsoleHost{})
	m.load('lib/std.lip') or { panic(err) }
	// Handlers render the same Markdown sources the static site uses, so
	// served pages and deployed pages cannot drift apart.
	m.run_str('(require "programs/markdown.lip")') or { panic(err) }
	m.run_str('(define (render-page title md-text) (use (read-file "site/layout.html") (string-replace (string-replace read-file "{{title}}" title) "{{body}}" (md-render (string-split md-text "\n")))))') or {
		panic(err)
	}
	m.run_str('(veb-route "/" (fn [req] (use (read-file "site/content/index.md") (render-page "blip — a Lisp dialect in V" read-file))))') or {
		panic(err)
	}
	m.run_str('(veb-route "/about" (fn [req] (use (read-file "site/content/about.md") (render-page "About — blip" read-file))))') or {
		panic(err)
	}
	m.run_str('(veb-route "/getting-started" (fn [req] (use (read-file "site/content/getting-started.md") (render-page "Getting started — blip" read-file))))') or {
		panic(err)
	}
	m.run_str('(veb-route "/tour" (fn [req] (use (read-file "site/content/tour.md") (render-page "The tour — blip" read-file))))') or {
		panic(err)
	}
	m.run_str('(veb-route "/cli" (fn [req] (use (read-file "site/content/cli.md") (render-page "CLI reference — blip" read-file))))') or {
		panic(err)
	}
	m.run_str('(veb-route "/embedding" (fn [req] (use (read-file "site/content/embedding.md") (render-page "Embedding — blip" read-file))))') or {
		panic(err)
	}
	m.run_str('(veb-route "/status" (fn [req] (use (read-file "site/content/status.md") (render-page "Status — blip" read-file))))') or {
		panic(err)
	}

	mut app := &App{
		machine: m
	}

	for path in ['/', '/about', '/getting-started', '/tour', '/cli', '/embedding', '/status'] {
		// Stock 0.5.2 veb has no render_request test helper, so drive the
		// route methods with a hand-built context: same handlers a live
		// server would call, same assertions on what they write.
		mut ctx := Context{}
		ctx.req = http.Request{
			method: .get
			url:    path
		}
		match path {
			'/' { app.index(mut ctx) }
			'/about' { app.about(mut ctx) }
			'/getting-started' { app.getting_started(mut ctx) }
			'/tour' { app.tour(mut ctx) }
			'/cli' { app.cli(mut ctx) }
			'/embedding' { app.embedding(mut ctx) }
			'/status' { app.status(mut ctx) }
			else { panic('no route for ${path}') }
		}

		body := ctx.res.body
		// Verify the response contains the layout markers and content.
		if !body.contains('<!DOCTYPE html>') {
			panic('missing layout for ${path}')
		}
		if !body.contains('<link rel="stylesheet" href="/assets/style.css">') {
			panic('missing stylesheet link for ${path}')
		}
		if path == '/' && !body.contains('<h1>blip</h1>') {
			panic('markdown was not rendered for ${path}')
		}
		println('response for ${path}: ${body.len} bytes, ok')
	}
	println('veb_server ok')
}
