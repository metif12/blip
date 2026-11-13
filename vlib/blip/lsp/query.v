module lsp

$if !wasm32 {
	import os
}

import blip.reader
import blip.prims
import blip.printer
import strings

fn extract_raw_id(content string) ?string {
	key := '"id"'
	idx := content.index(key) or { return none }
	mut i := idx + key.len
	for i < content.len && (content[i] == ` ` || content[i] == `\t` || content[i] == `\n` || content[i] == `\r` || content[i] == `:`) {
		i++
	}
	if i >= content.len {
		return none
	}
	if content[i] == `"` {
		mut j := i + 1
		for j < content.len {
			if content[j] == `\\` {
				j += 2
				continue
			}
			if content[j] == `"` {
				return content[i..j + 1]
			}
			j++
		}
		return none
	}
	mut j := i
	for j < content.len && content[j] != `,` && content[j] != `}` && content[j] != ` ` && content[j] != `\t` && content[j] != `\n` && content[j] != `\r` {
		j++
	}
	tok := content[i..j].trim_space()
	if tok == '' {
		return none
	}
	return tok
}

// ---------- helpers ----------

fn is_ident_char(c u8) bool {
	if (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`) {
		return true
	}
	return c in [`-`, `+`, `*`, `/`, `=`, `<`, `>`, `?`, `!`, `$`, `%`, `&`, `^`, `~`, `_`, `.`,
		`:`]
}

fn line_starts(text string) []int {
	mut res := [0]
	for i, c in text {
		if c == `\n` {
			res << i + 1
		}
	}
	return res
}

fn pos_to_offset(text string, pos Position) int {
	starts := line_starts(text)
	if pos.line < 0 || pos.line >= starts.len {
		return -1
	}
	mut off := starts[pos.line] + pos.character
	if off < 0 {
		off = 0
	}
	if off > text.len {
		off = text.len
	}
	return off
}

fn offset_to_pos(text string, off int) Position {
	mut line := 0
	mut col := 0
	mut i := 0
	for i < off && i < text.len {
		if text[i] == `\n` {
			line++
			col = 0
		} else {
			col++
		}
		i++
	}
	return Position{ line: line, character: col }
}

fn word_at(text string, raw_off int) string {
	mut off := raw_off
	if off < 0 {
		return ''
	}
	if off >= text.len && text.len > 0 {
		off = text.len - 1
	}
	if off < 0 {
		return ''
	}
	if !is_ident_char(text[off]) {
		if off > 0 && is_ident_char(text[off - 1]) {
			off--
		} else {
			return ''
		}
	}
	mut start := off
	mut end := off + 1
	for start > 0 && is_ident_char(text[start - 1]) {
		start--
	}
	for end < text.len && is_ident_char(text[end]) {
		end++
	}
	if end <= start {
		return ''
	}
	return text[start..end]
}

struct DefineInfo {
	name     string
	line     int
	col      int
	end_line int
	end_col  int
	form     string
}

fn top_defines(text string) []DefineInfo {
	res := reader.read_all(text)
	mut out := []DefineInfo{}
	for id in res.forms {
		d := res.arena.node(id)
		if d.tag != .list {
			continue
		}
		kids := res.arena.kids(id)
		if kids.len < 2 {
			continue
		}
		head := res.arena.node(kids[0])
		if head.tag != .sym {
			continue
		}
		if head.value != 'define' && head.value != 'def' {
			continue
		}
		name_node := res.arena.node(kids[1])
		mut name := ''
		mut n := name_node
		if name_node.tag == .sym {
			name = name_node.value
		} else if name_node.tag == .list {
			sig := res.arena.kids(kids[1])
			if sig.len > 0 {
				sn := res.arena.node(sig[0])
				if sn.tag == .sym {
					name = sn.value
					n = sn
				}
			}
		}
		if name == '' {
			continue
		}
		out << DefineInfo{
			name:     name
			line:     n.line
			col:      n.col
			end_line: n.line
			end_col:  n.col + name.len
			form:     printer.pp_form(res.arena, id, 0)
		}
	}
	return out
}

fn find_define(text string, name string) ?DefineInfo {
	for di in top_defines(text) {
		if di.name == name {
			return di
		}
	}
	return none
}

fn occurrences(text string, word string) []Position {
	mut out := []Position{}
	if word == '' {
		return out
	}
	mut i := 0
	n := text.len
	wl := word.len
	for i < n {
		if i + wl <= n && text[i..i + wl] == word {
			// boundary check
			left_ok := i == 0 || !is_ident_char(text[i - 1])
			right_ok := i + wl == n || !is_ident_char(text[i + wl])
			if left_ok && right_ok {
				out << offset_to_pos(text, i)
			}
		}
		i++
	}
	return out
}

fn special_forms() []string {
	return ['define', 'def', 'if', 'lambda', 'fn', 'let', 'let*', 'letrec', 'begin', 'quote',
		'quasiquote', 'unquote', 'unquote-splice', 'set!', 'and', 'or', 'cond', 'case', 'do', 'while',
		'match', 'define-syntax', 'syntax-rules', 'let-syntax', 'letrec-syntax']
}

fn primitive_names() []string {
	mut out := []string{}
	for k, _ in prims.table() {
		out << k
	}
	out.sort()
	return out
}

// format_text pretty-prints every form in text, or returns none when the
// file has diagnostics or is empty. Both formatting endpoints share it so
// the two cannot drift apart.
fn enclosing_call_name(text string, off int) string {
	mut depth := 0
	for i := off - 1; i >= 0; i-- {
		c := text[i]
		if c == `)` {
			depth++
		} else if c == `(` {
			if depth == 0 {
				// parse name
				mut j := i + 1
				for j < text.len && (text[j] == ` ` || text[j] == `\t` || text[j] == `\n` || text[j] == `\r`) {
					j++
				}
				mut start := j
				for j < text.len && is_ident_char(text[j]) {
					j++
				}
				if j > start {
					return text[start..j]
				}
				return ''
			}
			depth--
		}
	}
	return ''
}

fn function_params(text string, name string) []string {
	res := reader.read_all(text)
	mut out := []string{}
	for id in res.forms {
		d := res.arena.node(id)
		if d.tag != .list {
			continue
		}
		kids := res.arena.kids(id)
		if kids.len < 2 {
			continue
		}
		head := res.arena.node(kids[0])
		if head.tag != .sym || (head.value != 'define' && head.value != 'def') {
			continue
		}
		target := res.arena.node(kids[1])
		if target.tag != .list {
			continue
		}
		sig := res.arena.kids(kids[1])
		if sig.len == 0 {
			continue
		}
		sn := res.arena.node(sig[0])
		if sn.tag != .sym || sn.value != name {
			continue
		}
		for i in 1 .. sig.len {
			out << printer.pp_form(res.arena, sig[i], 0)
		}
	}
	return out
}

fn active_parameter_index(text string, off int) int {
	// find open paren
	mut open := -1
	mut depth := 0
	for i := off - 1; i >= 0; i-- {
		c := text[i]
		if c == `)` {
			depth++
		} else if c == `(` {
			if depth == 0 {
				open = i
				break
			}
			depth--
		}
	}
	if open < 0 {
		return 0
	}
	mut active := 0
	mut d := 0
	mut in_token := false
	for j in open + 1 .. off {
		if j >= text.len {
			break
		}
		c := text[j]
		if c == `(` || c == `[` || c == `{` {
			d++
			in_token = false
		} else if c == `)` || c == `]` || c == `}` {
			if d > 0 {
				d--
			}
		} else if d == 0 {
			if c == ` ` || c == `\t` || c == `\n` || c == `\r` {
				in_token = false
			} else if !in_token {
				active++
				in_token = true
			}
		}
	}
	if active <= 0 {
		return 0
	}
	return active - 1
}

fn semantic_token_data(text string) []int {
	mut data := []int{}
	defs := top_defines(text)
	mut def_names := map[string]bool{}
	for di in defs {
		def_names[di.name] = true
	}
	prim_names := primitive_names()
	mut special := map[string]bool{}
	for sf in special_forms() {
		special[sf] = true
	}
	mut prim_set := map[string]bool{}
	for pn in prim_names {
		prim_set[pn] = true
	}

	// collect tokens: (line, start_char, length, type)
	struct Tok {
		line int
		col  int
		len  int
		typ  int
	}
	mut toks := []Tok{}
	mut i := 0
	n := text.len
	mut line := 0
	mut col := 0
	for i < n {
		c := text[i]
		if c == `\n` {
			line++
			col = 0
			i++
			continue
		}
		if c == ` ` || c == `\t` || c == `\r` {
			col++
			i++
			continue
		}
		// line comment
		if c == `;` && (i + 1 >= n || text[i + 1] != `|`) {
			// comment to end of line
			mut j := i
			for j < n && text[j] != `\n` {
				j++
			}
			toks << Tok{ line: line, col: col, len: j - i, typ: 5 }
			// advance
			for k in i .. j {
				if text[k] == `\n` {
					line++
					col = 0
				} else {
					col++
				}
			}
			i = j
			continue
		}
		// block comment #| ... |# (nesting)
		if c == `#` && i + 1 < n && text[i + 1] == `|` {
			mut depth := 1
			mut j := i + 2
			col += 2
			line0 := line
			col0 := col - 2
			for j < n && depth > 0 {
				if j + 1 < n && text[j] == `#` && text[j + 1] == `|` {
					depth++
					j += 2
					col += 2
					continue
				}
				if j + 1 < n && text[j] == `|` && text[j + 1] == `#` {
					depth--
					j += 2
					col += 2
					continue
				}
				if text[j] == `\n` {
					line++
					col = 0
				} else {
					col++
				}
				j++
			}
			toks << Tok{ line: line0, col: col0, len: j - i, typ: 5 }
			i = j
			continue
		}
		// string
		if c == `"` {
			mut j := i + 1
			mut cc := col + 1
			mut ll := line
			for j < n {
				if text[j] == `\\` {
					j += 2
					cc += 2
					continue
				}
				if text[j] == `"` {
					j++
					cc++
					break
				}
				if text[j] == `\n` {
					ll++
					cc = 0
				} else {
					cc++
				}
				j++
			}
			toks << Tok{ line: line, col: col, len: j - i, typ: 4 }
			// advance line/col
			for k in i .. j {
				if text[k] == `\n` {
					line++
					col = 0
				} else {
					col++
				}
			}
			i = j
			continue
		}
		// number: starts with digit or sign followed by digit
		if (c >= `0` && c <= `9`) || ((c == `+` || c == `-`) && i + 1 < n && text[i + 1] >= `0` && text[i + 1] <= `9`) {
			mut j := i
			for j < n && (is_ident_char(text[j]) || text[j] == `/` || text[j] == `.`) {
				// stop at delimiters
				if text[j] == `(` || text[j] == `)` || text[j] == `[` || text[j] == `]` || text[j] == `{` || text[j] == `}` || text[j] == ` ` || text[j] == `\t` || text[j] == `\n` || text[j] == `\r` || text[j] == `;` || text[j] == `"` {
					break
				}
				j++
			}
			toks << Tok{ line: line, col: col, len: j - i, typ: 3 }
			for k in i .. j {
				if text[k] == `\n` {
					line++
					col = 0
				} else {
					col++
				}
			}
			i = j
			continue
		}
		// identifier
		if is_ident_char(c) {
			mut j := i
			for j < n && is_ident_char(text[j]) {
				j++
			}
			word := text[i..j]
			mut typ := 2 // variable
			if word in special {
				typ = 0 // keyword
			} else if word in prim_set || word in def_names {
				typ = 1 // function
			}
			toks << Tok{ line: line, col: col, len: j - i, typ: typ }
			for k in i .. j {
				if text[k] == `\n` {
					line++
					col = 0
				} else {
					col++
				}
			}
			i = j
			continue
		}
		// other
		col++
		i++
	}

	// build delta encoding sorted by position
	// insertion sort by line then col (V's sort only takes a single < / >)
	mut ti := 1
	for ti < toks.len {
		mut key := toks[ti]
		mut tj := ti - 1
		for tj >= 0 && (toks[tj].line > key.line || (toks[tj].line == key.line && toks[tj].col > key.col)) {
			toks[tj + 1] = toks[tj]
			tj--
		}
		toks[tj + 1] = key
		ti++
	}
	mut prev_line := 0
	mut prev_col := 0
	mut first_tok := true
	for t in toks {
		mut delta_line := t.line
		mut delta_col := t.col
		if !first_tok {
			if t.line == prev_line {
				delta_line = 0
				delta_col = t.col - prev_col
			} else {
				delta_col = t.col
			}
		}
		first_tok = false
		prev_line = t.line
		prev_col = t.col
		data << delta_line
		data << delta_col
		data << t.len
		data << t.typ
		data << 0
	}
	return data
}

fn doc_for_line(text string, def_line_1based int) string {
	lines := text.split('\n')
	mut idx := def_line_1based - 2 // line before definition (0-indexed)
	mut collected := []string{}
	for idx >= 0 && idx < lines.len {
		trimmed := lines[idx].trim_space()
		if trimmed.starts_with(';;') {
			collected << trimmed[2..].trim_space()
			idx--
		} else if trimmed == '' {
			// allow one blank line? stop to be safe
			break
		} else {
			break
		}
	}
	// reverse
	mut out := ''
	mut i := collected.len - 1
	for i >= 0 {
		if out != '' {
			out += '\n'
		}
		out += collected[i]
		i--
	}
	return out
}
