module machine

import vlib.blip

// CtxPrimFn is a machine-aware primitive: like blip.PrimFn it takes args, but
// it also gets the machine, so it can reach the host, the current env, gensym,
// limits, or veb handlers. Pure functions stay in prims.table; anything that
// needs interpreter state lives here, without a blip<->machine import cycle.
pub type CtxPrimFn = fn (mut m Machine, args []blip.Value) !blip.Value

// register_prim installs or replaces one primitive. Pure prims take only args;
// ctx prims take the machine too. Passing an empty body removes nothing; use
// unregister_prim to delete.
pub fn (mut m Machine) register_prim(name string, f blip.PrimFn) {
	m.cache_ok = false
	m.prims[name] = f
}

pub fn (mut m Machine) register_ctx_prim(name string, f CtxPrimFn) {
	m.cache_ok = false
	m.ctx_prims[name] = f
}

pub fn (mut m Machine) unregister_prim(name string) {
	m.cache_ok = false
	m.prims.delete(name)
	m.ctx_prims.delete(name)
}

pub fn (m &Machine) has_prim(name string) bool {
	return name in m.prims || name in m.ctx_prims || machine_builtin(name)
}

// prim_names lists every callable primitive: ctx extensions first (sorted),
// then pure prims (sorted), then builtins in match order.
pub fn (m &Machine) prim_names() []string {
	mut out := []string{}
	mut ctx := m.ctx_prims.keys()
	ctx.sort()
	for n in ctx {
		out << n
	}
	mut pure := m.prims.keys()
	pure.sort()
	for n in pure {
		out << n
	}
	return out
}

// restrict_to keeps only the named prims (plus machine builtins, which are
// syntax-level and cannot be removed this way). It is the sandbox: an untrusted
// program evaluated after restrict_to cannot reach file IO or the network,
// because those names no longer resolve. Returns the removed names.
pub fn (mut m Machine) restrict_to(keep []string) []string {
	mut removed := []string{}
	for n in m.prims.keys() {
		if n !in keep {
			m.prims.delete(n)
			removed << n
		}
	}
	for n in m.ctx_prims.keys() {
		if n !in keep {
			m.ctx_prims.delete(n)
			removed << n
		}
	}
	removed.sort()
	m.cache_ok = false
	return removed
}
