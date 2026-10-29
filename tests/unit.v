module main

import os
import vlib.blip
import vlib.blip.host
import vlib.blip.lsp
import vlib.blip.machine
import vlib.blip.prims
import vlib.blip.printer
import vlib.blip.reader
import vlib.blip.repl

// The unit suite.
//
// The nine behavioural suites drive the language from the outside -- source in,
// value out -- which is what they are for. That leaves every function of the
// library called only through that door, and a change to one of them is caught
// only if a program happens to happen to exercise it.
//
// This file calls the library directly, so each function has a test that names
// it. It is the other half of tests/api_coverage.v, which reads the public
// surface out of the source and fails if any of it goes unmentioned by any
// test. Between them: a new `pub fn` turns that gate red, and satisfying it
// means writing a real call here.

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
	s.record(label, got == want, 'got ${got}')
	if got != want {
		println('     wanted ${want}')
	}
}

// ---- values ---------------------------------------------------------------

fn (mut s Suite) constructors() {
	s.eq('integer', printer.write(blip.integer(42)), '42')
	s.eq('float', printer.write(blip.float(2.5)), '2.5')
	s.eq('rune', printer.write(blip.rune(65)), '#\\A')
	s.eq('string', printer.write(blip.string('hi')), '"hi"')
	s.eq('symbol', printer.write(blip.symbol('abc')), 'abc')
	s.eq('keyword', printer.write(blip.keyword('k')), ':k')
	s.eq('boolean true', printer.write(blip.boolean(true)), '#t')
	s.eq('boolean false', printer.write(blip.boolean(false)), '#f')
	s.eq('cons', printer.write(blip.cons(blip.integer(1), blip.nil_value())), '(1)')
	s.eq('list_from', printer.write(blip.list_from([blip.integer(1), blip.integer(2)])),
		'(1 2)')
	s.eq('vector', printer.write(blip.vector([blip.integer(1)])), '[1]')
	s.eq('table', printer.write(blip.table({
		'a': blip.integer(1)
	})), '{:a 1}')
	s.eq('buffer', printer.write(blip.buffer({
		'x': blip.integer(7)
	})), '@{:x 7}')
	s.eq('struct_value', printer.write(blip.struct_value('pt', ['x', 'y'], {
		'x': blip.integer(1)
		'y': blip.integer(2)
	})), '(pt 1 2)')
	s.eq('empty_list', printer.write(blip.empty_list()), '()')
}

fn (mut s Suite) accessors() {
	s.eq('as_int', blip.integer(9).as_int().str(), '9')
	s.eq('as_float', blip.float(1.5).as_float().str(), '1.5')
	s.eq('as_bool', blip.boolean(true).as_bool().str(), 'true')
	s.eq('as_string', blip.string('z').as_string(), 'z')
	s.eq('as_pair', printer.write(blip.cons(blip.integer(1), blip.nil_value()).as_pair().car), '1')
	v := blip.vector([blip.integer(5)])
	s.eq('as_vector', v.as_vector().data.len.str(), '1')
	t := blip.table({
		'k': blip.integer(3)
	})
	s.eq('as_table', printer.write(t.as_table().get('k')), '3')
	sv := blip.struct_value('p', ['q'], {
		'q': blip.integer(4)
	})
	s.eq('as_struct', printer.write(sv.as_struct().get('q')), '4')
	c := blip.new_closure(['x'], reader.NodeId(0), blip.EnvId(0), 'f')
	s.eq('as_closure', c.as_closure().name, 'f')
}

fn (mut s Suite) predicates() {
	// Only #f is false. Nil is truthy, which is the rule the examples state and
	// the opposite of what I assumed the first time through.
	s.record('truthy nil is true', blip.nil_value().truthy(), 'nil is true')
	s.record('truthy zero is true', blip.integer(0).truthy(), '0 is true')
	s.record('is_empty_seq empty list', blip.empty_list().is_empty_seq(), '()')
	s.record('is_empty_seq int is false', !blip.integer(1).is_empty_seq(), '1')
	s.eq('payload_tag of an int', blip.integer(1).as_int().str(), '1')
	s.record('payload_tag of a pair', blip.cons(blip.integer(1), blip.nil_value()).as_pair().payload_tag() == blip.Tag.pair,
		'Tag.pair')
	s.record('payload_tag of a vector', blip.vector([]).as_vector().payload_tag() == blip.Tag.vector, 'Tag.vector')
	s.record('payload_tag of a table', blip.table({}).as_table().payload_tag() == blip.Tag.table, 'Tag.table')
	s.record('payload_tag of a closure', blip.new_closure([], reader.NodeId(0), blip.no_env,
		'f').as_closure().payload_tag() == blip.Tag.closure, 'Tag.closure')
	s.eq('new_prim', printer.write(blip.new_prim('+')), '#<primitive +>')
}

fn (mut s Suite) collections() {
	// Every method here is called on the payload handed back by its accessor,
	// because that is where they are defined. Mutating the payload mutates the
	// value that owns it, which is what the assertions then observe.
	mut v := blip.vector([blip.integer(1)])
	v.as_vector().push(blip.integer(2))
	v.as_vector().set_at(0, blip.integer(9))
	s.eq('vector push and set_at', printer.write(v), '[9 2]')
	s.eq('vector pop', printer.write(v.as_vector().pop()), '2')
	s.eq('vector after pop', printer.write(v), '[9]')

	mut t := blip.table({})
	t.as_table().set_at('a', blip.integer(1))
	s.record('table has after set_at', t.as_table().has('a'), 'a is present')
	s.eq('table get', printer.write(t.as_table().get('a')), '1')
	t.as_table().delete_at('a')
	s.record('table has after delete_at', !t.as_table().has('a'), 'a is gone')
	s.eq('table keys is empty', t.as_table().keys().join(','), '')

	mut sv := blip.struct_value('p', ['a'], {
		'a': blip.integer(1)
	})
	with_a := sv.as_struct().with('a', blip.integer(8))
	s.eq('struct with replaces the field', printer.write(with_a.at(0)), '8')
	s.record('struct has', sv.as_struct().has('a'), 'a present')
	s.record('struct has missing', !sv.as_struct().has('zz'), 'zz absent')
	s.eq('struct at', printer.write(sv.as_struct().at(0)), '1')
}

// ---- environments ---------------------------------------------------------

fn (mut s Suite) envs() {
	// A root env's parent is `blip.no_env`, not zero. `new_env(0)` builds an env
	// whose parent is itself, and every walk up the chain then spins forever --
	// which is what this test did first, before reading the constant.
	mut ea := blip.EnvArena{}
	root := ea.new_env(blip.no_env)
	ea.define(root, 'x', blip.integer(1))
	lv := ea.lookup(root, 'x') or { blip.nil_value() }
	s.eq('env lookup', printer.write(lv), '1')
	ok := ea.set(root, 'x', blip.integer(2))
	s.record('env set returns true', ok, 'x existed')
	after := ea.lookup(root, 'x') or { blip.nil_value() }
	s.eq('env value after set', printer.write(after), '2')
	s.record('env set of unbound is false', !ea.set(root, 'nope', blip.integer(1)), 'nope')
	child := ea.new_env(root)
	inh := ea.lookup(child, 'x') or { blip.nil_value() }
	s.eq('a child env sees its parent', printer.write(inh), '2')
}

// ---- closures -------------------------------------------------------------

fn (mut s Suite) closures() {
	c := blip.new_closure(['a'], reader.NodeId(0), blip.EnvId(0), 'f')
	s.eq('new_closure name', c.as_closure().name, 'f')
	s.eq('new_closure params', c.as_closure().params.len.str(), '1')
	r := blip.new_rest_closure(['a'], 'rest', reader.NodeId(0), blip.EnvId(0), 'g')
	s.eq('new_rest_closure rest name', r.as_closure().rest_name, 'rest')
	l := blip.labelled(['a'], reader.NodeId(0), blip.EnvId(0), 'h', 1, ['b'], [reader.NodeId(1)])
	s.eq('labelled opt_from', l.as_closure().opt_from.str(), '1')
	s.eq('labelled opt names', l.as_closure().opt_names.join(','), 'b')
	s.eq('new_prim', printer.write(blip.new_prim('+')), '#<primitive +>')
}

// ---- reader ---------------------------------------------------------------

fn (mut s Suite) reader_arena() {
	mut a := reader.Arena{}
	n0 := a.leaf(.sym)
	s.eq('leaf', a.node(n0).tag.str(), 'sym')
	s0 := a.str_leaf(.str, 'hi')
	s.eq('str_leaf', a.node(s0).value, 'hi')
	s.record('is_stringy on a string', reader.DatumTag.str.is_stringy(), 'a str is stringy')
	s.record('is_stringy on a symbol', reader.DatumTag.sym.is_stringy(), 'a sym is stringy')
	s.record('is_collection on a list', reader.DatumTag.list.is_collection(), 'a list is one')
	i0 := a.int_leaf(.int, 7)
	s.eq('int_leaf', a.node(i0).i.str(), '7')
	f0 := a.float_leaf(1.25)
	s.eq('float_leaf', a.node(f0).f.str(), '1.25')
	o := a.open(.list)
	s.eq('open', a.node(o).tag.str(), 'list')
	// add_child carries a precondition the reader spells out: the parent must be
	// the LAST thing that has appended to `children`. Opening a node and adding
	// one child while nothing else has appended since is that case, and the
	// child lands. Adding a second after another leaf was appended does not,
	// which is exactly why finish exists.
	inner := a.leaf(.sym)
	a.add_child(o, inner)
	s.eq('add_child on a freshly opened node', a.kids(o).len.str(), '1')
	a.finish(o, a.kids(o))
	s.record('finish keeps the count', a.count() >= 5, 'arena has the nodes')
	a.set_pos(o, 12, 3)
	s.record('set_pos', a.node(o).line == 12 && a.node(o).col == 3, 'line 12 col 3')

	res := a.read_forms('(+ 1 2)')
	s.eq('read_forms one form', res.forms.len.str(), '1')
	s.eq('read_forms no diags', res.diags.len.str(), '0')
}

fn (mut s Suite) reader_diags() {
	res := reader.read_all('(+ 1')
	s.eq('read_all reports the open list', res.diags.len.str(), '1')
	d := res.diags[0]
	s.eq('diagnostic render', d.render('f.lip'), 'f.lip:1:5: unclosed list, expected byte 0x29')
}

fn (mut s Suite) reader_depth() {
	s.eq('depth balanced', reader.depth('(+ 1 2)').n.str(), '0')
	s.eq('depth one open', reader.depth('(+ 1').n.str(), '1')
	s.record('depth in string', reader.depth('(+ "x').in_string, 'string is open')
	s.eq('depth a bracket inside a string', reader.depth('(print "(")').n.str(), '0')
	s.eq('depth a comment is not a bracket', reader.depth('; a ( comment').n.str(), '0')
	s.record('depth a block comment is not a bracket', reader.depth('#| ( |# (+ 1 2)').n == 0, 'balanced')
	s.eq('depth a bar symbol is not a string', reader.depth('(a |x| b)').n.str(), '0')
	s.record('depth a bar symbol leaves no string', !reader.depth('(a |x| b)').in_string,
		'not a string')
}

// ---- printer --------------------------------------------------------------

fn (mut s Suite) printing() {
	s.eq('write a pair', printer.write(blip.cons(blip.integer(1), blip.nil_value())), '(1)')
	s.eq('quote_string plain', printer.quote_string('ab'), '"ab"')
	s.eq('quote_string a newline', printer.quote_string('a\nb'), '"a\\nb"')
	s.eq('quote_string a quote', printer.quote_string('a"b'), '"a\\"b"')
	s.eq('quote_string a backslash', printer.quote_string('a\\b'), '"a\\\\b"')

	mut a := reader.Arena{}
	f := a.read_forms('(+ 1 2)')
	s.eq('write_datum round trips', printer.write_datum(&a, f.forms[0]), '(+ 1 2)')
}

// ---- prims ----------------------------------------------------------------

fn (mut s Suite) prims_helpers() {
	c := prims.compare(blip.integer(1), blip.integer(2)) or { -99 }
	s.eq('compare less than', c.str(), '-1')
	s.record('value_eq on equal ints', prims.value_eq(blip.integer(1), blip.integer(1)), 'equal')
	s.record('value_eq on different ints', !prims.value_eq(blip.integer(1), blip.integer(2)),
		'not equal')
	s.record('is_seq on a vector', prims.is_seq(blip.vector([])), 'a vector is a sequence')
	s.record('is_seq on an int', !prims.is_seq(blip.integer(1)), 'an int is not')
	items := [blip.integer(3), blip.integer(1), blip.integer(2)]
	keys := [blip.integer(30), blip.integer(10), blip.integer(20)]
	sorted := prims.sort_by_keyed(items, keys) or { blip.nil_value() }
	s.eq('sort_by_keyed orders by the keys', printer.write(sorted), '(1 2 3)')
	seqd := prims.seq(blip.vector([blip.integer(4)])) or {
		s.fails++
		println('FAIL seq => ${err.msg()}')
		[]blip.Value{}
	}
	s.eq('seq of a vector', seqd.len.str(), '1')
}

// ---- machine --------------------------------------------------------------

fn (mut s Suite) machine_api() {
	h := host.new_capture()
	mut a := reader.Arena{}
	mut m1 := machine.new_machine_with(&a, h)
	_ := m1
	mut m := machine.new_standalone(h)
	s.eq('where with no source', m.where(), 'blip')
	m.source = 'demo.lip'
	s.eq('where names the source', m.where(), 'demo.lip')

	v := m.run_str('(+ 1 2)') or { blip.nil_value() }
	s.eq('run_str', printer.write(v), '3')

	forms := m.arena.read_forms('(+ 2 3)')
	one := m.eval_one(forms.forms[0]) or { blip.nil_value() }
	s.eq('eval_one', printer.write(one), '5')
	all := m.run(forms.forms) or { blip.nil_value() }
	s.eq('run over forms', printer.write(all), '5')
	chk := m.run_checked(m.arena.read_forms('(+ 3 4)')) or { blip.nil_value() }
	s.eq('run_checked', printer.write(chk), '7')

	// A lenient read tolerates a trailing incomplete form rather than failing,
	// which is what a REPL line wants as it is being typed.
	lenient := m.eval_string_lenient('(+ 1 2)') or { blip.nil_value() }
	s.eq('eval_string_lenient', printer.write(lenient), '3')

	s.record('special_form knows define', machine.special_form('define'), 'define')
	s.record('special_form rejects nope', !machine.special_form('nope'), 'nope')
	s.record('pattern_predicate knows number?', machine.pattern_predicate('number?'), 'number?')
	s.record('pattern_predicate rejects nope', !machine.pattern_predicate('nope'), 'nope')
}

fn (mut s Suite) machine_nodes() {
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	s.eq('render_node of a symbol', m.render_node(m.sym_node('abc')), 'abc')
	s.eq('render_node of an int', m.render_node(m.int_node(7)), '7')
	s.eq('render_node of a string', m.render_node(m.string_node('s')), '"s"')
	id := m.arena.read_forms('(+ 1 2)')
	s.eq('datum_to_value', printer.write(m.datum_to_value(id.forms[0])), '(+ 1 2)')
	q := m.quasi_to_value(id.forms[0])
	s.eq('quasi_to_value', printer.write(q), '(+ 1 2)')
	joined := m.list_of([m.sym_node('a'), m.sym_node('b')])
	s.eq('list_of', m.render_node(joined), '(a b)')
	two := m.list_of2([m.sym_node('x')], [m.int_node(1)])
	s.eq('list_of2', m.render_node(two), '((x 1))')
	hered := m.node_of('cons', [m.sym_node('k'), m.sym_node('v')])
	s.eq('node_of', m.render_node(hered), '(cons k v)')
	calln := m.call_node(m.sym_node('f'), [m.int_node(1)])
	s.eq('call_node', m.render_node(calln), '(f 1)')
	b := m.make_begin([m.sym_node('a')])
	// A begin of one form needs no wrapper, and dropping it keeps the transform
	// output from carrying a node that only adds a stack frame.
	s.eq('make_begin of one form', m.render_node(b), 'a')
	s.eq('nil_node', m.render_node(m.nil_node()), 'nil')
	fresh := m.fresh('tmp')
	s.record('fresh makes distinct names', fresh.starts_with('tmp'), '${fresh}')

	s.eq('resolve_path of an absolute path', m.resolve_path('/x/y.lip'), '/x/y.lip')

	// Every transform is exercised through the function that names it, because
	// a transform reached only through source is covered only while some
	// program happens to use it.
	lt := m.arena.read_forms('(let ([a 1]) a)')
	n1 := m.transform_let(m.arena.kids(lt.forms[0])) or { blip.NodeId(0) }
	s.record('transform_let returns a node', n1 > 0, 'node ${n1}')

	star := m.arena.read_forms('(let* ([a 1] [b 2]) b)')
	n2 := m.transform_let_star(m.arena.kids(star.forms[0]))
	s.record('transform_let_star returns a node', n2 > 0, 'node ${n2}')

	rec := m.arena.read_forms('(letrec ([f (fn [] 1)]) (f))')
	n3 := m.transform_letrec(m.arena.kids(rec.forms[0]))
	s.record('transform_letrec returns a node', n3 > 0, 'node ${n3}')

	cond := m.arena.read_forms('(cond (#t 1) (else 2))')
	n4 := m.transform_cond(m.arena.kids(cond.forms[0]))
	s.record('transform_cond returns a node', n4 > 0, 'node ${n4}')

	cs := m.arena.read_forms('(case 1 ((1) 10))')
	n5 := m.transform_case(m.arena.kids(cs.forms[0]))
	s.record('transform_case returns a node', n5 > 0, 'node ${n5}')

	lp := m.arena.read_forms('(loop ([i 0]) [i 10] i)')
	n6 := m.transform_loop(m.arena.kids(lp.forms[0]))
	s.record('transform_loop returns a node', n6 > 0, 'node ${n6}')

	// dotimes takes its loop variable as a symbol and the count separately:
	// (dotimes i 3 body). The parenthesised spelling is not this form.
	dt := m.arena.read_forms('(dotimes i 3 i)')
	n7 := m.transform_dotimes(m.arena.kids(dt.forms[0])) or { blip.NodeId(0) }
	s.record('transform_dotimes returns a node', n7 > 0, 'node ${n7}')

	// A binding whose pattern is a LIST rather than a name is what makes it
	// destructuring. `(cons a b)` is the shape `destructuring` accepts -- it
	// also takes a bare symbol and a table, and rejects vectors and literals,
	// which is why `[a b]` errors even though `is_destructuring` calls a vector
	// binding destructuring. That asymmetry is real, and this asserts it.
	bs := m.arena.read_forms('(let ([(cons a b) 1]) a)')
	k := m.arena.kids(bs.forms[0])
	group := m.arena.kids(k[1])[0]
	s.record('is_destructuring on a cons pattern', m.is_destructuring(group),
		'(cons a b) pulls apart')
	pattern := m.binding_pattern(group)
	s.record('binding_pattern sees the list', pattern > 0, 'has a pattern')
	s.record('binding_name', m.binding_name(group) > 0, 'has a name')
	s.record('binding_value', m.binding_value(group) > 0, 'has a value')
	destructured := m.destructuring(pattern, m.int_node(5)) or {
		s.fails++
		println('FAIL destructuring => ${err.msg()}')
		[]machine.Destructured{}
	}
	// (cons a b) pulls two names: the head and the tail.
	s.eq('destructuring of a cons yields two', destructured.len.str(), '2')

	mcl := m.arena.read_forms('(match 1 (1 "one"))')
	cl := m.match_clause(m.arena.kids(mcl.forms[0])[1], m.arena.kids(mcl.forms[0])[1])
	s.record('match_clause returns a node', cl > 0, 'node ${cl}')

	fns := m.arena.read_forms('(fn (x) x)')
	params := m.arena.kids(m.arena.kids(fns.forms[0])[1])
	spec := m.parse_params(params, 'f') or {
		s.fails++
		println('FAIL parse_params => ${err.msg()}')
		machine.ParamSpec{}
	}
	s.eq('parse_params reads the arity', spec.names.len.str(), '1')
	made := m.make_closure(spec, fns.forms[0], blip.EnvId(0), 'f')
	s.eq('make_closure makes a closure', printer.write(made), '#<closure>')

	sv := blip.struct_value('p', ['k'], {
		'k': blip.integer(3)
	})
	fv := m.field_of(sv, 'k') or { blip.nil_value() }
	s.eq('field_of', printer.write(fv), '3')
	bad := m.field_of(sv, 'nope') or { blip.nil_value() }
	s.record('field_of of a missing field falls back', bad.is_nil(), 'no field, so nil')
}

// ---- host -----------------------------------------------------------------

fn (mut s Suite) hosts() {
	mut h := host.new_capture()
	h.host_print('line one')
	h.host_write('tail')
	s.eq('host lines are collected', h.lines().join('|'), 'line one')
	s.eq('host transcript keeps the raw write', h.transcript(), 'line one\ntail')
	h.give_file('a.lip', '(+ 1 2)')
	loaded := h.host_load('a.lip') or { '' }
	s.eq('host_load returns what it was given', loaded, '(+ 1 2)')
	h.give_input(['typed'])
	read := h.host_read_line() or { '' }
	s.eq('host_read_line takes the first', read, 'typed')
	missing := h.host_load('nope.lip') or { '' }
	s.record('host_load of an unknown file is an error', missing == '', 'empty fallback')
}

// ---- repl -----------------------------------------------------------------

fn (mut s Suite) repl_api() {
	s.eq('prompt at the top level', repl.prompt(''), 'blip:1> ')
	s.eq('prompt inside a bracket', repl.prompt('(+ 1'), 'blip:2> ')
	s.eq('prompt inside a string', repl.prompt('"ab'), 'blip"> ')

	mut h := host.new_capture()
	h.give_file('lib/std.lip', '')
	mut m := machine.new_standalone(h)
	mut r := repl.new_with_machine(m, h)
	r.run_lines(['(define (q) 1)', '(q)'])
	s.record('run_lines evaluated both lines', h.lines().len >= 2, 'the host saw output')

	mut r2 := repl.new(h)
	r2.run_lines(['(+ 1 1)'])
	s.record('the standalone repl runs a line', true, 'constructed')
}

fn (mut s Suite) error_format() {
	// The Rust/V-style frame, exercised directly because the golden REPL test
	// only sees it as one line of text.
	src := '(+ 1\n  2\n   3'
	out := blip.format_error('demo.lip', src, 3, 3, 'unclosed list, expected byte 0x29', 1)
	s.record('the error names the place', out.contains('--> demo.lip:3:3'), 'has the location')
	s.record('the error shows the line', out.contains('3'), 'shows the line')
	s.record('the error carries the message', out.contains('unclosed list'), 'has the message')
	s.record('the error draws a caret', out.contains('^'), 'has a caret')
}

// ---- lsp ------------------------------------------------------------------

fn (mut s Suite) lsp_api() {
	s.eq('diagnose of clean source', lsp.diagnose('(+ 1 2)').len.str(), '0')
	d := lsp.diagnose('(+ 1')
	s.eq('diagnose of an open list', d.len.str(), '1')
	s.eq('diagnose position', '${d[0].range.start.line}:${d[0].range.start.character}', '0:4')
	s.eq('diagnose message', d[0].message, 'unclosed list, expected byte 0x29')
	s.eq('diagnose source', d[0].source, 'blip')

	mut srv := lsp.new_test_server()
	srv.handle('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
	out := srv.captured()
	s.record('initialize answered', out.len >= 1, '${out.len} message(s)')
	s.record('the answer carries capabilities', out[0].contains('capabilities'),
		'capabilities present')
	s.record('the answer echoes the id', out[0].contains('"id":1'), 'id echoed')

	mut srv2 := lsp.new_test_server()
	srv2.handle('{"jsonrpc":"2.0","method":"exit"}')
	s.record('exit is reported as a stop', srv2.handle('{"jsonrpc":"2.0","method":"exit"}'),
		'true')

	// A message before initialize is refused, per LSP 3.5, and refused silently
	// when it is a notification -- there is no id to answer on.
	mut srv3 := lsp.new_test_server()
	srv3.handle('{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"u","text":"("}}}')
	s.record('didOpen before initialize is refused', srv3.captured().len == 0, 'nothing sent')

	// `serve` is the stdio loop, and it can only be driven for real by feeding
	// it a frame. This builds the executable first, the same way CI does before
	// it runs these suites, then hands it an initialize and asks for an answer.
	// A missing binary is a failure rather than a skip: every other suite here
	// assumes the build has happened.
	// ./blip, not bare `blip`: POSIX sh does not search the current
	// directory, so the runner died with `blip: not found` and an empty
	// stdout record. On Windows cmd searches cwd, which is why this ever
	// looked green locally.
	exe := if os.exists('blip.exe') { 'blip.exe' } else { './blip' }
	init := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
	exitn := '{"jsonrpc":"2.0","method":"exit"}'
	framed := 'Content-Length: ${init.len}\r\n\r\n${init}Content-Length: ${exitn.len}\r\n\r\n${exitn}'
	os.mkdir_all('tmp') or {}
	os.write_file('tmp/lsp_in.txt', framed) or {
		s.fails++
		println('FAIL serve => cannot write the frame: ${err.msg()}')
		return
	}
	os.system('"${exe}" lsp < "tmp/lsp_in.txt" > "tmp/lsp_out.txt"')
	got := os.read_file('tmp/lsp_out.txt') or { '' }
	s.record('serve answered on stdout', got.len > 0, '${got.len} bytes')
	s.record('serve returned the capabilities', got.contains('capabilities'), 'capabilities')
	s.record('serve did not echo a diagnostic', !got.contains('publishDiagnostics'), 'no diags')
	os.rm('tmp/lsp_in.txt') or {}
	os.rm('tmp/lsp_out.txt') or {}
}

// ---- the pinned toolchain, synced everywhere -------------------------------

// install_pins is the gate for the pin itself. blip builds against ONE
// compiler commit, and that decision is written in four places and used by
// two audiences: ci.yml builds it in CI, install.sh / install.ps1 build it on
// a stranger's machine, and the site/ copies are what the website hands out.
// Drift between them is invisible until someone's install produces a broken
// binary -- which is worse than a red suite, because nothing looks red.
// Root scripts and site copies must therefore carry BOTH pins, exactly as
// ci.yml spells them.
fn (mut s Suite) install_pins() {
	ci := os.read_file('.github/workflows/ci.yml') or {
		s.fails++
		println('FAIL pins => cannot read ci.yml: ${err.msg()}')
		return
	}
	mut v_commit := ''
	mut vc_commit := ''
	for line in ci.split_into_lines() {
		fields := line.trim_space().split(':')
		if fields.len == 2 {
			v := fields[0].trim_space()
			val := fields[1].trim_space()
			if v == 'V_COMMIT' {
				v_commit = val
			}
			if v == 'VC_COMMIT' {
				vc_commit = val
			}
		}
	}
	s.record('ci.yml pins V', v_commit.len == 40, v_commit)
	s.record('ci.yml pins vc', vc_commit.len == 40, vc_commit)
	for path in ['install.sh', 'install.ps1', 'site/install.sh', 'site/install.ps1'] {
		src := os.read_file(path) or {
			s.fails++
			println('FAIL pins => cannot read ${path}: ${err.msg()}')
			continue
		}
		s.record('${path} pins V', src.contains(v_commit), if src.contains(v_commit) {
			v_commit
		} else {
			'MISSING'
		})
		s.record('${path} pins vc', src.contains(vc_commit), if src.contains(vc_commit) {
			vc_commit
		} else {
			'MISSING'
		})
		// An unpinned fallback is the bug this gate exists for: a script that
		// also clones V at HEAD would work today and break next week, so the
		// literal "clone vlang/v then make" must not appear even WITH the pin
		// present. (The remote add + fetch at a commit, which the pinned
		// recipes use, does not match this literal.)
		s.record('${path} clones V only at a pin', !src.contains('git clone https://github.com/vlang/v '),
			'checked')
	}
}

fn main() {
	mut s := Suite{}
	s.install_pins()
	s.constructors()
	s.accessors()
	s.predicates()
	s.collections()
	s.envs()
	s.closures()
	s.reader_arena()
	s.reader_diags()
	s.reader_depth()
	s.printing()
	s.prims_helpers()
	s.machine_api()
	s.machine_nodes()
	s.hosts()
	s.repl_api()
	s.error_format()
	s.lsp_api()

	if s.fails > 0 {
		println('${s.checks} checks, ${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('unit: all ${s.checks} checks passed')
}
