module main

// The programs gate: run every programs/*.blip file and check its output.
//
// The examples are the specification; the programs are the proof. Each one
// ends with a marker line -- "brainfuck ok", "json ok" -- and this file runs
// them and asserts the markers, the same cheap gate examples_run.v uses.
//
// Every file runs in a FRESH machine, for the same reason: a shared machine
// would let a leak from one program satisfy an assertion in the next.
//
// Programs differ from examples in one way that matters here: they do real
// I/O. Brainfuck's `,` command reads a line, so the capture host answers
// end-of-input (read-char yields 0 on EOF, which is also what a terminal
// gives). The hello-world program never reads, but the gate must not hang
// if a future program does.

import os
import blip.host
import blip.machine

struct Suite {
mut:
	fails int
}

fn (mut s Suite) fail(label string, msg string) {
	s.fails++
	println('FAIL ${label}: ${msg}')
}

// run_program evaluates one file and returns everything it printed.
//
// The standard library is loaded first, exactly as `blip run` does, because
// programs assume the prelude without defining it.
fn run_program(path string) !string {
	src := os.read_file(path) or {
		return error('cannot read ${path}')
	}
	h := host.new_capture()
	std := os.read_file('lib/std.blip') or {
		return error('cannot read lib/std.blip')
	}
	h.give_file('lib/std.blip', std)
	mut m := machine.new_standalone(h)
	m.load('lib/std.blip') or {
		return error('cannot load the standard library: ${err.msg()}')
	}
	m.source = path
	m.run_str(src) or {
		return error('${err.msg()}')
	}
	mut out := ''
	for line in m.out {
		out += line
		out += '\n'
	}
	return out
}

// check_program runs one file and asserts that its output contains want.
fn (mut s Suite) check_program(label string, path string, want string) {
	out := run_program(path) or {
		s.fail(label, err.msg())
		return
	}
	if !out.contains(want) {
		s.fail(label, 'output does not contain "${want}":\n${out}')
		return
	}
	println('ok   ${label}')
}

// hello_world_output pins what the Brainfuck hello-world program prints:
// the characters in order. Newlines are stripped before comparing, so the
// check survives whatever newline policy `display` has -- one per character
// today, none tomorrow -- while still catching a mistyped program or a
// broken `.` command, which is what an output gate is for.
fn (mut s Suite) hello_world_output() {
	out := run_program('programs/brainfuck.blip') or {
		s.fail('brainfuck hello world', err.msg())
		return
	}
	// `display` shows runes as `#\H`, so those markers are stripped as well.
	// Runes print as `#\H`, with names for the non-printing ones (`#\space`,
	// `#\newline`), so those markers are stripped as well. What remains must
	// be the greeting in order: a mistyped program or a broken `.` command
	// cannot produce it, while a future printer that shows runes bare keeps
	// this green.
	flat := out.replace('\n', '').replace('\r', '').replace('#\\space', ' ').replace('#\\newline', '').replace('#\\', '')
	if !flat.contains('Hello World') {
		s.fail('brainfuck hello world', 'no Hello World in output:\n${out}')
		return
	}
	println('ok   brainfuck hello world')
}

fn main() {
	mut s := Suite{}

	s.check_program('brainfuck', 'programs/brainfuck.blip', 'brainfuck ok')
	s.hello_world_output()
	s.check_program('json', 'programs/json.blip', 'json ok')
	s.check_program('config', 'programs/config.blip', 'config ok')
	s.check_program('csv_to_table', 'programs/csv_to_table.blip', 'csv ok')
	s.check_program('lint_commit', 'programs/lint_commit.blip', 'lint ok')
	s.check_program('markdown', 'programs/markdown.blip', 'markdown ok')
	s.check_program('pratt', 'programs/pratt.blip', 'pratt ok')
	s.check_program('peg', 'programs/peg.blip', 'peg ok')

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('programs: all checks passed')
}
