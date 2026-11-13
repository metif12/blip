// clib/blip.v -- the C ABI behind clib/blip.h.
//
// Build: v -shared -cc gcc -o libblip.so clib/blib.v        (linux)
//        v -shared -cc msvc -o blip.dll clib/blip.v         (windows)
// Then link the smoke test / your program against it; see docs/c-lib.md.
//
// Boundary rules, enforced by construction rather than convention:
//   * Only C types cross: voidptr (as BlipInterp*), &char, int. No V string,
//     slice, map or interface ever leaves this file.
//   * Strings into V are borrowed (cstring_to_vstring, read-only, never
//     stored). Strings out of V are C.malloc copies the caller frees with
//     blip_free_str. V's own string memory (.str of a V string) is GC-managed
//     and must never reach C.free -- freeing it corrupts the heap at exit.
//   * The interpreter pointer is GC-managed V memory (Boehm does not move,
//     so the address is stable). blip_free_interp drops the reference; the
//     runtime reclaims it. Nothing here calls free on V memory.

module clib

import os
import vlib.blip
import vlib.blip.embed

struct CState {
mut:
	out []string
}

struct CHost {
	state &CState
}

fn (c &CHost) host_print(s string) {
	unsafe {
		c.state.out << s
	}
}

fn (c &CHost) host_write(s string) {
	unsafe {
		c.state.out << s
	}
}

fn (c &CHost) host_read_line() ?string {
	return none
}

fn (c &CHost) host_load(path string) !string {
	return os.read_file(path)
}

// cstrdup copies a V string into C heap memory (NUL included: V strings are
// NUL-terminated). The caller owns it and frees it with C.free, i.e. with
// blip_free_str from C.
fn cstrdup(s string) &char {
	n := s.len
	p := unsafe { &char(C.malloc(n + 1)) }
	if p == 0 {
		panic('blip: out of memory')
	}
	unsafe { C.memcpy(p, s.str, n + 1) }
	return p
}

fn set_out(out &&char, s string) {
	unsafe { out[0] = cstrdup(s) }
}

fn argv_to_v(argv &&char, n int) []string {
	mut res := []string{cap: n}
	for i in 0 .. n {
		p := unsafe { argv[i] }
		if isnil(p) {
			res << ''
		} else {
			res << unsafe { cstring_to_vstring(p) }
		}
	}
	return res
}

@[export: 'blip_new']
pub fn blip_new() voidptr {
	st := &CState{}
	h := &CHost{
		state: st
	}
	e := embed.new(h)
	return voidptr(e)
}

@[export: 'blip_free_interp']
pub fn blip_free_interp(ip voidptr) {
	if ip == 0 {
		return
	}
	mut e := unsafe { &embed.Interp(ip) }
	e.clear_output()
}

@[export: 'blip_eval']
pub fn blip_eval(ip voidptr, src &char, out &&char) int {
	if ip == 0 || isnil(src) || isnil(out) {
		return 1
	}
	mut e := unsafe { &embed.Interp(ip) }
	code := unsafe { cstring_to_vstring(src) }
	v := e.eval(code) or {
		set_out(out, err.msg())
		return 1
	}
	set_out(out, embed.show(v))
	return 0
}

@[export: 'blip_load']
pub fn blip_load(ip voidptr, path &char, out &&char) int {
	if ip == 0 || isnil(path) || isnil(out) {
		return 1
	}
	mut e := unsafe { &embed.Interp(ip) }
	p := unsafe { cstring_to_vstring(path) }
	v := e.load(p) or {
		set_out(out, err.msg())
		return 1
	}
	set_out(out, embed.show(v))
	return 0
}

@[export: 'blip_call']
pub fn blip_call(ip voidptr, name &char, argv &&char, argc int, out &&char) int {
	if ip == 0 || isnil(name) || isnil(out) {
		return 1
	}
	if argc < 0 || (argc > 0 && isnil(argv)) {
		set_out(out, 'blip_call: NULL argv with argc > 0')
		return 1
	}
	mut e := unsafe { &embed.Interp(ip) }
	nm := unsafe { cstring_to_vstring(name) }
	args := argv_to_v(argv, argc)
	mut vals := []blip.Value{cap: args.len}
	for a in args {
		// Each argument is evaluated as a blip expression, so C callers can
		// pass literals ("21", "[1 2]", ":kw") and variable names alike.
		vals << e.eval(a) or {
			set_out(out, err.msg())
			return 1
		}
	}
	res := e.call_named(nm, vals) or {
		set_out(out, err.msg())
		return 1
	}
	set_out(out, embed.show(res))
	return 0
}

@[export: 'blip_set_limits']
pub fn blip_set_limits(ip voidptr, max_steps int, max_kont int) {
	if ip == 0 {
		return
	}
	mut e := unsafe { &embed.Interp(ip) }
	e.set_limits(max_steps, max_kont)
}

@[export: 'blip_output']
pub fn blip_output(ip voidptr, out &&char) int {
	if ip == 0 || isnil(out) {
		return -1
	}
	mut e := unsafe { &embed.Interp(ip) }
	lines := e.output()
	n := lines.len
	set_out(out, lines.join('\n'))
	e.clear_output()
	return n
}

@[export: 'blip_restrict']
pub fn blip_restrict(ip voidptr, keep &&char, nkeep int) int {
	if ip == 0 {
		return -1
	}
	if nkeep < 0 || (nkeep > 0 && isnil(keep)) {
		return -1
	}
	mut e := unsafe { &embed.Interp(ip) }
	names := argv_to_v(keep, nkeep)
	removed := e.restrict_to(names)
	return removed.len
}

@[export: 'blip_version']
pub fn blip_version() &char {
	// Static storage: the caller must NOT free this.
	// Keep in sync with `const version` in blip.v.
	return c'0.1.0'
}

@[export: 'blip_free_str']
pub fn blip_free_str(s &char) {
	if isnil(s) {
		return
	}
	unsafe { C.free(s) }
}
