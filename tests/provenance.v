module main

import blip
import blip.host
import blip.machine
import blip.prims

fn at(v blip.Value, file string, line int, col int) {
	loc := v.source_location() or { panic('missing source for ${v.tag}') }
	assert loc.file == file, '${loc}'
	assert loc.line == line, '${loc}'
	assert loc.col == col, '${loc}'
}

fn main() {
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	m.source = 'config.lip'
	src := '(define a 42)\n(define b 42)\n[a b (+ a b)]'
	v := m.run_str(src)!
	at(v, 'config.lip', 3, 1)
	xs := v.as_vector() or { panic('unreachable: valid test input') }.data
	at(xs[0], 'config.lip', 1, 11)
	at(xs[1], 'config.lip', 2, 11)
	at(xs[2], 'config.lip', 3, 6)
	assert prims.value_eq(xs[0], xs[1])
	assert v.as_vector() or { panic('unreachable: valid test input') }.data[2].i == 84
	loc := xs[2].source_location() or { panic('missing location') }
	assert src[loc.start..loc.end] == '(+ a b)'

	h.give_file('defaults.lip', '(define default-port 8080)\n(define (port) (+ default-port 1))\n(define (identity x) x)')
	m.load('defaults.lip')!
	at(m.run_str('default-port')!, 'defaults.lip', 1, 22)
	at(m.run_str('(port)')!, 'defaults.lip', 2, 16)
	at(m.run_str('(identity 7)')!, 'config.lip', 1, 11)
	assert m.source == 'config.lip'
	at(m.run_str('port')!, 'defaults.lip', 2, 1)

	q := m.run_str("'(1\n  {:x 2} [3])")!
	at(q.as_pair() or { panic('unreachable: valid test input') }.car, 'config.lip', 1, 3)
	tail := q.as_pair() or { panic('unreachable: valid test input') }.cdr
	at(tail.as_pair() or { panic('unreachable: valid test input') }.car.as_table() or { panic('unreachable: valid test input') }.get('x'), 'config.lip', 2, 7)
	at(tail.as_pair() or { panic('unreachable: valid test input') }.cdr.as_pair() or { panic('unreachable: valid test input') }.car.as_vector() or { panic('unreachable: valid test input') }.data[0], 'config.lip', 2, 11)
	at(tail, 'config.lip', 1, 2)

	at(m.run_str('(let ([x 5]) x)')!, 'config.lip', 1, 10)
	at(m.run_str('(if #t 9 10)')!, 'config.lip', 1, 8)
	at(m.run_str('(get {:x 13} :x)')!, 'config.lip', 1, 10)
	split := m.run_str('(string-split "a,b" ",")')!
	for x in prims.seq(split)! { at(x, 'config.lip', 1, 1) }
	info := m.run_str('(source-location a)')!.as_table() or { panic('unreachable: valid test input') }
	assert info.get('file').as_string() or { panic('unreachable: valid test input') } == 'config.lip'
	assert info.get('line').i == 1
	assert info.get('column').i == 11
	assert src[int(info.get('start').i)..int(info.get('end').i)] == '42'
	assert blip.integer(4).source_location() == none

	id := m.value_to_datum(xs[0])!
	at(m.eval_one(id)!, 'config.lip', 1, 11)
	m.load('absent.lip') or {}
	assert m.source == 'config.lip'
	// An error after switching files must restore the caller's source too.
	h.give_file('broken.lip', '(undefined)')
	m.load('broken.lip') or {}
	assert m.source == 'config.lip'
	m.run_str('(define (args . xs) xs)')!
	at(m.run_str('(args 1 2)')!, 'config.lip', 1, 1)
	m.run_str('(struct Point (x y))')!
	at(m.run_str('Point')!, 'config.lip', 1, 1)
	point := m.run_str('(Point 1 2)')!
	at(point.as_struct() or { panic('unreachable: valid test input') }.get('y'), 'config.lip', 1, 10)
	m.run_str('(define p (Point 1 2))')!
	updated := m.run_str('(p.x := 9)')!
	at(updated, 'config.lip', 1, 1)
	at(updated.as_struct() or { panic('unreachable: valid test input') }.get('x'), 'config.lip', 1, 9)
	unicode := m.run_str('["é" 17]')!.as_vector() or { panic('unreachable: valid test input') }.data[1]
	at(unicode, 'config.lip', 1, 7)
	unicode_loc := unicode.source_location() or { panic('missing unicode span') }
	assert '["é" 17]'[unicode_loc.start..unicode_loc.end] == '17'
	for literal in ['nil', '#t', '#f', '1.5', '"text"', ':key', '()', '[]', '{}', '@[]', '@{}'] {
		at(m.run_str(literal)!, 'config.lip', 1, 1)
	}
	m.run_str('(set! a 99)')!
	at(m.run_str('a')!, 'config.lip', 1, 9)
	m.run_str('(define data @[0])')!
	m.run_str('(array-set! data 0 23)')!
	at(m.run_str('(array-ref data 0)')!, 'config.lip', 1, 20)
	m.run_str('(define (inc x) (+ x 1))')!
	mapped := m.run_str('(map inc [1 2])')!
	for item in prims.seq(mapped)! { at(item, 'config.lip', 1, 17) }
	// New primitive results include their generated elements; cycles are bounded.
	origin := blip.SourceLocation{ file: 'host-call', line: 1, col: 1 }
	cyclic := blip.buffer({})
	cyclic.as_table() or { panic('unreachable: valid test input') }.set_at('self', cyclic)
	located := cyclic.with_tree_origin(origin)
	at(located.as_table() or { panic('unreachable: valid test input') }.get('self'), 'host-call', 1, 1)
	assert blip.integer(1).with_origin(origin).origin == origin
	parsed := m.arena.read_source('6', 'parsed.lip')
	at(m.run(parsed.forms)!, 'parsed.lip', 1, 1)
	println('PASS provenance: literals, calls, collections, loads, spans, equality, datum conversion')
}
