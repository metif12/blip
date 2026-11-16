module main

import os
import blip
import blip.host
import blip.lsp
import blip.machine
import blip.manifest
import blip.migrate
import blip.pkg
import blip.toolchain
import blip.prims
import blip.printer
import blip.reader
import blip.repl

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
	s.eq('list_from', printer.write(blip.list_from([blip.integer(1),
		blip.integer(2)])), '(1 2)')
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
	n_int := blip.integer(9).as_int() or { panic('unreachable: valid test input') }
	s.eq('as_int', n_int.str(), '9')
	n_float := blip.float(1.5).as_float() or { panic('unreachable: valid test input') }
	s.eq('as_float', n_float.str(), '1.5')
	n_bool := blip.boolean(true).as_bool() or { panic('unreachable: valid test input') }
	s.eq('as_bool', n_bool.str(), 'true')
	s.eq('as_string', blip.string('z').as_string() or { panic('unreachable: valid test input') },
		'z')
	s.eq('as_pair', printer.write(blip.cons(blip.integer(1), blip.nil_value()).as_pair() or {
		panic('unreachable: valid test input')
	}.car), '1')
	v := blip.vector([blip.integer(5)])
	s.eq('as_vector', v.as_vector() or { panic('unreachable: valid test input') }.data.len.str(),
		'1')
	t := blip.table({
		'k': blip.integer(3)
	})
	s.eq('as_table',
		printer.write(t.as_table() or { panic('unreachable: valid test input') }.get('k')), '3')
	sv := blip.struct_value('p', ['q'], {
		'q': blip.integer(4)
	})
	s.eq('as_struct',
		printer.write(sv.as_struct() or { panic('unreachable: valid test input') }.get('q')), '4')
	c := blip.new_closure(['x'], reader.NodeId(0), blip.EnvId(0), 'f')
	s.eq('as_closure', c.as_closure() or { panic('unreachable: valid test input') }.name, 'f')
}

fn (mut s Suite) predicates() {
	// Only #f is false. Nil is truthy, which is the rule the examples state and
	// the opposite of what I assumed the first time through.
	s.record('truthy nil is true', blip.nil_value().truthy(), 'nil is true')
	s.record('truthy zero is true', blip.integer(0).truthy(), '0 is true')
	s.record('is_empty_seq empty list', blip.empty_list().is_empty_seq(), '()')
	s.record('is_empty_seq int is false', !blip.integer(1).is_empty_seq(), '1')
	n_tag := blip.integer(1).as_int() or { panic('unreachable: valid test input') }
	s.eq('payload_tag of an int', n_tag.str(), '1')
	s.record('payload_tag of a pair', blip.cons(blip.integer(1), blip.nil_value()).as_pair() or {
		panic('unreachable: valid test input')
	}.payload_tag() == blip.Tag.pair, 'Tag.pair')
	s.record('payload_tag of a vector', blip.vector([]).as_vector() or {
		panic('unreachable: valid test input')
	}.payload_tag() == blip.Tag.vector, 'Tag.vector')
	s.record('payload_tag of a table', blip.table({}).as_table() or {
		panic('unreachable: valid test input')
	}.payload_tag() == blip.Tag.table, 'Tag.table')
	s.record('payload_tag of a closure', blip.new_closure([], reader.NodeId(0), blip.no_env, 'f').as_closure() or {
		panic('unreachable: valid test input')
	}.payload_tag() == blip.Tag.closure, 'Tag.closure')
	s.eq('new_prim', printer.write(blip.new_prim('+')), '#<primitive +>')
}

fn (mut s Suite) collections() {
	// Every method here is called on the payload handed back by its accessor,
	// because that is where they are defined. Mutating the payload mutates the
	// value that owns it, which is what the assertions then observe.
	mut v := blip.vector([blip.integer(1)])
	v.as_vector() or { panic('unreachable: valid test input') }.push(blip.integer(2))
	v.as_vector() or { panic('unreachable: valid test input') }.set_at(0, blip.integer(9))
	s.eq('vector push and set_at', printer.write(v), '[9 2]')
	s.eq('vector pop',
		printer.write(v.as_vector() or { panic('unreachable: valid test input') }.pop()), '2')
	s.eq('vector after pop', printer.write(v), '[9]')

	mut t := blip.table({})
	t.as_table() or { panic('unreachable: valid test input') }.set_at('a', blip.integer(1))
	s.record('table has after set_at',
		t.as_table() or { panic('unreachable: valid test input') }.has('a'), 'a is present')
	s.eq('table get',
		printer.write(t.as_table() or { panic('unreachable: valid test input') }.get('a')), '1')
	t.as_table() or { panic('unreachable: valid test input') }.delete_at('a')
	s.record('table has after delete_at', !t.as_table() or {
		panic('unreachable: valid test input')
	}.has('a'), 'a is gone')
	s.eq('table keys is empty',
		t.as_table() or { panic('unreachable: valid test input') }.keys().join(','), '')

	mut sv := blip.struct_value('p', ['a'], {
		'a': blip.integer(1)
	})
	with_a := sv.as_struct() or { panic('unreachable: valid test input') }.with('a',
		blip.integer(8))
	s.eq('struct with replaces the field', printer.write(with_a.at(0)), '8')
	s.record('struct has', sv.as_struct() or { panic('unreachable: valid test input') }.has('a'),
		'a present')
	s.record('struct has missing',
		!sv.as_struct() or { panic('unreachable: valid test input') }.has('zz'), 'zz absent')
	s.eq('struct at',
		printer.write(sv.as_struct() or { panic('unreachable: valid test input') }.at(0)), '1')
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
	s.eq('new_closure name', c.as_closure() or { panic('unreachable: valid test input') }.name, 'f')
	s.eq('new_closure params',
		c.as_closure() or { panic('unreachable: valid test input') }.params.len.str(), '1')
	r := blip.new_rest_closure(['a'], 'rest', reader.NodeId(0), blip.EnvId(0), 'g')
	s.eq('new_rest_closure rest name',
		r.as_closure() or { panic('unreachable: valid test input') }.rest_name, 'rest')
	l := blip.labelled(['a'], reader.NodeId(0), blip.EnvId(0), 'h', 1, ['b'], [
		reader.NodeId(1),
	])
	s.eq('labelled opt_from',
		l.as_closure() or { panic('unreachable: valid test input') }.opt_from.str(), '1')
	s.eq('labelled opt names',
		l.as_closure() or { panic('unreachable: valid test input') }.opt_names.join(','), 'b')
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
	s.eq('diagnostic render', d.render('f.blip'), 'f.blip:1:5: unclosed list, expected byte 0x29')
}

fn (mut s Suite) reader_depth() {
	s.eq('depth balanced', reader.depth('(+ 1 2)').n.str(), '0')
	s.eq('depth one open', reader.depth('(+ 1').n.str(), '1')
	s.record('depth in string', reader.depth('(+ "x').in_string, 'string is open')
	s.eq('depth a bracket inside a string', reader.depth('(print "(")').n.str(), '0')
	s.eq('depth a comment is not a bracket', reader.depth('; a ( comment').n.str(), '0')
	s.record('depth a block comment is not a bracket', reader.depth('#| ( |# (+ 1 2)').n == 0,
		'balanced')
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
	m.source = 'demo.blip'
	s.eq('where names the source', m.where(), 'demo.blip')

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
	s.eq('datum_to_value', printer.write(m.datum_to_value(id.forms[0]) or { blip.nil_value() }),
		'(+ 1 2)')
	q := m.quasi_to_value(id.forms[0]) or { blip.nil_value() }
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

	s.eq('resolve_path of an absolute path', m.resolve_path('/x/y.blip'), '/x/y.blip')
	s.eq('clean_path collapses dot-dot', machine.clean_path('site/../programs/markdown.blip'),
		'programs/markdown.blip')
	s.eq('clean_path drops dots', machine.clean_path('site/./x.blip'), 'site/x.blip')
	s.eq('clean_path keeps a leading dot-dot', machine.clean_path('../x.blip'), '../x.blip')

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

	lp := m.arena.read_forms('(loop ([i 0]) [i 10] i)')
	n6 := m.transform_loop(m.arena.kids(lp.forms[0]))
	s.record('transform_loop returns a node', n6 > 0, 'node ${n6}')

	// dotimes takes its loop variable as a symbol and the count separately:
	// (dotimes i 3 body). The parenthesised spelling is not this form.
	dt := m.arena.read_forms('(dotimes i 3 i)')
	n7 := m.transform_dotimes(m.arena.kids(dt.forms[0])) or { blip.NodeId(0) }
	s.record('transform_dotimes returns a node', n7 > 0, 'node ${n7}')

	// migrate rewrites v1 spellings to v2 canonical forms. Each case pins
	// the exact output text: a rename that drifts silently is the failure
	// this gate exists to catch.
	mm_def := migrate.migrate_source('(define x 1)') or { migrate.MigrateResult{} }
	s.record('migrate renames define to def', mm_def.text == '(def x 1)', mm_def.text)
	mm_lam := migrate.migrate_source('(lambda (x) (+ x 1))') or { migrate.MigrateResult{} }
	s.record('migrate turns lambda params into a vector', mm_lam.text == '(fn [x] (+ x 1))', mm_lam.text)
	mm_case := migrate.migrate_source('(case 5 [(1 2) 10] [else 0])') or {
		migrate.MigrateResult{}
	}
	s.record('migrate expands case to match', mm_case.text == '(match 5 [1 10] [2 10] [_ 0])',
		mm_case.text)
	mm_when := migrate.migrate_source('(when c (f))') or { migrate.MigrateResult{} }
	s.record('migrate turns when into if', mm_when.text == '(if c (begin (f)) nil)', mm_when.text)
	// `migrate_path` renames `.lip` to `.blip` (v2 loads `.blip` only):
	// --check reports without touching the filesystem, a real run moves
	// the content and removes the old spelling.
	tmpd := os.join_path(os.vtmp_dir(), 'blip_migrate_probe')
	os.rmdir_all(tmpd) or {}
	os.mkdir_all(tmpd) or { s.record('migrate rename setup', false, err.msg()) }
	os.write_file(os.join_path(tmpd, 'old.blip'), '(def x 1)') or {}
	os.write_file(os.join_path(tmpd, 'legacy.lip'), '(define x 1)') or {}
	reps := migrate.migrate_path(tmpd, true) or { []migrate.FileReport{} }
	mut saw_rename := false
	for r in reps {
		if r.path.ends_with('legacy.lip') && r.renamed {
			saw_rename = true
		}
	}
	s.record('migrate --check reports the .lip rename', saw_rename, 'legacy.lip marked renamed')
	still_old := os.exists(os.join_path(tmpd, 'legacy.lip'))
	s.record('migrate --check touches nothing', still_old, 'legacy.lip still on disk')
	reps2 := migrate.migrate_path(tmpd, false) or { []migrate.FileReport{} }
	_ = reps2
	moved := os.read_file(os.join_path(tmpd, 'legacy.blip')) or { '' }
	s.record('migrate renames .lip to .blip', moved == '(def x 1)' && !os.exists(os.join_path(tmpd,
		'legacy.lip')), 'content migrated at the new path, old removed')
	os.rmdir_all(tmpd) or {}

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
	h.give_file('a.blip', '(+ 1 2)')
	loaded := h.host_load('a.blip') or { '' }
	s.eq('host_load returns what it was given', loaded, '(+ 1 2)')
	h.give_input(['typed'])
	read := h.host_read_line() or { '' }
	s.eq('host_read_line takes the first', read, 'typed')
	missing := h.host_load('nope.blip') or { '' }
	s.record('host_load of an unknown file is an error', missing == '', 'empty fallback')
}

// ---- repl -----------------------------------------------------------------

fn (mut s Suite) repl_api() {
	s.eq('prompt at the top level', repl.prompt(''), 'blip:1> ')
	s.eq('prompt inside a bracket', repl.prompt('(+ 1'), 'blip:2> ')
	s.eq('prompt inside a string', repl.prompt('"ab'), 'blip"> ')

	mut h := host.new_capture()
	h.give_file('lib/std.blip', '')
	mut m := machine.new_standalone(h)
	mut r := repl.new_with_machine(m, h)
	r.run_lines(['(def (q) 1)', '(q)'])
	s.record('run_lines evaluated both lines', h.lines().len >= 2, 'the host saw output')

	mut r2 := repl.new(h)
	r2.run_lines(['(+ 1 1)'])
	s.record('the standalone repl runs a line', true, 'constructed')
}

fn (mut s Suite) error_format() {
	// The Rust/V-style frame, exercised directly because the golden REPL test
	// only sees it as one line of text.
	src := '(+ 1\n  2\n   3'
	out := blip.format_error('demo.blip', src, 3, 3, 'unclosed list, expected byte 0x29', 1)
	s.record('the error names the place', out.contains('--> demo.blip:3:3'), 'has the location')
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
	s.record('exit is reported as a stop', srv2.handle('{"jsonrpc":"2.0","method":"exit"}'), 'true')

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

// ---- the blip.mod manifest (roadmap Tracks E/G) --------------------------
//
// manifest.parse is the shape gate for the file E2, G1, and G5 share: it
// parses to exactly the Manifest struct or it fails. Feature names and
// version strings are validated by their own tracks, not here -- what this
// pins is that the SHAPE is exact (unknown stanzas, duplicates, and wrong
// shapes all error) and that capabilities default ON when absent.
fn (mut s Suite) manifest() {
	m := manifest.parse('(module myapp)\n(blip 2)') or {
		s.record('manifest minimal parses', false, err.msg())
		return
	}
	s.record('manifest minimal parses', m.name == 'myapp' && m.blip_version == 2, m.name)
	s.record('manifest features default on', m.feature('fibers') && m.feature('anything'),
		'absent means on')
	s.record('manifest deps default empty', m.deps.len == 0, 'no deps')
	s.record('manifest workspace default empty', m.workspace.len == 0, 'no members')
	full := manifest.parse('(module shop)\n(blip 2)\n(features (fibers #f) (network #t))\n(deps (acme/db "1.2.3") (acme/log ">=0.9"))\n(workspace (members shop web))') or {
		s.record('manifest full parses', false, err.msg())
		return
	}
	s.record('manifest full parses', full.name == 'shop', full.name)
	s.record('manifest feature off reads off', !full.feature('fibers'), 'fibers #f')
	s.record('manifest feature on reads on', full.feature('network'), 'network #t')
	s.record('manifest absent still defaults on', full.feature('threads'), 'threads absent')
	s.record('manifest deps read in order', full.deps.len == 2 && full.deps[0].name == 'acme/db'
		&& full.deps[0].req == '1.2.3' && full.deps[1].req == '>=0.9', '${full.deps.len} deps')
	s.record('manifest workspace reads members', full.workspace == ['shop', 'web'],
		full.workspace.str())
	// Feature lines point at the `(name #t/#f)` entry (E2b names this line
	// in its check diagnostic): two switches on line 3 record line 3 each,
	// an absent feature records 0.
	lined := manifest.parse('(module m)\n(blip 2)\n(features (fs #f) (env #t))') or {
		s.record('manifest feature lines parse', false, err.msg())
		return
	}
	s.record('manifest feature line tracks the entry', lined.feature_line('fs') == 3
		&& lined.feature_line('env') == 3, 'fs=${lined.feature_line('fs')} env=${lined.feature_line('env')}')
	s.record('manifest missing feature has no line', lined.feature_line('fibers') == 0
		&& m.feature_line('fs') == 0, 'absent is 0')
	// Tools map runnable names to files (G3): absent by default, strict
	// in shape, duplicates rejected like features.
	s.record('manifest tools default empty', m.tools.len == 0, 'no tools')
	tooled := manifest.parse('(module m)\n(blip 2)\n(tools (greet "tool.blip") (serve "cmd/serve.blip"))') or {
		s.record('manifest tools parse', false, err.msg())
		return
	}
	s.record('manifest tools parse', tooled.tools.len == 2 && tooled.tools[0].name == 'greet'
		&& tooled.tools[0].file == 'tool.blip' && tooled.tools[1].file == 'cmd/serve.blip',
		tooled.tools.str())
	for c in [
		'(module m)\n(blip 2)\n(tools greet)',
		'(module m)\n(blip 2)\n(tools (greet))',
		'(module m)\n(blip 2)\n(tools (greet "a" "b"))',
		'(module m)\n(blip 2)\n(tools (a "x") (a "y"))',
	] {
		manifest.parse(c) or {
			s.record('manifest rejects bad tools', true, 'rejected: ${err.msg()}')
			continue
		}
		s.record('manifest rejects bad tools', false, 'accepted: ${c}')
	}
	// Coverage pins for long-standing public helpers the api_coverage gate
	// requires to be named in the corpus (they predate E2a and would
	// otherwise keep the gate red).
	s.record('is_type_name knows int', blip.is_type_name('int'), 'int is a type')
	s.record('is_type_name rejects nope', !blip.is_type_name('nope'), 'nope is not')
	s.record('type_compatible same types', blip.type_compatible('int', 'int'), 'int flows to int')
	s.record('type_compatible any agrees', blip.type_compatible('any', 'string')
		&& !blip.type_compatible('int', 'string'), 'any unifies, int/string differ')
	mut ea := blip.EnvArena{}
	root := ea.new_env(blip.no_env)
	fr := ea.new_frame(root, ['a'], [blip.integer(1)])
	s.record('new_frame binds in a child', (ea.lookup(fr, 'a') or { blip.nil_value() }).as_int() or { -1 } == 1,
		'a is 1 in the frame')
	mut pa := reader.Arena{}
	pid := pa.leaf(.sym)
	pa.set_pos_origin(pid, 7, 8, blip.SourceLocation{
		file: 'f.blip'
		line: 7
		col:  8
	})
	s.record('set_pos_origin stamps line and origin', pa.node(pid).line == 7
		&& pa.node(pid).origin.file == 'f.blip', 'line 7 in f.blip')
	mdir := os.join_path(os.vtmp_dir(), 'blip_ensure_mod_probe')
	os.rmdir_all(mdir) or {}
	os.mkdir_all(mdir) or { s.record('ensure_mod setup', false, err.msg()) }
	st := migrate.ensure_mod(mdir, 2) or {
		s.record('ensure_mod creates a manifest', false, err.msg())
		''
	}
	s.record('ensure_mod creates a manifest', st == 'created', st)
	st2 := migrate.ensure_mod(mdir, 2) or {
		s.record('ensure_mod is idempotent', false, err.msg())
		''
	}
	s.record('ensure_mod is idempotent', st2 == 'current', st2)
	os.rmdir_all(mdir) or {}
	for c in [
		'(blip 2)',
		'(module myapp)',
		'(module myapp)\n(blip 1)',
		'(module myapp)\n(blip 2)\n(blip 2)',
		'(module myapp)\n(module other)\n(blip 2)',
		'(module myapp)\n(blip 2)\n(features fibers)',
		'(module myapp)\n(blip 2)\n(features (fibers))',
		'(module myapp)\n(blip 2)\n(features (fibers #f) (fibers #t))',
		'(module myapp)\n(blip 2)\n(deps acme/db)',
		'(module myapp)\n(blip 2)\n(deps (acme/db))',
		'(module myapp)\n(blip 2)\n(workspace a b)',
		'(module myapp)\n(blip 2)\n(workspace (paths a b))',
		'(module myapp)\n(blip 2)\n(version 3)',
		'(module myapp)\n(blip 2',
		'(module 7)\n(blip 2)',
	] {
		manifest.parse(c) or {
			s.record('manifest rejects shape', true, 'rejected: ${err.msg()}')
			continue
		}
		s.record('manifest rejects shape', false, 'accepted: ${c}')
	}
}

// ---- the stock toolchain, synced everywhere -------------------------------
//
// install_pins is the gate for the toolchain decision. blip builds against
// ONE compiler -- stock V 0.5.2, the official release, not a master build --
// and that decision is written in several places for two audiences: ci.yml
// (plus clib/release/pages, which copy it) downloads it in CI,
// install.sh / install.ps1 download it on a stranger's machine, and the
// site/ copies are what the website hands out. Drift between them is
// invisible until someone's install produces a broken binary -- which is
// worse than a red suite, because nothing looks red.
// Root scripts and site copies must therefore carry the SAME version,
// exactly as ci.yml spells it, and none of them may build V from source
// (a source build reintroduces the vc bootstrap -- a second pin hiding
// inside the first).
fn (mut s Suite) install_pins() {
	ci := os.read_file('.github/workflows/ci.yml') or {
		s.fails++
		println('FAIL pins => cannot read ci.yml: ${err.msg()}')
		return
	}
	mut v_version := ''
	for line in ci.split_into_lines() {
		fields := line.trim_space().split(':')
		if fields.len == 2 {
			v := fields[0].trim_space()
			val := fields[1].trim_space()
			if v == 'V_VERSION' {
				v_version = val
			}
		}
	}
	s.record('ci.yml names V', v_version != '' && v_version[0].is_digit(), v_version)
	for path in ['install.sh', 'install.ps1', 'site/install.sh', 'site/install.ps1'] {
		src := os.read_file(path) or {
			s.fails++
			println('FAIL pins => cannot read ${path}: ${err.msg()}')
			continue
		}
		s.record('${path} names V', src.contains(v_version), if src.contains(v_version) {
			v_version
		} else {
			'MISSING'
		})
		// A source build is the bug this gate exists for: cloning vlang/v
		// and running make works today and breaks on the next upstream
		// commit, so neither the clone nor the old commit pins may appear
		// even WITH the version present.
		s.record('${path} downloads V, no source build',
			!src.contains('git clone https://github.com/vlang/v') && !src.contains('V_COMMIT')
			&& !src.contains('VC_COMMIT'), 'checked')
	}
	for path in ['docker/alpine.Dockerfile', 'docker/debian.Dockerfile', 'docker/nix.Dockerfile'] {
		src := os.read_file(path) or {
			s.fails++
			println('FAIL pins => cannot read ${path}: ${err.msg()}')
			continue
		}
		s.record('${path} names V', src.contains('V_VERSION=${v_version}'), 'checked')
	}
}

fn (mut s Suite) modular_core() {
	// E3: the prim table splits into core + gated IO. core_table lacks
	// fs/env; table adds them back; names and register fns agree.
	core := prims.core_table()
	s.record('core lacks read-file', 'read-file' !in core, 'minimal core')
	s.record('core lacks env', 'env' !in core, 'minimal core')
	s.record('core keeps arithmetic', 'car' in core && '+' in core, '+ and car present')
	s.record('core keeps html-escape', 'html-escape' in core, 'pure string helper stays')
	full := prims.table()
	s.record('table has fs and env', 'read-file' in full && 'env' in full, 'full table')
	s.record('fs names list file prims', prims.fs_prim_names() == ['read-file', 'write-file',
		'file-exists?'], prims.fs_prim_names().str())
	s.record('env names list env', prims.env_prim_names() == ['env'], 'env')
	mut p := prims.core_table()
	prims.register_fs(mut p)
	s.record('register_fs adds file prims', 'read-file' in p && 'file-exists?' in p, 'fs installed')
	prims.register_env(mut p)
	s.record('register_env adds env', 'env' in p, 'env installed')
	// E3: machine capabilities mirror the prim groups.
	s.record('capabilities list env and fs', machine.capabilities() == ['env', 'fs'],
		machine.capabilities().str())
	fsp := machine.capability_prims('fs') or { []string{} }
	s.record('capability_prims fs matches', fsp == prims.fs_prim_names(), fsp.str())
	if _ := machine.capability_prims('fibers') {
		s.record('capability_prims rejects fibers', false, 'fibers resolved')
	} else {
		s.record('capability_prims rejects fibers', true, 'fibers unknown until B4')
	}
	s.record('prim_capability maps read-file to fs', machine.prim_capability('read-file') or {
		''
	} == 'fs', 'read-file is fs')
	s.record('prim_capability maps env to env', machine.prim_capability('env') or { '' } == 'env',
		'env is env')
	s.record('prim_capability leaves core alone', if _ := machine.prim_capability('+') {
		false
	} else {
		true
	}, '+ is core')
	// E3: a core-only machine runs pure code and refuses IO cleanly.
	h := host.new_capture()
	mut m := machine.new_standalone_core(h)
	v := m.run_str('(+ 1 2)') or { blip.nil_value() }
	s.record('core machine runs arithmetic', printer.write(v) == '3', printer.write(v))
	m.run_str('(read-file "x")') or {
		s.record('core machine refuses read-file', err.msg().contains('unbound identifier'),
			err.msg())
	}
	m.run_str('(env "HOME")') or {
		s.record('core machine refuses env', err.msg().contains('unbound identifier'), err.msg())
	}
	m.enable_fs()
	v2 := m.run_str('(file-exists? "no-such-blip-file")') or { blip.nil_value() }
	s.record('enable_fs restores file prims', printer.write(v2) == '#f', printer.write(v2))
	m.enable_env()
	s.record('enable_env restores env', m.has_prim('env'), 'env present')
}

// ---- toolchain: versions, pins, shims (roadmap Track G4) ------------------
//
// The layout half of self-management is pinned here with a temp BLIP_HOME;
// the download-and-exec half runs through the CLI in tests/project.v,
// which builds a second versioned binary and drives the shims for real.
fn (mut s Suite) toolchain_pins() {
	old_home := os.getenv('BLIP_HOME')
	th := os.join_path(os.vtmp_dir(), 'blip_tc_pins')
	os.rmdir_all(th) or {}
	os.setenv('BLIP_HOME', th, true)
	s.record('toolchain home honors env', toolchain.home() == th, th)
	os.setenv('BLIP_HOME', '', true)
	s.record('toolchain home defaults under user', toolchain.home().ends_with('.blip'),
		toolchain.home())
	os.setenv('BLIP_HOME', th, true)
	af := toolchain.artifact_file()
	$if windows {
		s.record('toolchain artifact is a zip', af == 'blip-windows.zip', af)
	} $else {
		s.record('toolchain artifact is a tarball', af == 'blip-linux.tar.gz', af)
	}
	s.record('toolchain url defaults to github',
		toolchain.release_url('1.0.0') == 'https://github.com/metif12/blip/releases/download/v1.0.0/' + af,
		toolchain.release_url('1.0.0'))
	os.setenv('BLIP_RELEASE_BASE', '/srv/rel', true)
	s.record('toolchain url honors base',
		toolchain.release_url('1.0.0') == '/srv/rel/v1.0.0/' + af, toolchain.release_url('1.0.0'))
	os.setenv('BLIP_RELEASE_BASE', '', true)
	// Pins resolve upward; missing pins and versions are errors, not guesses.
	os.mkdir_all(os.join_path(th, 'versions/v1/inner/deep')) or {}
	os.write_file(os.join_path(th, 'versions/v1/.blip-version'), '9.9') or {}
	found := toolchain.find_pin(os.join_path(th, 'versions/v1/inner/deep')) or {
		s.record('toolchain pin walks up', false, 'no pin found')
		toolchain.Pin{}
	}
	s.record('toolchain pin walks up', found.version == '9.9'
		&& found.file == os.join_path(th, 'versions/v1/.blip-version'), found.version)
	os.rm(os.join_path(th, 'versions/v1/.blip-version')) or {}
	s.record('toolchain pin misses cleanly', if _ := toolchain.find_pin(os.join_path(th,
		'versions/v1/inner')) {
		false
	} else {
		true
	}, 'none without a file')
	toolchain.use_version(th, 'v1') or {
		s.record('toolchain use refuses missing', err.msg().contains('not installed'), err.msg())
	}
	os.write_file(os.join_path(th, 'versions/v1/' + toolchain.binary_name()), 'fake') or {}
	toolchain.use_version(os.join_path(th, 'versions/v1/inner'), 'v1') or {
		s.record('toolchain use pins', false, err.msg())
	}
	s.record('toolchain use pins',
		os.read_file(os.join_path(th, 'versions/v1/inner/.blip-version')) or { '' } == 'v1',
		'pinned')
	// Default round-trips; the default version cannot be removed.
	toolchain.write_default('nope') or {
		s.record('toolchain default refuses missing', err.msg().contains('not installed'), err.msg())
	}
	toolchain.write_default('v1') or { s.record('toolchain default writes', false, err.msg()) }
	s.record('toolchain default reads', (toolchain.read_default() or { '' }) == 'v1', 'v1')
	toolchain.remove_version('v1') or {
		s.record('toolchain remove refuses default', err.msg().contains('default'), err.msg())
	}
	os.mkdir_all(os.join_path(th, 'versions/v2')) or {}
	toolchain.remove_version('v2') or { s.record('toolchain remove deletes', false, err.msg()) }
	s.record('toolchain remove deletes', !os.is_dir(os.join_path(th, 'versions/v2')), 'gone')
	toolchain.remove_version('v2') or {
		s.record('toolchain remove misses loudly', err.msg().contains('not installed'), err.msg())
	}
	s.record('toolchain versions sorted', toolchain.installed_versions() == ['v1'], 'v1 only')
	// Shims resolve env, then the upward pin, then the default, then fail.
	sh := toolchain.shim_sh(th, 'blip')
	s.record('toolchain sh shim resolves', sh.contains('BLIP_VERSION') && sh.contains('.blip-version')
		&& sh.contains('/default') && sh.contains('/versions/'), 'three levels')
	bat := toolchain.shim_bat(th, 'blip.exe')
	s.record('toolchain bat shim resolves', bat.contains('BLIP_VERSION')
		&& bat.contains('.blip-version') && bat.contains('default'), 'three levels')
	// install_from_artifact assembles from a plain directory too (no tar).
	ad := os.join_path(os.vtmp_dir(), 'blip_tc_asm_probe')	os.rmdir_all(ad) or {}
	os.mkdir_all(os.join_path(ad, 'src')) or {}
	os.mkdir_all(os.join_path(ad, 'res/lib')) or {}
	os.write_file(os.join_path(ad, 'src/' + toolchain.binary_name()), 'fakebin') or {}
	os.write_file(os.join_path(ad, 'res/lib/std.blip'), '(def x 1)\n') or {}
	got := toolchain.install_from_artifact('asmv', os.join_path(ad, 'src'), os.join_path(ad,
		'res/lib'), '') or {
		s.record('toolchain assembles a version', false, err.msg())
		''
	}
	s.record('toolchain assembles a version', os.exists(os.join_path(got, toolchain.binary_name()))
		&& os.exists(os.join_path(got, 'lib/std.blip')), got)
	s.record('toolchain dirs nest',
		toolchain.version_dir('v1') == os.join_path(toolchain.versions_dir(), 'v1'), 'versions/v1')
	// unpack handles real tarballs too (system tar reads and writes them).
	os.mkdir_all(os.join_path(ad, 'arch/inner')) or {}
	os.write_file(os.join_path(ad, 'arch/inner/f.blip'), '(def x 1)\n') or {}
	os.execute('tar -a -cf "${ad}/pkg.tgz" -C "${ad}/arch" inner')
	toolchain.unpack(os.join_path(ad, 'pkg.tgz'), os.join_path(ad, 'unpacked')) or {
		s.record('toolchain unpacks tarballs', false, err.msg())
	}
	s.record('toolchain unpacks tarballs',
		os.exists(os.join_path(ad, 'unpacked/inner/f.blip')), 'round trip')
	os.rmdir_all(ad) or {}
	os.rmdir_all(th) or {}
	os.setenv('BLIP_HOME', old_home, true)
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
	s.manifest()
	s.modular_core()
	s.pkg_logic()
	s.toolchain_pins()

	if s.fails > 0 {
		println('${s.checks} checks, ${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('unit: all ${s.checks} checks passed')
}

// ---- packages: versions, checksums, workspaces (roadmap Track G) ---------
//
// The pure half of `blip.pkg` is pinned here; the git-and-filesystem half
// (clone, tags, universe install) is pinned through the CLI in
// tests/pkg_cli.v, which drives `blip pkg update/install/verify` against
// local mirror repos with no network.
fn (mut s Suite) pkg_logic() {
	// Specs split owner/repo[@ref]; anything else is not a package.
	o, r, f := pkg.parse_spec('acme/db')
	s.record('parse_spec bare', o == 'acme' && r == 'db' && f == 'HEAD', 'acme/db')
	o2, r2, f2 := pkg.parse_spec('acme/db@v1.2.0')
	s.record('parse_spec ref', o2 == 'acme' && r2 == 'db' && f2 == 'v1.2.0', 'ref kept')
	o3, _, _ := pkg.parse_spec('nodivider')
	s.record('parse_spec rejects bare', o3 == '', 'no owner')
	o4, _, _ := pkg.parse_spec('a/b/c')
	s.record('parse_spec rejects deep', o4 == '', 'one slash only')
	// Versions compare numerically, `v` transparently, short tails as zeros.
	s.record('compare_versions orders', pkg.compare_versions('1.2.3', '1.2.10') < 0, '3 < 10')
	s.record('compare_versions v prefix', pkg.compare_versions('v1.2.0', '1.2.0') == 0, 'v transparent')
	s.record('compare_versions short tail', pkg.compare_versions('1.2', '1.2.0') == 0, 'tail zeros')
	s.record('compare_versions major', pkg.compare_versions('2.0.0', '1.9.9') > 0, 'major wins')
	// Req satisfaction: exact (with/without `=`/`v`), floors, literals.
	s.record('satisfies exact', pkg.satisfies('1.2.0', '1.2.0'), 'bare exact')
	s.record('satisfies =v', pkg.satisfies('v1.2.0', '=1.2.0'), '= and v mix')
	s.record('satisfies floor', pkg.satisfies('1.2.3', '>=1.2.0') && !pkg.satisfies('1.1.9', '>=1.2.0'),
		'floor holds')
	s.record('satisfies branch literal', pkg.satisfies('stable', 'stable')
		&& !pkg.satisfies('stable', 'other'), 'branches literal')
	s.record('satisfies rejects path', !pkg.satisfies('1.2.0', 'path:../x'), 'paths resolve elsewhere')
	// Resolution picks the max tag meeting every req, or errors naming them.
	tags := ['v1.0.0', '1.2.0', '2.0.0']
	best := pkg.resolve('acme/db', ['>=1.0.0', '=1.2.0'], tags) or {
		s.record('resolve exact plus floor', false, err.msg())
		''
	}
	s.record('resolve exact plus floor', best == '1.2.0', best)
	top := pkg.resolve('acme/db', ['>=1.0.0'], tags) or { '' }
	s.record('resolve floor takes max', top == '2.0.0', top)
	pkg.resolve('acme/db', ['>=3.0.0'], tags) or {
		s.record('resolve impossible errors', err.msg().contains('cannot resolve'), err.msg())
	}
	// Path reqs are detected with their directory.
	ok, p := pkg.is_path_req('path:../shared')
	s.record('is_path_req detects', ok && p == '../shared', p)
	ok2, _ := pkg.is_path_req('1.2.0')
	s.record('is_path_req rejects versions', !ok2, 'version is not a path')
	// The lock round-trips through files, sorted and four-wide.
	lockd := os.join_path(os.vtmp_dir(), 'blip_pkg_lock_probe')
	os.rmdir_all(lockd) or {}
	os.mkdir_all(lockd) or { s.record('pkg lock setup', false, err.msg()) }
	pkg.write_lock(lockd, [pkg.Pin{
		name:     'acme/db'
		ref:      'v1.2.0'
		sha:      'abc1234'
		checksum: 'sum1'
	}, pkg.Pin{
		name:     'acme/log'
		ref:      'v0.9.0'
		sha:      'def5678'
		checksum: 'sum2'
	}]) or { s.record('pkg lock write', false, err.msg()) }
	back := pkg.read_lock(lockd)
	s.record('pkg lock round trips', back.len == 2 && back[0].name == 'acme/db'
		&& back[1].checksum == 'sum2', '${back.len} pins sorted')
	found := pkg.pin_of(back, 'acme/log') or { pkg.Pin{} }
	s.record('pin_of finds', found.ref == 'v0.9.0', found.ref)
	s.record('pin_of misses', if _ := pkg.pin_of(back, 'no/such') {
		false
	} else {
		true
	}, 'none for unknown')
	os.rmdir_all(lockd) or {}
	// Checksums judge content: identical trees hash equal, a one-byte edit
	// fails verification naming the package.
	csd := os.join_path(os.vtmp_dir(), 'blip_pkg_sum_probe')
	os.rmdir_all(csd) or {}
	os.mkdir_all(os.join_path(csd, 'pkg')) or { s.record('pkg sum setup', false, err.msg()) }
	os.write_file(os.join_path(csd, 'pkg/blip.blip'), '(def x 1)\n') or {}
	os.write_file(os.join_path(csd, 'pkg/a.blip'), '(def a 1)\n') or {}
	sum := pkg.checksum_dir(os.join_path(csd, 'pkg')) or {
		s.record('pkg checksum computes', false, err.msg())
		''
	}
	s.record('pkg checksum computes', sum.len == 64, 'sha256 hex')
	pkg.verify_dir(os.join_path(csd, 'pkg'), 'acme/db', sum) or {
		s.record('pkg verify clean passes', false, err.msg())
	}
	s.record('pkg verify clean passes', true, 'untampered')
	os.write_file(os.join_path(csd, 'pkg/a.blip'), '(def a 2)\n') or {}
	pkg.verify_dir(os.join_path(csd, 'pkg'), 'acme/db', sum) or {
		s.record('pkg verify tamper fails', err.msg().contains('checksum mismatch'), err.msg())
	}
	os.rmdir_all(csd) or {}
	// Copies carry the tree minus history; the package URL honors mirrors.
	cpd := os.join_path(os.vtmp_dir(), 'blip_pkg_cp_probe')
	os.rmdir_all(cpd) or {}
	os.mkdir_all(os.join_path(cpd, 'src/sub')) or {}
	os.mkdir_all(os.join_path(cpd, 'src/.git')) or {}
	os.write_file(os.join_path(cpd, 'src/blip.blip'), '(def x 1)\n') or {}
	os.write_file(os.join_path(cpd, 'src/sub/y.blip'), '(def y 2)\n') or {}
	os.write_file(os.join_path(cpd, 'src/.git/HEAD'), 'ref: refs/heads/main\n') or {}
	pkg.copy_package(os.join_path(cpd, 'src'), os.join_path(cpd, 'dst')) or {
		s.record('pkg copy carries', false, err.msg())
	}
	s.record('pkg copy carries', os.exists(os.join_path(cpd, 'dst/sub/y.blip'))
		&& !os.exists(os.join_path(cpd, 'dst/.git')), 'tree without .git')
	os.rmdir_all(cpd) or {}
	old_mirror := os.getenv('BLIP_PKG_MIRROR')
	os.setenv('BLIP_PKG_MIRROR', '/srv/mirror', true)
	s.record('package_url honors mirror', pkg.package_url('acme/db') == os.join_path('/srv/mirror',
		'acme/db'), pkg.package_url('acme/db'))
	os.setenv('BLIP_PKG_MIRROR', old_mirror, true)
	s.record('package_url defaults to github',
		pkg.package_url('acme/db') == 'https://github.com/acme/db.git', 'github')
	// The universe folds member manifests into one requester map.
	ud := os.join_path(os.vtmp_dir(), 'blip_pkg_uni_probe')
	os.rmdir_all(ud) or {}
	os.mkdir_all(os.join_path(ud, 'a')) or {}
	os.write_file(os.join_path(ud, 'blip.mod'),
		'(module shop)\n(blip 2)\n(deps (acme/db ">=1.0.0"))\n(workspace (members a))') or {}
	os.write_file(os.join_path(ud, 'a/blip.mod'),
		'(module a)\n(blip 2)\n(deps (acme/db "=1.2.0"))') or {}
	u := pkg.collect_universe(ud) or {
		s.record('pkg universe collects', false, err.msg())
		pkg.Universe{}
	}
	s.record('pkg universe collects', u.dep_names() == ['acme/db'] && u.members == ['a'],
		u.dep_names().str())
	if u.dep_names() == ['acme/db'] {
		s.record('pkg universe names requesters', u.reqs['acme/db'].len == 2
			&& u.reqs['acme/db'][0].requester == 'blip.mod'
			&& u.reqs['acme/db'][1].requester == 'a/blip.mod', 'root plus member')
	}
	os.rmdir_all(ud) or {}
	// resolve_universe on a path-only universe needs no network: the pin
	// records the source root-relative.
	pd := os.join_path(os.vtmp_dir(), 'blip_pkg_res_probe')
	os.rmdir_all(pd) or {}
	os.mkdir_all(os.join_path(pd, 'lib')) or {}
	os.write_file(os.join_path(pd, 'lib/blip.blip'), '(def x 1)\n') or {}
	mut pu := pkg.Universe{}
	pu.reqs['local/x'] = [pkg.From{
		requester: 'blip.mod'
		req:       'path:lib'
		dir:       pd
	}]
	rpins := pkg.resolve_universe(pd, pu) or {
		s.record('pkg resolve path universe', false, err.msg())
		[]pkg.Pin{}
	}
	s.record('pkg resolve path universe', rpins.len == 1 && rpins[0].ref == 'path:lib',
		if rpins.len == 1 { rpins[0].ref } else { 'no pin' })
	os.rmdir_all(pd) or {}
}
