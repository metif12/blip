module main

// The embed facade gate: every public function of vlib/blip/embed and the new
// machine extension surface is exercised here, which also keeps
// tests/api_coverage.v green (it fails on any pub fn named nowhere).

import vlib.blip
import vlib.blip.embed
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

fn my_double(args []blip.Value) !blip.Value {
	if args.len != 1 {
		return error('my-double needs 1 arg')
	}
	return blip.integer(args[0].as_int() * 2)
}

fn my_steps(mut m machine.Machine, _ []blip.Value) !blip.Value {
	return blip.integer(i64(m.steps))
}

fn main() {
	mut s := Suite{}

	// new + eval + eval_text through the embedded prelude.
	h := host.new_capture()
	mut e := embed.new(h)
	got := e.eval('(+ 1 2)') or {
		s.fail('embed eval', err.msg())
		return
	}
	if printer.write(got) != '3' {
		s.fail('embed eval', 'expected 3, got ${printer.write(got)}')
	} else {
		s.ok('embed eval', '3')
	}
	txt := e.eval_text('(* 3 4)') or {
		s.fail('embed eval_text', err.msg())
		return
	}
	if txt != '12' {
		s.fail('embed eval_text', 'expected 12, got ${txt}')
	} else {
		s.ok('embed eval_text', txt)
	}

	// define + lookup + call + call_named.
	e.define('seven', blip.integer(7))
	lv := e.lookup('seven') or {
		s.fail('embed lookup', 'seven missing')
		return
	}
	if embed.to_int(lv) or { -1 } != 7 {
		s.fail('embed lookup', 'expected 7')
	} else {
		s.ok('embed define+lookup', '7')
	}
	e.eval('(define (quad x) (* 4 x))') or {
		s.fail('embed setup quad', err.msg())
		return
	}
	qv := e.lookup('quad') or {
		s.fail('embed lookup fn', 'quad missing')
		return
	}
	q := e.call(qv, [blip.integer(3)]) or {
		s.fail('embed call', err.msg())
		return
	}
	if embed.to_int(q) or { -1 } != 12 {
		s.fail('embed call', 'expected 12')
	} else {
		s.ok('embed call', '12')
	}
	q2 := e.call_named('quad', [blip.integer(4)]) or {
		s.fail('embed call_named', err.msg())
		return
	}
	if embed.to_int(q2) or { -1 } != 16 {
		s.fail('embed call_named', 'expected 16')
	} else {
		s.ok('embed call_named', '16')
	}
	// machine-level call_value is the same path embed.call wraps.
	direct := e.m.call_value(qv, [blip.integer(2)]) or {
		s.fail('machine call_value', err.msg())
		return
	}
	if embed.to_int(direct) or { -1 } != 8 {
		s.fail('machine call_value', 'expected 8')
	} else {
		s.ok('machine call_value', '8')
	}

	// Pure + ctx prim registration, listing, removal.
	e.register_prim('my-double', my_double)
	if !e.has_prim('my-double') {
		s.fail('embed register_prim', 'missing after register')
	} else {
		s.ok('embed register_prim', 'present')
	}
	d := e.eval('(my-double 21)') or {
		s.fail('embed pure prim', err.msg())
		return
	}
	if embed.to_int(d) or { -1 } != 42 {
		s.fail('embed pure prim', 'expected 42')
	} else {
		s.ok('embed pure prim', '42')
	}
	e.register_ctx_prim('my-steps', my_steps)
	st := e.eval('(my-steps)') or {
		s.fail('embed ctx prim', err.msg())
		return
	}
	if embed.to_int(st) or { -99 } < 0 {
		s.fail('embed ctx prim', 'expected non-negative steps')
	} else {
		s.ok('embed ctx prim', embed.show(st))
	}
	names := e.prim_names()
	if 'my-double' !in names || 'my-steps' !in names {
		s.fail('embed prim_names', 'extensions missing from list')
	} else {
		s.ok('embed prim_names', '${names.len} prims')
	}
	e.unregister_prim('my-double')
	if e.has_prim('my-double') {
		s.fail('embed unregister_prim', 'still present')
	} else {
		s.ok('embed unregister_prim', 'gone')
	}

	// Output capture + clearing.
	e.eval('(print "hello-embed")') or {
		s.fail('embed print', err.msg())
		return
	}
	if e.output().len == 0 {
		s.fail('embed output', 'nothing captured')
	} else {
		s.ok('embed output', e.output().last())
	}
	e.clear_output()
	if e.output().len != 0 {
		s.fail('embed clear_output', 'not cleared')
	} else {
		s.ok('embed clear_output', 'empty')
	}

	// Value helpers.
	if !embed.to_bool(blip.integer(0)) || !embed.to_bool(blip.string('x')) {
		s.fail('embed to_bool', 'truthiness wrong')
	} else {
		s.ok('embed to_bool', 'R5RS: only #f is false')
	}
	if embed.to_float(blip.float(1.5)) or { -1.0 } != 1.5 {
		s.fail('embed to_float', 'wrong')
	} else {
		s.ok('embed to_float', '1.5')
	}
	if embed.to_str(blip.keyword('k')) or { '' } != 'k' {
		s.fail('embed to_str', 'wrong')
	} else {
		s.ok('embed to_str', 'k')
	}
	vv := embed.from_strs(['a', 'b'])
	ss := embed.to_strs(vv) or {
		s.fail('embed to_strs', err.msg())
		return
	}
	if ss != ['a', 'b'] {
		s.fail('embed to_strs', 'round trip failed: ${ss}')
	} else {
		s.ok('embed to_strs/from_strs', ss.join(','))
	}
	tbl := embed.from_table(['host'], [blip.string('x')])
	if embed.show(tbl) != '{:host "x"}' {
		s.fail('embed from_table', embed.show(tbl))
	} else {
		s.ok('embed from_table', embed.show(tbl))
	}
	okv := e.eval('(ok 1)') or {
		s.fail('embed ok setup', err.msg())
		return
	}
	if !embed.is_ok(okv) || embed.is_err(okv) {
		s.fail('embed is_ok/is_err', 'ok misread')
	} else {
		s.ok('embed is_ok/is_err', 'ok')
	}
	inner := embed.ok_value(okv) or {
		s.fail('embed ok_value', err.msg())
		return
	}
	if embed.show(inner) != '1' {
		s.fail('embed ok_value', 'wrong inner: ${embed.show(inner)}')
	} else {
		s.ok('embed ok_value', '1')
	}
	errv := e.eval('(err "boom")') or {
		s.fail('embed err setup', err.msg())
		return
	}
	if !embed.is_err(errv) || embed.is_ok(errv) {
		s.fail('embed is_err', 'err misread')
	} else {
		s.ok('embed is_err', 'err')
	}
	if embed.err_message(errv) or { '' } != 'boom' {
		s.fail('embed err_message', 'wrong message')
	} else {
		s.ok('embed err_message', 'boom')
	}
	if embed.show(blip.integer(9)) != '9' {
		s.fail('embed show', 'wrong')
	} else {
		s.ok('embed show', '9')
	}

	// Error classifiers.
	e.eval('no-such-name-xyz') or {
		if !embed.is_unbound_error(err.msg()) {
			s.fail('embed is_unbound_error', err.msg())
		} else {
			s.ok('embed is_unbound_error', 'unbound')
		}
	}
	e.eval('(define') or {
		if !embed.is_parse_error(err.msg()) {
			s.fail('embed is_parse_error', err.msg())
		} else {
			s.ok('embed is_parse_error', 'parse')
		}
	}
	{
		h2 := host.new_capture()
		mut tiny := embed.new(h2)
		tiny.set_limits(200, 200)
		tiny.eval('(loop i 0 #t i)') or {
			if !embed.is_limit_error(err.msg()) {
				s.fail('embed is_limit_error', err.msg())
			} else {
				s.ok('embed is_limit_error+set_limits', 'limited')
			}
		}
	}

	// Config constructors: file + none + reload.
	{
		h3 := host.new_capture()
		h3.give_file('pre.lip', '(define preloaded 99)')
		mut cfge := embed.new_with_config(h3, embed.Config{
			prelude: .none
		}) or {
			s.fail('embed new_with_config none', err.msg())
			return
		}
		cfge.load_prelude() or {
			s.fail('embed load_prelude', err.msg())
			return
		}
		pv := cfge.eval('(+ 1 1)') or {
			s.fail('embed load_prelude eval', err.msg())
			return
		}
		if embed.show(pv) != '2' {
			s.fail('embed load_prelude', 'eval failed')
		} else {
			s.ok('embed load_prelude', 'prelude reloaded')
		}
		lv2 := cfge.load('pre.lip') or {
			s.fail('embed load', err.msg())
			return
		}
		_ = lv2
		got2 := cfge.eval('preloaded') or {
			s.fail('embed load eval', err.msg())
			return
		}
		if embed.show(got2) != '99' {
			s.fail('embed load', 'expected 99')
		} else {
			s.ok('embed load', '99 via host')
		}
	}
	{
		h4 := host.new_capture()
		h4.give_file('lib/std.lip', '(define std-marker 1)')
		mut file_e := embed.new_with_config(h4, embed.Config{
			prelude:      .file
			prelude_path: 'lib/std.lip'
		}) or {
			s.fail('embed new_with_config file', err.msg())
			return
		}
		mv := file_e.eval('std-marker') or {
			s.fail('embed file prelude', err.msg())
			return
		}
		if embed.show(mv) != '1' {
			s.fail('embed file prelude', 'wrong value')
		} else {
			s.ok('embed new_with_config file', 'file prelude')
		}
	}

	// Sandbox: restrict_to removes IO; fresh interp keeps working.
	{
		h5 := host.new_capture()
		mut box := embed.new(h5)
		removed := box.restrict_to(['+', '-', '*', 'print'])
		if 'read-file' !in removed {
			s.fail('embed restrict_to', 'read-file not removed')
		} else {
			s.ok('embed restrict_to', '${removed.len} removed')
		}
		if box.has_prim('read-file') {
			s.fail('embed sandbox', 'read-file still resolves')
		} else {
			s.ok('embed sandbox', 'read-file gone')
		}
		box.eval('(read-file "x")') or {
			s.ok('embed sandbox eval', 'blocked: ${err.msg()}')
		}
	}

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('embed_api: all checks passed')
}
