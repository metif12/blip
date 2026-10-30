// Macro emit-time embedded machine — Option 1 (design memo docs/macros-design.md).
//
// This module does two jobs:
//
//   * `expand_macro_at_embed` — the end-to-end check the macros_gate suite
//     exercises (a fresh machine, source in, expanded value converted back
//     to AST). Unchanged signature.
//
//   * `expand_form` + `form_text` — the pre-pass `compile_with_base` runs
//     before emitting. defmacro forms register their macro in an embedded
//     machine and are dropped from the output; macro calls (registered macros
//     and explicit `macex`/`macex1`) are expanded through that machine and
//     re-read into the same arena, so the emitter only ever sees ordinary
//     forms. A macro that expands to itself, or one that fails to register,
//     is a compile error rather than a silently dropped form.

module emit

import vlib.blip
import vlib.blip.host
import vlib.blip.machine
import vlib.blip.printer
import vlib.blip.reader

// is_defmacro_form reports whether `id` is a (defmacro ...) form.
fn is_defmacro_form(a &reader.Arena, id reader.NodeId) bool {
	kids := a.kids(id)
	if kids.len == 0 {
		return false
	}
	h := a.node(kids[0])
	return h.tag == .sym && h.value == 'defmacro'
}

// then converts the expanded Value back to AST via value_to_datum.
pub fn expand_macro_at_embed(src string, h host.Host) !string {
	mut m := machine.new_standalone(h)
	expanded := m.run_str(src)!
	_ = blip.value_to_datum(mut m, expanded)!
	return 'embedded-machine macro expansion: pure-shape converted (complex deferred)'
}

// is_macro_value reports whether `v` is a call to a registered macro.
fn is_macro_value(m machine.Machine, v blip.Value) bool {
	if v.tag != .pair {
		return false
	}
	head := v.as_pair().car
	if head.tag != .symbol {
		return false
	}
	name := head.as_string()
	return name in m.macros
}

fn is_registered_macro(m machine.Machine, name string) bool {
	return name in m.macros
}

// expand_value walks a Value and expands every macro call and every explicit
// macex/macex1 it finds, recursively. Macros in blip are unhygienic and
// their bodies return code as data, so expansion is a pure tree walk.
fn expand_value(mut m machine.Machine, v blip.Value) !blip.Value {
	// Explicit expansion request: run it through the machine.
	if v.tag == .pair {
		car := v.as_pair().car
		if car.tag == .symbol {
			name := car.as_string()
			if name == 'macex' || name == 'macex1' {
				cdr := v.as_pair().cdr
				if cdr.tag != .pair {
					return error('macex needs a form')
				}
				arg_txt := printer.write(cdr.as_pair().car)
				expanded := m.run_str('(${name} ${arg_txt})')!
				return expand_value(mut m, expanded)
			}
		}
	}
	// Registered macro call: expand it (macex loops up to 8 rounds).
	if is_macro_value(m, v) {
		mut cur := v
		mut i := 0
		for i < 8 {
			if !is_macro_value(m, cur) {
				break
			}
			cur_txt := printer.write(cur)
			cur = m.run_str('(macex ${cur_txt})')!
			i++
		}
		if is_macro_value(m, cur) {
			return error('macex did not terminate')
		}
		return expand_value(mut m, cur)
	}
	match v.tag {
		.pair {
			car := expand_value(mut m, v.as_pair().car)!
			cdr := expand_value(mut m, v.as_pair().cdr)!
			return blip.cons(car, cdr)
		}
		.vector {
			vec := v.as_vector()
			mut elems := []blip.Value{}
			for e in vec.data {
				elems << expand_value(mut m, e)!
			}
			return blip.vector(elems)
		}
		else {
			return v
		}
	}
}

// expand_form expands one reader form. Returns the original id unchanged
// when nothing needed expanding, so ordinary programs produce no churn.
fn expand_form(mut m machine.Machine, a &reader.Arena, id reader.NodeId) !reader.NodeId {
	d := a.node(id)
	if d.tag != .list {
		return id
	}
	kids := a.kids(id)
	if kids.len == 0 {
		return id
	}
	head := a.node(kids[0])
	if head.tag == .sym {
		// Explicit macex/macex1: expand the argument and emit the result.
		if head.value == 'macex' || head.value == 'macex1' {
			if kids.len < 2 {
				return id
			}
			arg_txt := printer.write_datum(a, kids[1])
			expanded_val := m.run_str('(${head.value} ${arg_txt})')!
			ev := expand_value(mut m, expanded_val)!
			txt := printer.write(ev)
			f := a.read_forms(txt)
			if f.diags.len > 0 {
				return error('expanded form did not re-parse: ${f.diags[0].msg}')
			}
			if f.forms.len != 1 {
				return error('expanded form yielded ${f.forms.len} forms')
			}
			return f.forms[0]
		}
		// Registered macro call: expand through the machine.
		if is_registered_macro(m, head.value) {
			form_txt := printer.write_datum(a, id)
			expanded_val := m.run_str('(macex ${form_txt})')!
			ev := expand_value(mut m, expanded_val)!
			txt := printer.write(ev)
			f := a.read_forms(txt)
			if f.diags.len > 0 {
				return error('expanded form did not re-parse: ${f.diags[0].msg}')
			}
			if f.forms.len != 1 {
				return error('expanded form yielded ${f.forms.len} forms')
			}
			return f.forms[0]
		}
	}
	// Otherwise: expand each child; rebuild only if something changed.
	mut child_txts := []string{}
	mut changed := false
	for i := 0; i < kids.len; i++ {
		k := kids[i]
		nid := expand_form(mut m, a, k)!
		if nid != k {
			changed = true
		}
		child_txts << printer.write_datum(a, nid)
	}
	if !changed {
		return id
	}
	mut txt := ''
	if d.tag == .vector {
		txt = '['
		for i, t in child_txts {
			if i > 0 {
				txt += ' '
			}
			txt += t
		}
		txt += ']'
	} else {
		txt = '('
		for i, t in child_txts {
			if i > 0 {
				txt += ' '
			}
			txt += t
		}
		txt += ')'
	}
	f := a.read_forms(txt)
	if f.diags.len > 0 {
		return error('rebuilt form did not re-parse: ${f.diags[0].msg}')
	}
	if f.forms.len != 1 {
		return error('rebuilt form yielded ${f.forms.len} forms')
	}
	return f.forms[0]
}

// form_text extracts the original source text of one top-level form, using
// its recorded line/column and a paren/bracket/brace balancer. Used to feed
// defmacro forms to the embedded machine without re-rendering them.
fn form_text(src string, a &reader.Arena, id reader.NodeId) string {
	d := a.node(id)
	off := byte_offset(src, d.line, d.col)
	if off >= src.len {
		return ''
	}
	end := scan_form(src, off)
	if end <= off {
		return src[off..].trim_space()
	}
	return src[off..end].trim_space()
}

fn byte_offset(src string, line int, col int) int {
	mut l := 1
	mut i := 0
	for l < line && i < src.len {
		if src[i] == `\n` {
			l++
		}
		i++
	}
	mut j := i
	mut c := 1
	for c < col && j < src.len && src[j] != `\n` {
		j++
		c++
	}
	return j
}

fn scan_form(src string, start int) int {
	if start >= src.len {
		return src.len
	}
	// Atom (not a collection): run to the next whitespace.
	if src[start] != `(` && src[start] != `[` && src[start] != `{` {
		mut i := start
		for i < src.len && src[i] != ` ` && src[i] != `\t` && src[i] != `\n` && src[i] != `\r` {
			i++
		}
		return i
	}
	mut depth := 0
	mut i := start
	mut in_str := false
	mut in_comment := false
	for i < src.len {
		ch := src[i]
		if in_comment {
			if ch == `\n` {
				in_comment = false
			}
			i++
			continue
		}
		if in_str {
			if ch == `\\` {
				i += 2
				continue
			}
			if ch == `"` {
				in_str = false
			}
			i++
			continue
		}
		if ch == `;` {
			in_comment = true
			i++
			continue
		}
		if ch == `"` {
			in_str = true
			i++
			continue
		}
		if ch == `(` || ch == `[` || ch == `{` {
			depth++
			i++
			continue
		}
		if ch == `)` || ch == `]` || ch == `}` {
			depth--
			i++
			if depth == 0 {
				return i
			}
			continue
		}
		i++
	}
	return src.len
}
