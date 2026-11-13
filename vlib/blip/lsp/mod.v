module lsp

import json2

$if !wasm32 {
	import os
}

import vlib.blip.reader
import vlib.blip.prims
import vlib.blip.printer
import strings

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
		struct RenameParams {
			text_document TextDocId @[json: 'textDocument']
			position      Position
			new_name      string @[json: 'newName']
		}
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
		mut sb := strings.new_builder(data.len * 4)
		mut first := true
		for n in data {
			if !first { sb.write_string(',') }
			first = false
			sb.write_string(n.str())
		}
		if has_id {
			s.send_result(raw, '{"data":[' + sb.str() + ']}')
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
		if out := format_text(text) {
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
		if out := format_text(text) {
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
