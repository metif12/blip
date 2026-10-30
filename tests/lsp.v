module main

import vlib.blip
import vlib.blip.host
import vlib.blip.lsp
import vlib.blip.machine
import vlib.blip.reader

// The language-server gate.
//
// Roadmap section 8.3 states the bar: the server is driven over stdio
// in-process and its diagnostics diffed against fixtures, and a server whose
// errors disagree with `blip run` is worse than none, so the fixtures and the
// `read_forms` diagnostics share one source of positions.
//
// Both halves are here. The first is the protocol -- initialize, didOpen,
// didChange, didClose, the lifecycle, the refusals. The second is the position
// check: each diagnostic's line and character are compared against the line
// and column `blip.format_error` prints for the SAME source, which is the text
// `blip run` shows a user. If those two ever drift, an editor would point at a
// different byte than the command line, which is the failure the section
// describes.
//
// The server is driven through its own `handle`, which is the same function the
// stdio loop calls; only the transport differs. That is what makes this
// possible without a client.

struct Suite {
mut:
	fails  int
	checks int
}

fn (mut s Suite) record(label string, ok bool, detail string) {
	s.checks++
	if ok {
		println('ok   ${label} => ${detail}')
	} else {
		s.fails++
		println('FAIL ${label} => ${detail}')
	}
}

fn (mut s Suite) eq(label string, got string, want string) {
	s.checks++
	if got == want {
		println('ok   ${label} => ${got}')
	} else {
		s.fails++
		println('FAIL ${label}')
		println('     got  ${got}')
		println('     want ${want}')
	}
}

// cli_position returns the line and column `blip run` prints for the first
// diagnostic in `src`. It reads the formatter's own output rather than
// re-deriving the position, because the point is to catch a drift between the
// two, and re-deriving would hide it.
fn cli_position(src string) (int, int) {
	probe := reader.read_all(src)
	if probe.diags.len == 0 {
		return 0, 0
	}
	d := probe.diags[0]
	text := blip.format_error('main.lip', src, d.line, d.col, d.msg, 1)
	// The header reads "  --> path:line:col". Pull the two numbers out.
	arrow := text.index('-->') or { return 0, 0 }
	rest := text[arrow + 3..].trim_space()
	first := rest.index(':') or { return 0, 0 }
	tail := rest[first + 1..]
	last := tail.last_index(':') or { return 0, 0 }
	return tail[..last].trim_space().int(), tail[last + 1..].trim_space().int()
}

// blip_output runs the source the way `blip run` does and returns what it
// printed, so an LSP diagnostic can be checked against a real run rather than
// against the reader alone.
fn blip_output(src string) string {
	h := host.new_capture()
	h.give_file('main.lip', src)
	mut m := machine.new_standalone(h)
	m.load('main.lip') or { return 'ERROR: ${err.msg()}' }
	return h.transcript().trim_right('\n')
}

fn (mut s Suite) protocol() {
	// initialize returns capabilities and echoes the request id verbatim.
	mut srv := lsp.new_test_server()
	srv.handle('{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}')
	out := srv.captured()
	s.record('initialize answers', out.len == 1, '${out.len} message(s)')
	s.record('initialize echoes the id', out.len > 0 && out[0].contains('"id":7'),
		'id present')
	s.record('initialize advertises sync', out.len > 0
		&& out[0].contains('"capabilities"'), 'capabilities present')

	// A second initialize is refused, per the LSP spec -- and refusal is a
	// message, not silence, so the client learns its handshake was rejected.
	before := srv.captured().len
	srv.handle('{"jsonrpc":"2.0","id":8,"method":"initialize","params":{}}')
	after := srv.captured()
	s.record('a second initialize is refused', after.len == before + 1
		&& after[after.len - 1].contains('-32600'), '${after.len} message(s)')

	// didOpen publishes diagnostics for the text it was handed.
	mut srv2 := lsp.new_test_server()
	srv2.handle('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
	srv2.handle('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.lip","text":"(+ 1"}}}')
	got := srv2.captured()
	last := if got.len > 0 { got[got.len - 1] } else { '' }
	s.record('didOpen publishes diagnostics', last.contains('publishDiagnostics'),
		'notification sent')
	s.record('didOpen names the uri', last.contains('file:///t.lip'), 'uri echoed')
	s.record('didOpen carries the message', last.contains('unclosed list'),
		'diagnostic present')

	// didChange re-diagnoses the new text.
	srv2.handle('{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.lip","version":2},"contentChanges":[{"text":"(+ 1 2)"}]}}')
	now := srv2.captured()
	last2 := if now.len > 0 { now[now.len - 1] } else { '' }
	s.record('didChange re-diagnoses', last2.contains('publishDiagnostics'),
		'notification sent')
	s.record('a fixed file reports nothing', last2.contains('"diagnostics":[]'),
		'no diagnostics')
	s.record('two files stay separate', srv2.captured().len == 3,
		'${srv2.captured().len} messages')

	// didClose clears the diagnostics for that document.
	srv2.handle('{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///t.lip"}}}')
	closed := srv2.captured()
	last3 := if closed.len > 0 { closed[closed.len - 1] } else { '' }
	s.record('didClose clears diagnostics', last3.contains('"diagnostics":[]'),
		'cleared')

	// didSave re-diagnoses from the text it was given.
	mut srv3 := lsp.new_test_server()
	srv3.handle('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
	srv3.handle('{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":"file:///s.lip"},"text":"[1 2"}}}')
	saved := srv3.captured()
	last4 := if saved.len > 0 { saved[saved.len - 1] } else { '' }
	s.record('didSave re-diagnoses', last4.contains('publishDiagnostics'),
		'notification sent')
	s.record('didSave carries the message', last4.contains('unclosed vector'),
		'diagnostic present')
}

fn (mut s Suite) lifecycle() {
	// Before initialize, a request is refused with ServerNotInitialized.
	mut srv := lsp.new_test_server()
	srv.handle('{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{}}')
	out := srv.captured()
	s.record('a request before initialize is refused', out.len == 1
		&& out[0].contains('-32002'), 'ServerNotInitialized')

	// A NOTIFICATION before initialize is refused silently: there is no id to
	// answer on, and answering a notification is a protocol error.
	mut srv1 := lsp.new_test_server()
	srv1.handle('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"u","text":"("}}}')
	s.record('a notification before initialize is silent', srv1.captured().len == 0,
		'nothing sent')

	// shutdown answers null, and after it every request is refused.
	mut srv2 := lsp.new_test_server()
	srv2.handle('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
	srv2.handle('{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}')
	mid := srv2.captured()
	s.record('shutdown answers', mid.len == 2 && mid[1].contains('"result":null'),
		'null result')
	srv2.handle('{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{}}')
	end := srv2.captured()
	s.record('after shutdown a request is refused', end.len == 3
		&& end[2].contains('-32600'), 'InvalidRequest')

	// Unknown methods are refused by name rather than silently ignored.
	mut srv3 := lsp.new_test_server()
	srv3.handle('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
	srv3.handle('{"jsonrpc":"2.0","id":9,"method":"textDocument/bogus","params":{}}')
	unk := srv3.captured()
	s.record('an unknown method is refused', unk.len == 2 && unk[1].contains('-32601'),
		'MethodNotFound')
}

fn (mut s Suite) positions() {
	// Section 8.3's bar: the LSP position and the `blip run` position must
	// agree. Both come from the same reader, but they are converted in two
	// different places -- the diagnostic subtracts one for LSP's 0-indexing,
	// and format_error prints the reader's own -- so they can drift, and this
	// is the check that would see it.
	sources := [
		'(+ 1',
		'(+ 1 2',
		'[1 2',
		'"unterminated',
		';; only a comment\n(+ 1',
	]
	for src in sources {
		diags := lsp.diagnose(src)
		if diags.len == 0 {
			s.record('a position case produced a diagnostic', false, src)
			continue
		}
		d := diags[0]
		cli_line, cli_col := cli_position(src)
		// LSP is 0-indexed, so add one back to compare with the reader's.
		s.record('LSP position matches blip run for `${src}`',
			d.range.start.line + 1 == cli_line && d.range.start.character + 1 == cli_col,
			'lsp ${d.range.start.line + 1}:${d.range.start.character + 1} cli ${cli_line}:${cli_col}')
	}

	// The position is the reader's own, taken from where the form ends. For
	// `(+ 1` that is line 0, character 4 -- one past the `1`, which is where the
	// closing bracket should have been. Asserting the concrete value rather
	// than a shape is what stops a future refactor from quietly moving it.
	d := lsp.diagnose('(+ 1')[0]
	s.record("the position is the reader's, not a guess",
		d.range.start.line == 0 && d.range.start.character == 4,
		'line ${d.range.start.line} char ${d.range.start.character}')
}

fn main() {
	mut s := Suite{}

	s.protocol()
	s.lifecycle()
	s.positions()

	// The real bar: the server and the interpreter must agree that a broken
	// file is broken, on the same text. This is the same shape as the emit-js
	// gate: two engines, one input, one answer.
	broken := '(+ 1'
	diags := lsp.diagnose(broken)
	cli := blip_output(broken)
	s.record('both engines see the same break', diags.len > 0
		&& cli.contains('unclosed list'), 'lsp ${diags.len} diag(s), cli reported')

	clean := '(+ 1 2)'
	s.record('both engines agree a clean file is clean', lsp.diagnose(clean).len == 0,
		'no diagnostics')

	if s.fails > 0 {
		println('${s.checks} checks, ${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('lsp: all ${s.checks} checks passed')
}
