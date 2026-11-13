module embed

// The embedding facade: one import, one struct, no arena plumbing.
//
// An embedder otherwise wires four modules by hand (reader arena, machine,
// host, printer) and learns three facts the hard way: the arena must outlive
// every closure, the prelude must load before user code, and a second machine
// needs a second host. Interp hides all three: it owns its machine (which owns
// its arena), it loads the prelude on construction, and each Interp takes its
// own host.
//
// Pure blip fns stay in prims; stateful extensions use register_ctx_prim,
// which sees the machine (host, env, limits) instead of only its args.
// Untrusted code runs after restrict_to keeps only the names it may use.

import blip
import blip.host
import blip.machine
import blip.printer

// Embedded prelude: the same lib/std.lip `blip run` loads, compiled into the
// embedder so there is no path to resolve and no file to ship. A file-based
// prelude is still available via Config{prelude: .file}.
const embedded_std = $embed_file('../../../lib/std.lip').to_string()

pub enum PreludeMode {
	embedded
	file
	none
}

pub struct Config {
pub:
	max_steps    int
	max_kont     int
	prelude      PreludeMode = .embedded
	prelude_path string      = 'lib/std.lip'
}

@[heap]
pub struct Interp {
pub mut:
	m &machine.Machine
}

// new builds an interpreter with the embedded prelude and default limits. The
// prelude is trusted: a failure to load it is ignored rather than surfaced,
// because there is nothing the embedder could do about it.
pub fn new(h host.Host) &Interp {
	mut e := &Interp{
		m: machine.new_standalone(h)
	}
	e.m.run_str(embedded_std) or {}
	return e
}

// new_with_config builds an interpreter honoring cfg. max_steps/max_kont of 0
// keep the machine defaults; prelude .file loads prelude_path through the
// host (an error surfaces), .none skips the prelude, .embedded uses the
// compiled-in copy.
pub fn new_with_config(h host.Host, cfg Config) !&Interp {
	mut e := &Interp{
		m: machine.new_standalone(h)
	}
	if cfg.max_steps > 0 {
		e.m.max_steps = cfg.max_steps
	}
	if cfg.max_kont > 0 {
		e.m.max_kont = cfg.max_kont
	}
	match cfg.prelude {
		.embedded {
			e.m.run_str(embedded_std)!
		}
		.file {
			e.m.load(cfg.prelude_path)!
		}
		.none {}
	}
	return e
}

// load_prelude evaluates the embedded standard library into the running
// machine. new/new_with_config already do this; it exists for interpreters
// that started with prelude .none and changed their mind.
pub fn (mut e Interp) load_prelude() !blip.Value {
	return e.m.run_str(embedded_std)
}

// eval parses and evaluates src in the running machine and returns the last
// value. Definitions accumulate across calls.
pub fn (mut e Interp) eval(src string) !blip.Value {
	return e.m.run_str(src)
}

// eval_text evaluates src and renders the result the way print would.
pub fn (mut e Interp) eval_text(src string) !string {
	return show(e.eval(src)!)
}

// call invokes a closure (or primitive) value with args, run to completion.
pub fn (mut e Interp) call(f blip.Value, args []blip.Value) !blip.Value {
	return e.m.call_value(f, args)
}

// call_named resolves name in the current env and calls it. It reports
// "unbound identifier" exactly like a program reference would.
pub fn (mut e Interp) call_named(name string, args []blip.Value) !blip.Value {
	f := e.lookup(name) or {
		return error('unbound identifier: ${name}')
	}
	return e.call(f, args)
}

// define binds name to val in the globals, visible to later evals.
pub fn (mut e Interp) define(name string, val blip.Value) {
	e.m.envs.define(e.m.globals, name, val)
	e.m.cache_ok = false
}

// lookup resolves name in the current env chain, or none.
pub fn (mut e Interp) lookup(name string) ?blip.Value {
	return e.m.envs.lookup(e.m.env, name)
}

// load reads path through the host and evaluates it in the running machine.
pub fn (mut e Interp) load(path string) !blip.Value {
	return e.m.load(path)
}

// set_limits bounds untrusted code. Zero keeps the current value.
pub fn (mut e Interp) set_limits(max_steps int, max_kont int) {
	if max_steps > 0 {
		e.m.max_steps = max_steps
	}
	if max_kont > 0 {
		e.m.max_kont = max_kont
	}
}

// output is everything print/display wrote since the last clear_output.
pub fn (mut e Interp) output() []string {
	return e.m.out
}

pub fn (mut e Interp) clear_output() {
	e.m.out = []string{}
}

// register_prim installs a pure primitive; register_ctx_prim a machine-aware
// one (host/env/limits visible). Either replaces the same-named entry.
pub fn (mut e Interp) register_prim(name string, f blip.PrimFn) {
	e.m.register_prim(name, f)
}

pub fn (mut e Interp) register_ctx_prim(name string, f machine.CtxPrimFn) {
	e.m.register_ctx_prim(name, f)
}

pub fn (mut e Interp) unregister_prim(name string) {
	e.m.unregister_prim(name)
}

pub fn (mut e Interp) has_prim(name string) bool {
	return e.m.has_prim(name)
}

pub fn (mut e Interp) prim_names() []string {
	return e.m.prim_names()
}

// restrict_to is the sandbox: only the kept names still resolve. Builtins
// handled inside the machine (apply/error/...) stay; everything else named
// and missing is gone. Returns the removed names.
pub fn (mut e Interp) restrict_to(keep []string) []string {
	return e.m.restrict_to(keep)
}

// ---- value helpers ---------------------------------------------------------

// show renders a value the way print would.
pub fn show(v blip.Value) string {
	return printer.write(v)
}

pub fn to_bool(v blip.Value) bool {
	return v.truthy()
}

// to_int answers the integer (or rune code point), or an error.
pub fn to_int(v blip.Value) !i64 {
	return v.as_int() or { return error(err.msg()) }
}

pub fn to_float(v blip.Value) !f64 {
	return v.as_float() or { return error(err.msg()) }
}

// to_str answers the string/symbol/keyword/primitive payload, or an error.
pub fn to_str(v blip.Value) !string {
	return v.as_string() or { return error(err.msg()) }
}

// to_strs reads a vector/list of strings into V strings.
pub fn to_strs(v blip.Value) ![]string {
	mut out := []string{}
	if v.tag == .vector || v.tag == .array {
		vec := v.as_vector() or { return error(err.msg()) }
		for item in vec.data {
			out << item.as_string() or { return error(err.msg()) }
		}
		return out
	}
	if v.tag == .pair || v.tag == .emptylist {
		mut cur := v
		for cur.tag == .pair {
			pair_v := cur.as_pair() or { return error(err.msg()) }
			out << pair_v.car.as_string() or { return error(err.msg()) }
			cur = pair_v.cdr
		}
		return out
	}
	return error('to_strs: called on a ${v.tag}, not a sequence')
}

pub fn from_strs(items []string) blip.Value {
	mut vals := []blip.Value{cap: items.len}
	for s in items {
		vals << blip.string(s)
	}
	return blip.vector(vals)
}

// from_table builds an immutable table from parallel keys/values.
pub fn from_table(keys []string, vals []blip.Value) blip.Value {
	mut m := map[string]blip.Value{}
	mut i := 0
	for i < keys.len && i < vals.len {
		m[keys[i]] = vals[i]
		i++
	}
	return blip.table(m)
}

// is_ok/is_err read the (ok v)/(err why) shapes the prelude uses.
pub fn is_ok(v blip.Value) bool {
	if v.tag != .pair {
		return false
	}
	pair_v := v.as_pair() or { return false }
	head := pair_v.car
	if head.tag != .symbol {
		return false
	}
	s := head.as_string() or { return false }
	return s == 'ok'
}

pub fn is_err(v blip.Value) bool {
	if v.tag != .pair {
		return false
	}
	pair_v := v.as_pair() or { return false }
	head := pair_v.car
	if head.tag != .symbol {
		return false
	}
	s := head.as_string() or { return false }
	return s == 'err'
}

pub fn ok_value(v blip.Value) !blip.Value {
	if !is_ok(v) {
		return error('ok_value: not an (ok ...) result')
	}
	rest := (v.as_pair() or { return error(err.msg()) }).cdr
	if rest.tag == .pair {
		return (rest.as_pair() or { return error(err.msg()) }).car
	}
	return blip.nil_value()
}

pub fn err_message(v blip.Value) !string {
	if !is_err(v) {
		return error('err_message: not an (err ...) result')
	}
	rest := (v.as_pair() or { return error(err.msg()) }).cdr
	if rest.tag == .pair {
		inner := (rest.as_pair() or { return error(err.msg()) }).car
		if inner.tag in [.string, .symbol, .keyword] {
			return inner.as_string() or { return error(err.msg()) }
		}
		return show(inner)
	}
	return ''
}

// ---- error classifiers ------------------------------------------------------

// The machine reports errors as strings; these read the three shapes an
// embedder branches on. Parse errors carry a line:col from format_error;
// unbound names and limits are plain messages.
pub fn is_unbound_error(err string) bool {
	return err.contains('unbound identifier')
}

pub fn is_limit_error(err string) bool {
	return err.contains('step limit exceeded') || err.contains('continuation too deep')
}

pub fn is_parse_error(err string) bool {
	return err.contains('unexpected byte') || err.contains('unclosed') || err.contains('unterminated')
}
