module emit

$if !wasm32 {
	import os
}

import vlib.blip
import vlib.blip.host
import vlib.blip.machine
import vlib.blip.reader

fn (mut e Emitter) collect_paths(nodes []reader.NodeId) []string {
	mut out := []string{}
	mut i := 0
	for i < nodes.len {
		d := e.node(nodes[i])
		if d.tag == .str {
			out << d.value
		} else if d.tag == .list {
			kids := e.kids(nodes[i])
			mut j := 0
			for j < kids.len {
				part := e.collect_paths([kids[j]])
				mut p := 0
				for p < part.len {
					out << part[p]
					p++
				}
				j++
			}
		}
		i++
	}
	return out
}

fn (mut e Emitter) resolve_path(path string) string {
	if path.starts_with('/') || e.base == '' {
		return path
	}
	// Same guarantee as the machine: relative requires resolve against the
	// requiring file, `..` included. See machine/mod.v clean_path.
	mut cut := -1
	mut i := 0
	for i < e.base.len {
		c := e.base[i]
		if c == `/` || c == `\\` {
			cut = i
		}
		i++
	}
	if cut < 0 {
		if e.base == '' {
			return path
		}
		return machine.clean_path(e.base + '/' + path)
	}
	return machine.clean_path(e.base[..cut] + '/' + path)
}

fn (mut e Emitter) compile_module(src string, base string) ![]string {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		return error('module has diagnostics')
	}
	mut me := Emitter{
		arena:        &res.arena
		top:          map[string]bool{}
		mangled:      map[string]string{}
		collided:     map[string]string{}
		takes_kwargs: map[string]bool{}
		base:         base
		loaded:       e.loaded
	}
	for id in res.forms {
		me.remember(id)
	}
	for id in res.forms {
		me.form(id)
	}
	if me.blocked.len > 0 {
		for b in me.blocked {
			e.refuse(b)
		}
	}
	return me.out.clone()
}

fn compile_with_base(src string, base string) !Result {
	mut res := reader.read_all(src)
	if res.diags.len > 0 {
		d := res.diags[0]
		return error('${d.line}:${d.col}: ${d.msg}')
	}
	// Macro pre-pass: defmacro forms register their macro in an embedded
	// machine and are dropped from the output; macro calls (registered
	// macros and explicit macex/macex1) are expanded through that machine
	// and re-read, so the emitter only ever sees ordinary forms. A macro
	// that expands to itself, or one that fails to register, is a compile
	// error rather than a silently dropped form.
	mut mach := machine.new_machine_with(&res.arena, host.new_capture())
	mut expanded_forms := []reader.NodeId{}
	for id in res.forms {
		if is_defmacro_form(res.arena, id) {
			txt := form_text(src, res.arena, id)
			mach.run_str(txt) or {
				return error('macro registration failed: ${err.msg()}')
			}
			continue
		}
		nid := expand_form(mut mach, res.arena, id) or {
			return error('macro expansion failed: ${err.msg()}')
		}
		expanded_forms << nid
	}
	res.forms = expanded_forms
	mut e := Emitter{
		arena:        &res.arena
		top:          map[string]bool{}
		mangled:      map[string]string{}
		collided:     map[string]string{}
		takes_kwargs: map[string]bool{}
		base:         base
		loaded:       map[string]bool{}
	}
	// Two passes, because a function may refer to a name defined later in the
	// file -- ordinary in blip, impossible in a `const` declaration.
	for id in res.forms {
		e.remember(id)
	}
	for id in res.forms {
		e.form(id)
	}
	// The runtime comes first in the TEXT even though it is emitted last, so the
	// generated module is self-contained: one file, runnable by node as it is.
	mut body := e.out.clone()
	e.out = []
	e.emit(prelude)
	e.out << ''
	for line in body {
		e.out << line
	}
	return Result{
		js:      e.out.join('\n')
		blocked: e.blocked
	}
}

// push_local records one binding under its blip name and the identifier that
// holds it.
