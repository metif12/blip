// veb_bridge — option 2 of the P5 website plan: veb calls blip.
//
// A blip closure becomes a veb handler. The bridge stores handler closures
// in the machine's veb_handlers map keyed by path; veb's router calls
// veb_dispatch, which runs the closure with the request converted to a blip
// value and converts the response back. No green continuations are needed
// for the request/response round trip: each request re-runs the handler
// closure to completion.
//
// Status: bridge implemented; HTTP server example is the next step.

module machine

import vlib.blip
import vlib.blip.printer

// veb_to_value converts a request's fields into a blip table.
pub fn veb_to_value(method string, path string, body string) blip.Value {
	mut m := map[string]blip.Value{}
	m['method'] = blip.string(method)
	m['path'] = blip.string(path)
	m['body'] = blip.string(body)
	return blip.table(m)
}

// value_to_veb_body extracts the response body from a handler result. A
// string is the body (status 200); a table may carry :status and :body.
pub fn value_to_veb_body(resp blip.Value) string {
	if resp.tag == .string {
		return resp.as_string()
	}
	if resp.tag == .table {
		t := resp.as_table()
		if 'body' in t.values {
			return t.values['body'].as_string()
		}
	}
	return printer.write(resp)
}

// veb_route stores a handler closure under `path` on this machine.
pub fn (mut m Machine) veb_route(path string, handler blip.Value) {
	m.veb_handlers[path] = handler
}

// veb_dispatch runs the handler for `path` with `req` and returns the
// response value. Returns an error value when no handler is registered.
pub fn (mut m Machine) veb_dispatch(path string, req blip.Value) blip.Value {
	handler := m.veb_handlers[path] or {
		return blip.list_from([blip.symbol('err'), blip.string('no handler for ${path}')])
	}
	resp := m.call_value(handler, [req]) or {
		return blip.list_from([blip.symbol('err'), blip.string('handler failed: ${err.msg()}')])
	}
	return resp
}