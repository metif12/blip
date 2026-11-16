module machine

import blip
import blip.host
import blip.manifest
import blip.prims

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

// capabilities lists every manifest capability this machine knows
// (roadmap E2/E3). Sorted, so `blip env` and error messages print them
// in a stable order.
pub fn capabilities() []string {
	return ['env', 'fs']
}

// capability_prims maps a manifest capability to the prim names it gates.
// v2 knows two: `fs` (file IO) and `env` (environment). Fibers land with
// Track B4; naming one before then is an unknown-feature error, not a
// silent no-op -- a manifest must be exact, and a typo must fail.
pub fn capability_prims(name string) ?[]string {
	match name {
		'fs' {
			return prims.fs_prim_names()
		}
		'env' {
			return prims.env_prim_names()
		}
		else {
			return none
		}
	}
}

// prim_capability names the manifest capability gating a prim, or none
// when the prim is core (always available). The reverse of
// capability_prims, for `blip check` (E2b): the checker reports the use,
// not the switch, so it needs prim -> feature.
pub fn prim_capability(name string) ?string {
	if name in prims.fs_prim_names() {
		return 'fs'
	}
	if name in prims.env_prim_names() {
		return 'env'
	}
	return none
}

// apply_manifest enforces a blip.mod's `(features ...)` stanza (roadmap E2).
// A feature switched OFF removes its prims, so a later use fails cleanly
// as `unbound identifier` rather than running. A feature switched ON (or
// absent, which defaults ON) keeps them. An unknown feature is a hard
// error naming the blip.mod line, because the manifest must be exact and
// the capability does not exist to switch off.
//
// Precedence is manifest < embedder code: an explicit `restrict_to` or
// `register_prim` after this call wins, so the file declares intent and
// code keeps control. The manifest is stored on the machine for E2b
// `blip check`, which names the manifest line in its diagnostic.
pub fn (mut m Machine) apply_manifest(mf manifest.Manifest) ! {
	for name in mf.features.keys() {
		gated := capability_prims(name) or {
			line := mf.feature_line(name)
			if line > 0 {
				return error("blip.mod:${line}: unknown feature '${name}' (known: env, fs)")
			}
			return error("blip.mod: unknown feature '${name}' (known: env, fs)")
		}
		if !mf.features[name] {
			for p in gated {
				m.unregister_prim(p)
			}
		}
	}
	m.applied_manifest = mf
}

// new_standalone_core builds a machine with the minimal core only
// (roadmap E3): arithmetic, collections, strings, and machine builtins
// work, while `fs`/`env` prims are absent from the start rather than
// removed afterwards. An embedder that never wants IO starts here;
// one that wants it conditionally starts from new_standalone and calls
// apply_manifest, or re-adds a capability with enable_fs/enable_env.
pub fn new_standalone_core(h host.Host) &Machine {
	mut m := new_standalone(h)
	for n in prims.fs_prim_names() {
		m.prims.delete(n)
	}
	for n in prims.env_prim_names() {
		m.prims.delete(n)
	}
	m.cache_ok = false
	return m
}

// enable_fs re-adds the `fs` capability after apply_manifest or a
// core-only construction removed it. Precedence stays manifest < code:
// calling this after apply_manifest wins over the file.
pub fn (mut m Machine) enable_fs() {
	fresh := prims.table()
	for n in prims.fs_prim_names() {
		if f := fresh[n] {
			m.prims[n] = f
		}
	}
	m.cache_ok = false
}

// enable_env re-adds the `env` capability after apply_manifest or a
// core-only construction removed it.
pub fn (mut m Machine) enable_env() {
	fresh := prims.table()
	for n in prims.env_prim_names() {
		if f := fresh[n] {
			m.prims[n] = f
		}
	}
	m.cache_ok = false
}
