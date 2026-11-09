module lsp

import json2
$if !wasm32 {
import os
}
import vlib.blip.reader
import vlib.blip.prims

pub struct Position {
pub:
	line      int
	character int
}

pub struct Range {
pub:
	start Position
	end   Position
}

pub struct LspDiagnostic {
pub:
	range    Range
	message  string
	severity int
	source   string
}

pub struct PublishDiagnosticsParams {
pub:
	uri         string
	diagnostics []LspDiagnostic
}

struct PublishNotification {
	jsonrpc string = '2.0'
	method  string = 'textDocument/publishDiagnostics'
	params  PublishDiagnosticsParams
}

struct Incoming {
	method string
	params string
}

struct DidOpenDoc {
	uri         string
	text        string
	language_id ?string @[json: 'languageId']
	version     ?i64
}

struct DidOpenParams {
	text_document DidOpenDoc @[json: 'textDocument']
}

struct VersionedId {
	uri     string
	version ?i64
}

struct ContentChange {
	text         string
	range        ?string
	range_length ?i64 @[json: 'rangeLength']
}

struct DidChangeParams {
	text_document   VersionedId     @[json: 'textDocument']
	content_changes []ContentChange @[json: 'contentChanges']
}

struct UriOnly {
	uri string
}

struct DidCloseParams {
	text_document UriOnly @[json: 'textDocument']
}

struct DidSaveDoc {
	uri string
}

struct DidSaveParams {
	text_document DidSaveDoc @[json: 'textDocument']
	text          ?string
}

struct TextDocId {
	uri string
}

struct HoverParams {
	text_document TextDocId @[json: 'textDocument']
	position      Position
}

struct CompletionParams {
	text_document TextDocId @[json: 'textDocument']
	position      Position
}

struct DefinitionParams {
	text_document TextDocId @[json: 'textDocument']
	position      Position
}

struct ReferencesParams {
	text_document TextDocId @[json: 'textDocument']
	position      Position
}

struct DocumentSymbolParams {
	text_document TextDocId @[json: 'textDocument']
}

struct FormattingParams {
	text_document TextDocId @[json: 'textDocument']
}

pub struct Server {
mut:
	open_files          map[string]string
	capture_output      bool
	captured_output     []string
	is_shutdown         bool
	received_initialize bool
	current_raw_id      string
}

pub fn new_test_server() Server {
	return Server{
		open_files:     map[string]string{}
		capture_output: true
	}
}

pub fn diagnose(src string) []LspDiagnostic {
	res := reader.read_all(src)
	mut out := []LspDiagnostic{}
	for d in res.diags {
		line := if d.line - 1 > 0 { d.line - 1 } else { 0 }
		ch := if d.col - 1 > 0 { d.col - 1 } else { 0 }
		out << LspDiagnostic{
			range:    Range{
				start: Position{
					line:      line
					character: ch
				}
				end:   Position{
					line:      line
					character: ch + 1
				}
			}
			message:  d.msg
			severity: 1
			source:   'blip'
		}
	}
	return out
}

pub fn (mut s Server) captured() []string {
	return s.captured_output
}

fn (mut s Server) send_framed(content string) {
	msg := 'Content-Length: ${content.len}\r\n\r\n${content}'
	if s.capture_output {
		s.captured_output << msg
		return
	}
	print(msg)
	flush_stdout()
}

fn (mut s Server) send_result(raw_id string, result_json string) {
	s.send_framed('{"jsonrpc":"2.0","id":${raw_id},"result":${result_json}}')
}

fn (mut s Server) send_error(raw_id string, code int, message string) {
	id := if raw_id == '' { 'null' } else { raw_id }
	s.send_framed('{"jsonrpc":"2.0","id":${id},"error":{"code":${code},"message":${json2.encode(message)}}}')
}

fn (mut s Server) publish(uri string, diags []LspDiagnostic) {
	mut sb := '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":'
	sb += json2.encode(uri)
	sb += ',"diagnostics":['
	for i, d in diags {
		if i > 0 {
			sb += ','
		}
		sb += '{"range":{"start":{"line":${d.range.start.line},"character":${d.range.start.character}},"end":{"line":${d.range.end.line},"character":${d.range.end.character}}},"severity":${d.severity},"message":'
		sb += json2.encode(d.message)
		sb += ',"source":'
		sb += json2.encode(d.source)
		sb += '}'
	}
	sb += ']}}'
	s.send_framed(sb)
}

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
	return c in [`-`, `+`, `*`, `/`, `=`, `<`, `>`, `?`, `!`, `$`, `%`, `&`, `^`, `~`, `_`, `.`, `:`]
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
	return Position{line: line, character: col}
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
			form:     pp_form(res.arena, id, 0)
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
		'quasiquote', 'unquote', 'unquote-splice', 'set!', 'and', 'or', 'cond', 'case', 'do',
		'while', 'match', 'define-syntax', 'syntax-rules', 'let-syntax', 'letrec-syntax']
}

fn primitive_names() []string {
	mut out := []string{}
	for k, _ in prims.table() {
		out << k
	}
	out.sort()
	return out
}

fn pp_form(a &reader.Arena, id reader.NodeId, depth int) string {
	d := a.node(id)
	match d.tag {
		.nil { return 'nil' }
		.bool { return if d.i == 1 { '#t' } else { '#f' } }
		.int { return d.i.str() }
		.float { return d.f.str() }
		.str { return quote_string(d.value) }
		.sym { return d.value }
		.kw { return ':' + d.value }
		.list {
			kids := a.kids(id)
			if kids.len == 0 {
				return '()'
			}
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			line := '(' + parts.join(' ') + ')'
			if line.len <= 80 {
				return line
			}
			mut s := '('
			for i, p in parts {
				if i == 0 {
					s += p
				} else {
					s += '\n' + '  '.repeat(depth + 1) + p
				}
			}
			s += ')'
			return s
		}
		.vector {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			return '[' + parts.join(' ') + ']'
		}
		.table {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1) + ' ' + pp_form(a, kids[ki + 1], depth + 1)
				ki += 2
			}
			return '{' + parts.join(' ') + '}'
		}
		.array {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			return '@[' + parts.join(' ') + ']'
		}
		.bytes {
			kids := a.kids(id)
			mut parts := []string{}
			mut ki := 0
			for ki < kids.len {
				parts << pp_form(a, kids[ki], depth + 1)
				ki++
			}
			return '#(' + parts.join(' ') + ')'
		}
		.quoted {
			kids := a.kids(id)
			if kids.len == 0 {
				return "'()"
			}
			return "'" + pp_form(a, kids[0], depth)
		}
		.quasi {
			kids := a.kids(id)
			if kids.len == 0 {
				return '`()'
			}
			return '`' + pp_form(a, kids[0], depth)
		}
		.unquote {
			kids := a.kids(id)
			if kids.len == 0 {
				return ',()'
			}
			return ',' + pp_form(a, kids[0], depth)
		}
		.unquote_splice {
			kids := a.kids(id)
			if kids.len == 0 {
				return ',@()'
			}
			return ',@' + pp_form(a, kids[0], depth)
		}
		else {
			return '#<datum>'
		}
	}
}

fn quote_string(s string) string {
	mut sb := '"'
	for ch in s.runes() {
		match ch {
			`"` { sb += '\\"' }
			`\\` { sb += '\\\\' }
			`\n` { sb += '\\n' }
			`\r` { sb += '\\r' }
			`\t` { sb += '\\t' }
			else { sb += ch.str() }
		}
	}
	sb += '"'
	return sb
}

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
			out << pp_form(res.arena, sig[i], 0)
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
	struct Tok { line int; col int; len int; typ int }
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
			toks << Tok{line: line, col: col, len: j - i, typ: 5}
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
			toks << Tok{line: line0, col: col0, len: j - i, typ: 5}
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
			toks << Tok{line: line, col: col, len: j - i, typ: 4}
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
			toks << Tok{line: line, col: col, len: j - i, typ: 3}
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
			toks << Tok{line: line, col: col, len: j - i, typ: typ}
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

pub fn (mut s Server) handle(content string) bool {
	msg := json2.decode[Incoming](content) or { return false }
	method := msg.method
	raw := extract_raw_id(content) or { '' }
	s.current_raw_id = raw
	has_id := raw != ''
	if s.is_shutdown {
		if method == 'exit' {
			return true
		}
		if has_id {
			s.send_error(raw, -32600, 'Server has been shut down')
		}
		return false
	}
	if method == 'exit' {
		return true
	}
	if method == 'shutdown' {
		s.is_shutdown = true
		if has_id {
			s.send_result(raw, 'null')
		}
		return false
	}
	if !s.received_initialize && method != 'initialize' {
		if has_id {
			s.send_error(raw, -32002, 'Server not yet initialized')
		}
		return false
	}
	if method == 'initialize' {
		if s.received_initialize {
			if has_id {
				s.send_error(raw, -32600, 'Server already initialized')
			}
			return false
		}
		s.received_initialize = true
		if has_id {
			s.send_result(raw, '{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"hoverProvider":true,"completionProvider":{"triggerCharacters":[" ","("]},"definitionProvider":true,"referencesProvider":true,"documentSymbolProvider":true,"documentFormattingProvider":true,"signatureHelpProvider":{"triggerCharacters":[" ","("]},"documentHighlightProvider":true,"foldingRangeProvider":true,"renameProvider":true,"prepareRenameProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","function","variable","number","string","comment","operator"],"tokenModifiers":[]},"full":true}},"serverInfo":{"name":"blip","version":"0.1.0"}}')
		}
		return false
	}
	if method == 'initialized' {
		return false
	}
	if method == '$/setTrace' || method == '$/cancelRequest' || method == 'workspace/didChangeConfiguration' {
		return false
	}
	if method == 'textDocument/didOpen' {
		p := json2.decode[DidOpenParams](msg.params) or { return false }
		s.open_files[p.text_document.uri] = p.text_document.text
		s.publish(p.text_document.uri, diagnose(p.text_document.text))
		return false
	}
	if method == 'textDocument/didChange' {
		p := json2.decode[DidChangeParams](msg.params) or { return false }
		if p.content_changes.len > 0 {
			text := p.content_changes.last().text
			s.open_files[p.text_document.uri] = text
			s.publish(p.text_document.uri, diagnose(text))
		}
		return false
	}
	if method == 'textDocument/didClose' {
		p := json2.decode[DidCloseParams](msg.params) or { return false }
		s.open_files.delete(p.text_document.uri)
		s.publish(p.text_document.uri, []LspDiagnostic{})
		return false
	}
	if method == 'textDocument/didSave' {
		p := json2.decode[DidSaveParams](msg.params) or { return false }
		if t := s.open_files[p.text_document.uri] {
			s.publish(p.text_document.uri, diagnose(t))
		} else if txt := p.text {
			s.publish(p.text_document.uri, diagnose(txt))
		}
		return false
	}

	if method == 'textDocument/hover' {
		p := json2.decode[HoverParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		w := word_at(text, off)
		mut result := 'null'
		if w != '' {
			if di := find_define(text, w) {
				doc := doc_for_line(text, di.line)
				mut body := ''
				if doc != '' {
					body = doc + '\n\n'
				}
				body += '```blip\n' + di.form + '\n```'
				escaped := json2.encode(body)
				result = '{"contents":{"kind":"markdown","value":' + escaped + '}}'
			} else if w in primitive_names() {
				result = '{"contents":{"kind":"markdown","value":"primitive `' + w + '`"}}'
			}
		}
		if has_id {
			s.send_result(raw, result)
		}
		return false
	}

	if method == 'textDocument/completion' {
		p := json2.decode[CompletionParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		mut items := ''
		mut first := true
		for name in special_forms() {
			if !first { items += ',' }
			first = false
			items += '{"label":' + json2.encode(name) + ',"kind":14}'
		}
		for name in primitive_names() {
			if !first { items += ',' }
			first = false
			items += '{"label":' + json2.encode(name) + ',"kind":3,"detail":"primitive"}'
		}
		for di in top_defines(text) {
			if !first { items += ',' }
			first = false
			items += '{"label":' + json2.encode(di.name) + ',"kind":3,"detail":"definition"}'
		}
		if has_id {
			s.send_result(raw, '{"isIncomplete":false,"items":[' + items + ']}')
		}
		return false
	}

	if method == 'textDocument/definition' {
		p := json2.decode[DefinitionParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		w := word_at(text, off)
		mut result := 'null'
		if w != '' {
			if di := find_define(text, w) {
				start_line := if di.line - 1 >= 0 { di.line - 1 } else { 0 }
				start_ch := if di.col - 1 >= 0 { di.col - 1 } else { 0 }
				end_ch := start_ch + w.len
				result = '{"uri":' + json2.encode(p.text_document.uri) + ',"range":{"start":{"line":' + start_line.str() + ',"character":' + start_ch.str() + '},"end":{"line":' + start_line.str() + ',"character":' + end_ch.str() + '}}}'
			}
		}
		if has_id {
			s.send_result(raw, result)
		}
		return false
	}

	if method == 'textDocument/references' {
		p := json2.decode[ReferencesParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		w := word_at(text, off)
		mut arr := ''
		mut first := true
		if w != '' {
			for pos in occurrences(text, w) {
				if !first { arr += ',' }
				first = false
				end_ch := pos.character + w.len
				arr += '{"uri":' + json2.encode(p.text_document.uri) + ',"range":{"start":{"line":' + pos.line.str() + ',"character":' + pos.character.str() + '},"end":{"line":' + pos.line.str() + ',"character":' + end_ch.str() + '}}}'
			}
		}
		if has_id {
			s.send_result(raw, '[' + arr + ']')
		}
		return false
	}

	if method == 'textDocument/documentSymbol' {
		p := json2.decode[DocumentSymbolParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		mut arr := ''
		mut first := true
		for di in top_defines(text) {
			start_line := if di.line - 1 >= 0 { di.line - 1 } else { 0 }
			start_ch := if di.col - 1 >= 0 { di.col - 1 } else { 0 }
			end_ch := start_ch + di.name.len
			if !first { arr += ',' }
			first = false
			arr += '{"name":' + json2.encode(di.name) + ',"kind":12,"range":{"start":{"line":' + start_line.str() + ',"character":' + start_ch.str() + '},"end":{"line":' + start_line.str() + ',"character":' + end_ch.str() + '}},"selectionRange":{"start":{"line":' + start_line.str() + ',"character":' + start_ch.str() + '},"end":{"line":' + start_line.str() + ',"character":' + end_ch.str() + '}}}'
		}
		if has_id {
			s.send_result(raw, '[' + arr + ']')
		}
		return false
	}

	if method == 'textDocument/signatureHelp' {
		p := json2.decode[HoverParams](msg.params) or {
			// reuse hover params shape (textDocument + position)
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		name := enclosing_call_name(text, off)
		mut result := 'null'
		if name != '' {
			params := function_params(text, name)
			mut plist := ''
			mut pfirst := true
			for pm in params {
				if !pfirst { plist += ',' }
				pfirst = false
				plist += '{"label":' + json2.encode(pm) + '}'
			}
			mut label := '(' + name
			for pm in params {
				label += ' ' + pm
			}
			label += ')'
			active := active_parameter_index(text, off)
			result = '{"signatures":[{"label":' + json2.encode(label) + ',"parameters":[' + plist + ']}],"activeSignature":0,"activeParameter":' + active.str() + '}'
		}
		if has_id {
			s.send_result(raw, result)
		}
		return false
	}

	if method == 'textDocument/documentHighlight' {
		p := json2.decode[HoverParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		w := word_at(text, off)
		mut arr := ''
		mut first := true
		if w != '' {
			for pos in occurrences(text, w) {
				if !first { arr += ',' }
				first = false
				end_ch := pos.character + w.len
				arr += '{"range":{"start":{"line":' + pos.line.str() + ',"character":' + pos.character.str() + '},"end":{"line":' + pos.line.str() + ',"character":' + end_ch.str() + '}},"kind":1}'
			}
		}
		if has_id {
			s.send_result(raw, '[' + arr + ']')
		}
		return false
	}

	if method == 'textDocument/foldingRange' {
		p := json2.decode[DocumentSymbolParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		res := reader.read_all(text)
		mut arr := ''
		mut first := true
		for id in res.forms {
			d := res.arena.node(id)
			start_line := if d.line - 1 >= 0 { d.line - 1 } else { 0 }
			// find end line by scanning? use start line only; LSP requires endLine >= startLine
			end_line := start_line
			if !first { arr += ',' }
			first = false
			arr += '{"startLine":' + start_line.str() + ',"endLine":' + end_line.str() + '}'
		}
		if has_id {
			s.send_result(raw, '[' + arr + ']')
		}
		return false
	}

	if method == 'textDocument/prepareRename' {
		p := json2.decode[HoverParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		w := word_at(text, off)
		mut result := 'null'
		if w != '' && is_ident_char(w[0]) {
			// find position of word
			// recompute start offset of word
			mut start := off
			if start >= text.len && text.len > 0 { start = text.len - 1 }
			if start >= 0 && !is_ident_char(text[start]) && start > 0 { start-- }
			for start > 0 && is_ident_char(text[start - 1]) { start-- }
			ws := offset_to_pos(text, start)
			we := offset_to_pos(text, start + w.len)
			result = '{"range":{"start":{"line":' + ws.line.str() + ',"character":' + ws.character.str() + '},"end":{"line":' + we.line.str() + ',"character":' + we.character.str() + '}},"placeholder":' + json2.encode(w) + '}'
		}
		if has_id {
			s.send_result(raw, result)
		}
		return false
	}

	if method == 'textDocument/rename' {
		// params: textDocument, position, newName
		struct RenameParams { text_document TextDocId @[json: 'textDocument']; position Position; new_name string @[json: 'newName'] }
		p := json2.decode[RenameParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		old := word_at(text, off)
		mut edits := ''
		mut first := true
		if old != '' {
			for pos in occurrences(text, old) {
				if !first { edits += ',' }
				first = false
				end_ch := pos.character + old.len
				edits += '{"range":{"start":{"line":' + pos.line.str() + ',"character":' + pos.character.str() + '},"end":{"line":' + pos.line.str() + ',"character":' + end_ch.str() + '}},"newText":' + json2.encode(p.new_name) + '}'
			}
		}
		if has_id {
			s.send_result(raw, '{"changes":{' + json2.encode(p.text_document.uri) + ':[' + edits + ']}}')
		}
		return false
	}

	if method == 'textDocument/semanticTokens/full' {
		p := json2.decode[DocumentSymbolParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		data := semantic_token_data(text)
		mut arr := ''
		mut first := true
		for n in data {
			if !first { arr += ',' }
			first = false
			arr += n.str()
		}
		if has_id {
			s.send_result(raw, '{"data":[' + arr + ']}')
		}
		return false
	}

	if method == 'textDocument/formatting' {
		p := json2.decode[FormattingParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		mut result := '[]'
		res := reader.read_all(text)
		if res.diags.len == 0 && text.len > 0 {
			mut out := ''
			for i, id in res.forms {
				if i > 0 {
					out += '\n\n'
				}
				out += pp_form(res.arena, id, 0)
			}
			out += '\n'
			end_pos := offset_to_pos(text, text.len)
			end_line := end_pos.line
			end_ch := end_pos.character
			result = '[{"range":{"start":{"line":0,"character":0},"end":{"line":' + end_line.str() + ',"character":' + end_ch.str() + '}},"newText":' + json2.encode(out) + '}]'
		}
		if has_id {
			s.send_result(raw, result)
		}
		return false
	}

	if method == 'textDocument/codeAction' || method == 'textDocument/codeLens' || method == 'textDocument/inlayHint' || method == 'textDocument/documentLink' || method == 'textDocument/onTypeFormatting' || method == 'textDocument/willSaveWaitUntil' {
		if has_id {
			s.send_result(raw, '[]')
		}
		return false
	}

	if method == 'textDocument/rangeFormatting' {
		p := json2.decode[FormattingParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		mut result := '[]'
		res := reader.read_all(text)
		if res.diags.len == 0 && text.len > 0 {
			mut out := ''
			for i, id in res.forms {
				if i > 0 { out += '\n\n' }
				out += pp_form(res.arena, id, 0)
			}
			out += '\n'
			end_pos := offset_to_pos(text, text.len)
			result = '[{"range":{"start":{"line":0,"character":0},"end":{"line":' + end_pos.line.str() + ',"character":' + end_pos.character.str() + '}},"newText":' + json2.encode(out) + '}]'
		}
		if has_id { s.send_result(raw, result) }
		return false
	}

	if method == 'textDocument/selectionRange' {
		p := json2.decode[HoverParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		w := word_at(text, off)
		mut start := off
		if start >= text.len && text.len > 0 { start = text.len - 1 }
		if start >= 0 && !is_ident_char(text[start]) && start > 0 { start-- }
		for start > 0 && is_ident_char(text[start - 1]) { start-- }
		ws := offset_to_pos(text, start)
		we := offset_to_pos(text, start + w.len)
		mut result := '[]'
		if w != '' {
			result = '[{"range":{"start":{"line":' + ws.line.str() + ',"character":' + ws.character.str() + '},"end":{"line":' + we.line.str() + ',"character":' + we.character.str() + '}}}]'
		}
		if has_id { s.send_result(raw, result) }
		return false
	}

	if method == 'textDocument/linkedEditingRange' {
		p := json2.decode[HoverParams](msg.params) or {
			if has_id { s.send_error(raw, -32700, 'Parse error') }
			return false
		}
		text := s.open_files[p.text_document.uri] or { '' }
		off := pos_to_offset(text, p.position)
		w := word_at(text, off)
		mut ranges := ''
		mut first := true
		if w != '' {
			for pos in occurrences(text, w) {
				if !first { ranges += ',' }
				first = false
				end_ch := pos.character + w.len
				ranges += '{"start":{"line":' + pos.line.str() + ',"character":' + pos.character.str() + '},"end":{"line":' + pos.line.str() + ',"character":' + end_ch.str() + '}}'
			}
		}
		if has_id {
			s.send_result(raw, '{"ranges":[' + ranges + ']}')
		}
		return false
	}

	if method == 'workspace/symbol' {
		// search across open files
		mut arr := ''
		mut first := true
		for uri, text in s.open_files {
			for di in top_defines(text) {
				start_line := if di.line - 1 >= 0 { di.line - 1 } else { 0 }
				start_ch := if di.col - 1 >= 0 { di.col - 1 } else { 0 }
				end_ch := start_ch + di.name.len
				if !first { arr += ',' }
				first = false
				arr += '{"name":' + json2.encode(di.name) + ',"kind":12,"location":{"uri":' + json2.encode(uri) + ',"range":{"start":{"line":' + start_line.str() + ',"character":' + start_ch.str() + '},"end":{"line":' + start_line.str() + ',"character":' + end_ch.str() + '}}}}'
			}
		}
		if has_id {
			s.send_result(raw, '[' + arr + ']')
		}
		return false
	}

	if method == 'workspace/executeCommand' {
		if has_id {
			s.send_result(raw, 'null')
		}
		return false
	}

	if has_id {
		s.send_error(raw, -32601, 'Method not found: ${method}')
	}
	return false
}

struct StdinReader {
	fd int
mut:
	buf []u8
	off int
	len int
}

$if wasm32 {
fn (mut r StdinReader) fill() bool {
	return false
}
} $else {
fn (mut r StdinReader) fill() bool {
	if r.buf.len == 0 {
		r.buf = []u8{len: 65536}
	}
	data, n := os.fd_read(r.fd, r.buf.len)
	if n <= 0 {
		return false
	}
	r.len = n
	r.off = 0
	for i in 0 .. n {
		r.buf[i] = data[i]
	}
	return true
}
}

fn (mut r StdinReader) read_byte() ?u8 {
	if r.off >= r.len {
		if !r.fill() {
			return none
		}
	}
	b := r.buf[r.off]
	r.off++
	return b
}

fn (mut r StdinReader) read_line() ?string {
	mut out := []u8{}
	for {
		b := r.read_byte() or { return none }
		if b == `\n` {
			break
		}
		out << b
	}
	mut s := out.bytestr()
	if s.ends_with('\r') {
		s = s[..s.len - 1]
	}
	return s
}

fn (mut r StdinReader) read_exact(n int) ?string {
	mut out := []u8{cap: n}
	for out.len < n {
		if r.off >= r.len {
			if !r.fill() {
				return none
			}
		}
		need := n - out.len
		avail := r.len - r.off
		take := if need < avail { need } else { avail }
		out << r.buf[r.off..r.off + take]
		r.off += take
	}
	return out.bytestr()
}

fn read_request(mut r StdinReader) ?string {
	mut length := -1
	for {
		line := r.read_line() or { return none }
		t := line.trim_space()
		if t == '' {
			break
		}
		low := t.to_lower()
		if low.starts_with('content-length:') {
			length = t.all_after(':').trim_space().int()
		}
	}
	if length < 0 {
		return ''
	}
	return r.read_exact(length)
}

pub fn serve() {
	mut s := Server{
		open_files: map[string]string{}
	}
	mut r := StdinReader{
		fd: 0
	}
	for {
		content := read_request(mut r) or { break }
		if content == '' {
			continue
		}
		if s.handle(content) {
			break
		}
	}
}
