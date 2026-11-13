module machine

$if !wasm32 {
	import os
}

import strconv
import blip
import blip.host
import blip.prims
import blip.printer
import blip.reader

fn (mut m Machine) eval_import(kids []blip.NodeId) ! {
	if kids.len < 2 {
		return error('import needs a package name: (import owner/repo)')
	}
	d := m.arena.node(kids[1])
	name := d.value.trim_space()
	if name == '' {
		return error('import needs a package name: (import owner/repo)')
	}
	path := m.resolve_module(name) or {
		hint := if name.contains('/') {
			'is it installed? `blip pkg install ${name}`'
		} else {
			'is it installed? `blip pkg list`'
		}
		return error('import: no package named ${name} -- ${hint}')
	}
	m.load(path)!
}

// where labels the current source for an error message.
pub fn (m &Machine) where() string {
	if m.source == '' {
		return 'blip'
	}
	return m.source
}

// decorate_error wraps a runtime error with source context.
//
// The machine knows which form was being evaluated when the error occurred
// (m.form) and the reader recorded that form's position on the node. This
// turns a bare "unbound identifier: foo" into a Rust-style frame showing the
// source line and underlining the token.
//
// Without source text (a form evaluated by eval_one before src_text was set,
// or a synthetic node with no position), the message passes through unchanged.
fn (m &Machine) decorate_error(msg string) string {
	if m.src_text == '' || m.form == blip.no_node {
		return msg
	}
	d := m.arena.node(m.form)
	if d.line == 0 {
		return msg
	}
	mut length := 1
	if msg.starts_with('unbound identifier: ') {
		length = msg.len - 'unbound identifier: '.len
	} else if msg.starts_with('set! cannot assign to unbound identifier: ') {
		prefix := 'set! cannot assign to unbound identifier: '
		length = msg.len - prefix.len
	}
	return blip.format_error(m.where(), m.src_text, d.line, d.col, msg, length)
}

// render_node prints a form back to source, for an error message that has to name
// a pattern or a message string.
pub fn (m &Machine) render_node(n blip.NodeId) string {
	if n == blip.no_node {
		return ''
	}
	return printer.write_datum(m.arena, n)
}

// eval_one evaluates a single form, for the REPL. It resets the control state
// first, so a form that failed to evaluate leaves nothing behind.
fn (mut m Machine) eval_require(kids []blip.NodeId) ! {
	mut paths := []string{}
	// kids[0] is the `require` symbol itself. Scanning it as a clause is how the
	// first version reported "require is not a file path" on a perfectly good
	// require.
	mut i := 1
	for i < kids.len {
		part := m.require_paths(kids[i])
		mut j := 0
		for j < part.len {
			paths << part[j]
			j++
		}
		if part.len == 0 {
			return error('require: ${m.render_node(kids[i])} is not a file path, or a form containing one')
		}
		i++
	}
	if paths.len == 0 {
		return error('require: no file path given')
	}
	mut k := 0
	for k < paths.len {
		full := m.resolve_path(paths[k])
		if !m.already_loaded(full) {
			m.load(full) or {
				return error('require: ${err.msg()}')
			}
			m.loaded << full
		}
		k++
	}
	m.val = blip.nil_value()
	m.ret()
}

// require_paths returns the file paths in one `require` clause.
//
// A clause is a string, or a form whose head is a filter and whose arguments
// include the path: `(only-in "x.vl" a b)`, `(prefix-in p: "x.vl")`. Recursing
// into the form and collecting every string is enough for those, and it
// deliberately does NOT try to understand the filters -- see eval_require's
// comment. It RETURNS the list rather than appending to one the caller passed,
// because a `mut []string` parameter is awkward in V and this is the whole
// function.
fn (m &Machine) require_paths(n blip.NodeId) []string {
	d := m.arena.node(n)
	if d.tag == .str {
		return [d.value]
	}
	if d.tag != .list {
		return []string{}
	}
	mut out := []string{}
	kids := m.arena.kids(n)
	mut i := 0
	for i < kids.len {
		part := m.require_paths(kids[i])
		mut j := 0
		for j < part.len {
			out << part[j]
			j++
		}
		i++
	}
	return out
}

// let => ((lambda (a b) body) e1 e2). The values are evaluated in the enclosing
// scope, which is exactly let semantics, and the result is an ordinary
// application so it needs no new continuation.
//
// A binding may be a PATTERN as well as a name: `(let ([(list h t) '(1 2)]) ...)`.
// It is compiled into a `match` over a temporary, because destructuring is what
// the pattern matcher already knows how to do and writing a second binder for
// lists, tables and structs would be three implementations to keep in step.
pub fn (m &Machine) resolve_path(path string) string {
	if path.starts_with('/') || m.source == '' {
		return path
	}
	// A `..` that climbs out of its own directory used to bypass the join
	// below (paths starting with `.` were returned as-is, i.e. resolved
	// against the working directory), contradicting the documented
	// file-relative guarantee. Join first, then clean lexically.
	base := m.source
	mut cut := -1
	mut i := 0
	for i < base.len {
		c := base[i]
		if c == `/` || c == `\\` {
			cut = i
		}
		i++
	}
	if cut < 0 {
		return clean_path(path)
	}
	return clean_path(base[..cut] + '/' + path)
}

// clean_path lexically resolves `.` and `..` segments, so a require that
// climbs out of its own directory ("../programs/markdown.lip" from
// "site/build.lip") lands where the author meant. Lexical on purpose: no
// filesystem access, no symlink resolution, and `/` and `\` both work on
// either platform.
pub fn clean_path(path string) string {
	is_abs := path.starts_with('/') || (path.len >= 2 && path[1] == `:`)
	mut parts := []string{}
	for seg in path.split('/') {
		for sub in seg.split('\\') {
			if sub == '' || sub == '.' {
				continue
			} else if sub == '..' {
				if parts.len > 0 && parts.last() != '..' && !parts.last().ends_with(':') {
					parts.pop()
				} else if !is_abs {
					parts << '..'
				}
			} else {
				parts << sub
			}
		}
	}
	joined := parts.join('/')
	if is_abs {
		return '/' + joined
	}
	if joined == '' {
		return '.'
	}
	return joined
}

// loaded remembers which paths have already been evaluated in this machine, so a
// file required twice runs once.
//
// Without it, `(require "lib/text.vl")` after `(require (only-in "lib/text.vl"
// ...))` re-evaluates the file and every definition in it is replaced by a
// freshly made one -- which quietly discards any `set!` a caller had made.
fn (m &Machine) already_loaded(path string) bool {
	return path in m.loaded
}
