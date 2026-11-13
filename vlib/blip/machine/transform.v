module machine

$if !wasm32 {
	import os
}

import strconv
import vlib.blip
import vlib.blip.host
import vlib.blip.prims
import vlib.blip.printer
import vlib.blip.reader

fn (mut m Machine) transform_match_star(kids []blip.NodeId) blip.NodeId {
	subjects := m.arena.kids(kids[1])
	// Every subject is passed straight into ONE `(list ...)` call, which is what
	// makes each exactly-once evaluation: the list is built before the match sees
	// it, and the match only ever reads it.
	//
	// An earlier version bound each subject to a fresh temporary first and did not
	// bind them in the generated `let`, so every `match*` failed with
	// "unbound identifier: s_1". The temporaries were never needed -- `(list a b)`
	// already evaluates each argument once.
	inner := m.call_node(m.sym_node('list'), subjects)
	mut clauses := []blip.NodeId{}
	mut c := 2
	for c < kids.len {
		ckids := m.arena.kids(kids[c])
		if ckids.len == 0 {
			c++
			continue
		}
		mut body := []blip.NodeId{}
		mut bi := 1
		for bi < ckids.len {
			body << ckids[bi]
			bi++
		}
		// One clause becomes [(list)] whose pattern is (list P1 P2 ...), so each
		// pattern sees the subject in its own position.
		mut pat := []blip.NodeId{}
		pat << m.sym_node('list')
		mut p := 0
		for p < ckids.len {
			pat << ckids[p]
			p++
		}
		clauses << m.list_of([m.list_of(pat), m.make_begin(body)])
		c++
	}
	mut items := []blip.NodeId{}
	items << m.sym_node('match')
	items << inner
	mut ci := 0
	for ci < clauses.len {
		items << clauses[ci]
		ci++
	}
	return m.list_of(items)
}

// let assert PATTERN VALUE body... => a match with no other clauses, so a failure
// is a hard error naming the pattern instead of falling through to nil.
//
// `kids` here has already had the word `assert` removed by transform_let, so it is
// the ordinary [let, BINDINGS, body...] shape with BINDINGS replaced by two forms.
//
// The subject is bound once and the `match` runs against the temporary, so a
// VALUE with a side effect is evaluated exactly once even though the transform
// mentions it twice.
fn (mut m Machine) transform_let_assert(kids []blip.NodeId) !blip.NodeId {
	// `(let assert PATTERN VALUE body...)` is a match with no other clause, so a
	// failure is a hard error naming the pattern instead of falling through to
	// nil.
	//
	// `kids` is [assert, BINDINGS, body...], where BINDINGS is the single
	// two-element vector [PATTERN VALUE]. An earlier version read the pattern out
	// of kids[1] and the value out of kids[2] -- the BINDINGS VECTOR and the first
	// body form -- so with a one-form body it fell into a `len < 4` guard and
	// returned nil, and `parse-in` in the standard library returned nil for every
	// input.
	//
	// The body goes INSIDE the matching clause, not after the match. A match binds
	// its names in its own clause frame, so a body sequenced after it saw none of
	// them -- "unbound identifier: s". Running the body in the clause means the
	// pattern bindings are in scope exactly where they should be.
	//
	// There is no temporary: `match` evaluates its subject once, so a VALUE with a
	// side effect is still evaluated exactly once.
	if kids.len < 3 {
		return error('let assert needs a pattern and a value')
	}
	bindings := m.arena.kids(kids[1])
	if bindings.len != 2 {
		return error('let assert takes exactly one binding, written [PATTERN VALUE]')
	}
	fail := m.node_of('error', [m.string_node('let assert failed: the value does not match the pattern')])
	return m.node_of('match', [bindings[1], m.list_of([bindings[0], m.make_begin(kids[2..])]),
		m.list_of([m.sym_node('_'), fail])])
}

// It is a continuation tag rather than a transform, and the reason is the one
// thing a transform cannot do here: `use` does not know how many names to bind.
// `(use (parse "x") a b)` binds two, `(use (commit conn) (print "done"))` binds
// zero, and the difference is only visible in the VALUE the call returned. A
// transform would have to guess -- from the number of body forms, which is what
// the first version did, and `(list-ref r 2)` on a one-element result is what
// that produced.
pub fn (mut m Machine) transform_let(kids []blip.NodeId) !blip.NodeId {
	// `(let assert PATTERN VALUE body...)` is `let` with the word `assert` in the
	// binding slot. It is read here rather than as its own head symbol so that
	// `(let assert ...)` needs no reader change and so that a program can use
	// `assert` as an ordinary variable name everywhere else.
	if kids.len > 1 && m.arena.node(kids[1]).tag == .sym
		&& m.arena.node(kids[1]).value == 'assert' {
		return m.transform_let_assert(kids[1..])!
	}
	// `(let NAME ((var init) ...) body...)` is R7RS named let. It is checked
	// BEFORE the one-binding shorthand, which shares its head shape: both are
	// `(let SYMBOL X body...)`. It is named let when X is a PARENTHESISED list
	// whose every element is a `(symbol expr)` / `[symbol expr]` pair. A
	// bracketed X stays a vector literal, so `(let m [[a 1]] ...)` still binds
	// m to a vector.
	if kids.len > 3 && m.arena.node(kids[1]).tag == .sym && m.is_named_let_bindings(kids[2]) {
		return m.transform_named_let(kids)
	}
	// `(let NAME VALUE body...)` is the one-binding shorthand. It is unambiguous
	// because a bracketed binding list can never be a symbol: kids[1] being a
	// symbol means the programmer left the brackets out.
	if kids.len > 2 && m.arena.node(kids[1]).tag == .sym {
		pair := m.list_of2([kids[1]], [kids[2]])
		mut rest := [kids[0], pair]
		rest << kids[3..]
		return m.transform_let(rest)
	}
	binds := m.arena.kids(kids[1])
	if binds.len == 0 {
		return m.make_begin(kids[2..])
	}
	// `let` evaluates every value in the ENCLOSING scope, then binds all names at
	// once. Nesting the bindings -- which is what this did first -- makes each
	// value see the names bound before it, which is `let*` semantics and wrong:
	// `(let ([a 1] [b (a 2)]) b)` stopped erroring on the unbound `a`.
	//
	// So the values are bound by ONE lambda, plain names and destructuring
	// temporaries alike, and the destructuring happens in nested lets INSIDE the
	// body where the temporaries are already bound.
	mut params := []blip.NodeId{}
	mut args := []blip.NodeId{}
	mut destructures := []Destructure{}
	mut i := 0
	for i < binds.len {
		if m.is_destructuring(binds[i]) {
			tmp := m.sym_node(m.fresh('let'))
			params << tmp
			args << m.binding_value(binds[i])
			destructures << Destructure{
				temp:  tmp
				parts: m.destructuring(m.binding_pattern(binds[i]), tmp)!
			}
		} else {
			params << m.binding_name(binds[i])
			args << m.binding_value(binds[i])
		}
		i++
	}
	mut dgroups := []Group{}
	for d in destructures {
		mut names := []blip.NodeId{}
		mut vals := []blip.NodeId{}
		for p in d.parts {
			names << p.name
			vals << p.accessor
		}
		dgroups << Group{
			params: names
			args:   vals
		}
	}
	inner := m.nest_lets(dgroups, kids[2..])
	lam := m.node_of('lambda', [m.list_of(params), inner])
	return m.call_node(lam, args)
}

// is_named_let_bindings says whether `b` reads as a named-let binding list:
// a paren list (possibly empty) of two-element forms headed by a symbol.
fn (m &Machine) is_named_let_bindings(b blip.NodeId) bool {
	if m.arena.node(b).tag != .list {
		return false
	}
	for pair in m.arena.kids(b) {
		if !m.is_binding_form(pair) {
			return false
		}
		k := m.arena.kids(pair)
		if k.len != 2 || m.arena.node(k[0]).tag != .sym {
			return false
		}
	}
	return true
}

// transform_named_let is the R7RS expansion:
//
//   (let NAME ((v init) ...) body...)
//     =>  ((letrec ((NAME (lambda (v ...) body...))) NAME) init ...)
//
// The inits are arguments of the OUTER call, so they are evaluated where the
// `let` is and cannot see NAME or each other -- the same scoping as plain
// `let`. A call to NAME in tail position of the body is an ordinary tail call,
// so a million iterations run in one frame.
fn (mut m Machine) transform_named_let(kids []blip.NodeId) blip.NodeId {
	name := kids[1]
	mut vars := []blip.NodeId{}
	mut inits := []blip.NodeId{}
	for pair in m.arena.kids(kids[2]) {
		vars << m.binding_name(pair)
		inits << m.binding_value(pair)
	}
	lam := m.node_of('lambda', [m.list_of(vars), m.make_begin(kids[3..])])
	bind := m.list_of([m.list_of([name, lam])])
	proc := m.node_of('letrec', [bind, name])
	return m.call_node(proc, inits)
}

// Group is one lambda's parameter list and argument list. `let` is a nest of
// these rather than one wide lambda because destructuring needs a scope per step.
pub struct Group {
pub mut:
	params []blip.NodeId
	args   []blip.NodeId
}

// nest_lets builds the lambda nest, putting the body LAST so that the body stays
// in tail position at every level.
fn (mut m Machine) nest_lets(groups []Group, body []blip.NodeId) blip.NodeId {
	if groups.len == 0 {
		return m.make_begin(body)
	}
	g := groups[0]
	lam := m.node_of('lambda', [m.list_of(g.params), m.nest_lets(groups[1..], body)])
	return m.call_node(lam, g.args)
}

// Destructured is one name a destructuring binding introduces, with the EXPRESSION
// that produces it.
pub struct Destructured {
pub mut:
	name     blip.NodeId
	accessor blip.NodeId
}

// destructuring expands a binding pattern into names and accessor expressions.
//
// `(let ([(list h t) xs]) body)` becomes
//
//	(let ([__v xs]) (let ([h (list-ref __v 0)] [t (list-ref __v 1)]) body))
//
// and NOT a `match` over the pattern. The match version was the first attempt and
// it is wrong in a way that only shows up on the second line: a `match` binds its
// names in the frame of its own clause, so `body` -- evaluated after the match has
// returned -- cannot see them. It reported "unbound identifier: h".
//
// Accessors rather than a match also means a destructuring binding costs nothing
// at run time and cannot fail at run time, which is what a binding should be.
pub fn (mut m Machine) destructuring(pattern blip.NodeId, value blip.NodeId) ![]Destructured {
	d := m.arena.node(pattern)
	if d.tag == .sym {
		if d.value == '_' {
			return []Destructured{}
		}
		return [Destructured{
			name:     pattern
			accessor: value
		}]
	}
	if d.tag == .kw || d.tag == .int || d.tag == .str {
		return error('${m.render_node(pattern)} cannot be a destructuring binding: it is a literal')
	}
	if d.tag == .table {
		kids := m.arena.kids(pattern)
		mut out := []Destructured{}
		mut i := 0
		for i + 1 < kids.len {
			k := m.arena.node(kids[i])
			if k.tag != .kw {
				return error('a table destructuring binding needs keyword keys')
			}
			out << Destructured{
				name:     kids[i + 1]
				accessor: m.call_node(m.sym_node('get'), [value, kids[i]])
			}
			i += 2
		}
		return out
	}
	if d.tag != .list {
		return error('${m.render_node(pattern)} cannot be a destructuring binding')
	}
	kids := m.arena.kids(pattern)
	if kids.len == 0 {
		return []Destructured{}
	}
	head := m.pattern_head(pattern)
	if head == 'cons' {
		if kids.len != 3 {
			return error('(cons head tail) needs a head and a tail')
		}
		return [Destructured{
			name:     kids[1]
			accessor: m.call_node(m.sym_node('car'), [value])
		}, Destructured{
			name:     kids[2]
			accessor: m.call_node(m.sym_node('cdr'), [value])
		}]
	}
	if head == 'list' || head == 'vector' || head == '' {
		// No tail capture here, deliberately. In a MATCH, `(list 1 rest)` binds
		// the remainder, and `is_capturing_tail` decides that from a bare symbol in
		// the last position. In a BINDING that reading is ambiguous -- `(list h t)`
		// would bind only `h` and treat `t` as the rest -- so positions are
		// positional: `(list h t)` binds exactly two elements.
		mut out := []Destructured{}
		mut i := 1
		for i < kids.len {
			out << m.destructuring(kids[i], m.call_node(m.sym_node('list-ref'), [
				value,
				m.int_node(i64(i - 1)),
			]))!
			i++
		}
		return out
	}
	if head == 'struct' {
		if kids.len < 2 {
			return error('(struct Name f: p ...) needs a name and a field')
		}
		nm := m.arena.node(kids[1])
		if nm.tag != .sym {
			return error('a struct destructuring binding needs a struct name')
		}
		mut out := []Destructured{}
		mut i := 2
		for i < kids.len {
			f := m.arena.node(kids[i])
			mut fname := ''
			if f.tag == .kw {
				fname = f.value
			} else if f.tag == .sym && f.value.ends_with(':') {
				fname = f.value[..f.value.len - 1]
			} else {
				return error('a struct destructuring field must be written field: pattern')
			}
			if i + 1 >= kids.len {
				return error('field ${fname} has no name')
			}
			out << m.destructuring(kids[i + 1], m.call_node(m.sym_node('${nm.value.to_lower()}-${fname}'), [value]))!
			i += 2
		}
		return out
	}
	return error('${m.render_node(pattern)} cannot be a destructuring binding')
}

// empty_collection is the literal with no elements. A table and an array are
// distinct tags even when empty, because the reader told us which was written.
// try => run the body, and hand a raised error to a handler instead of aborting.
//
//	(try body...
//	     #:catch [(err e) (print "caught:" (err-message e))]
//	     #:finally [(print "cleanup")])
//
// This cannot be a transform, because the catch clause is a PATTERN and patterns
// are runtime data: the handler has to be matched against the error value when
// the error arrives. So `try` pushes a frame that holds the body forms and
// evaluates them one at a time; `raise` unwinds the continuation stack to it.
//
// `slot` says what the frame is waiting for:
//	>= 0  body[slot] has just finished
//	-1    #:finally has just finished -- return val2
//	-3    the catch clause has just finished -- run #:finally, or return val2
pub fn (mut m Machine) match_clause(subject blip.NodeId, pattern blip.NodeId) blip.NodeId {
	fail := m.node_of('error', [m.string_node('pattern did not match'), m.call_node(m.sym_node('format'), [
		m.string_node('~a does not match ~a'),
		subject,
		pattern,
	])])
	return m.node_of('match', [subject, m.list_of([pattern, m.sym_node('nil')]),
		m.list_of([m.sym_node('_'), fail])])
}

// let* => nested single-binding lets, so each value sees the previous name.
//
// The obvious version passes 1 as the starting index, treating `binds_at` as a
// count of forms already consumed. It is not: `binds_at` indexes
// `kids[1]`'s children, the binding group, so it must start at 0. Starting at 1
// silently DROPPED the first binding -- `(let* ([a 1] [b (+ a 1)]) b)` compiled to
// `(let ([b (+ a 1)]) b)`, whose `a` is then genuinely unbound in the enclosing
// scope. That is why the failure read as "unbound identifier: a" and was
// misdiagnosed for a while as the `[...]`-in-two-positions problem.
pub fn (mut m Machine) transform_let_star(kids []blip.NodeId) blip.NodeId {
	return m.transform_let_star_at(kids, 0)
}

fn (mut m Machine) transform_let_star_at(kids []blip.NodeId, binds_at int) blip.NodeId {
	binds := m.arena.kids(kids[1])
	if binds_at >= binds.len {
		return m.make_begin(kids[2..])
	}
	inner := m.transform_let_star_at(kids, binds_at + 1)
	mut one := []blip.NodeId{}
	one << binds[binds_at]
	mut items := []blip.NodeId{}
	items << m.sym_node('let')
	items << m.list_of(one)
	items << inner
	return m.list_of(items)
}

// letrec => every name is visible to every value, so all names are bound to nil
// first and then assigned.
// letrec needs the names in scope BEFORE their values are evaluated, so the
// values can see each other. Binding them as lambda parameters does that:
//
//   (letrec ([a A] [b B]) body)
//     => ((lambda (a b) (set! a A) (set! b B) body...) #f #f)
//
// The parameters start as #f placeholders. The earlier version instead
// `(set! a nil)` in the ENCLOSING scope, which required the name to already
// exist: `(letrec ([e ...] [o ...]) ...)` failed with "cannot set unbound
// identifier" unless `e` happened to be defined globally first, and it leaked
// every letrec binding into the global frame.
pub fn (mut m Machine) transform_letrec(kids []blip.NodeId) blip.NodeId {
	binds := m.arena.kids(kids[1])
	if binds.len == 0 {
		return m.make_begin(kids[2..])
	}
	nilq := m.arena.open(.quoted)
	m.arena.finish(nilq, [m.nil_node()])

	mut params := []blip.NodeId{}
	mut stmts := []blip.NodeId{}
	mut holes := []blip.NodeId{}
	// An index loop, not `for b in binds`: V 0.5.2 emits an unresolved `NodeId`
	// in the generated C for a range loop over a []blip.NodeId, so the alias
	// from another module has to be indexed by hand to compile.
	mut idx := 0
	for idx < binds.len {
		b := binds[idx]
		name := m.binding_name(b)
		params << name
		holes << nilq
		stmts << m.node_of('set!', [name, m.binding_value(b)])
		idx++
	}
	mut bi := 2
	for bi < kids.len {
		stmts << kids[bi]
		bi++
	}
	lam := m.node_of('lambda', [m.list_of(params), m.make_begin(stmts)])
	return m.call_node(lam, holes)
}

// cond => nested ifs.
pub fn (mut m Machine) transform_cond(kids []blip.NodeId) blip.NodeId {
	mut items := []blip.NodeId{}
	mut ci := 1
	for ci < kids.len {
		items << kids[ci]
		ci++
	}
	return m.cond_from(items)
}

fn (mut m Machine) cond_from(items []blip.NodeId) blip.NodeId {
	if items.len == 0 {
		return m.nil_node()
	}
	clause := m.arena.kids(items[0])
	if clause.len == 0 {
		return m.nil_node()
	}
	head := m.arena.node(clause[0])
	if head.tag == .sym && head.value == 'else' {
		if clause.len == 1 {
			return m.nil_node()
		}
		return m.make_begin(clause[1..])
	}
	if clause.len == 1 {
		// (cond (test)) => (let ([t test]) (if t t nil))
		t := m.sym_node('__cond_t')
		body := m.node_of('if', [t, t, m.nil_node()])
		// The lambda's PARAMETER list is (t); the binding form (t test) is what
		// goes through `let`.
		lam := m.node_of('lambda', [m.list_of([t]), body])
		return m.call_node(lam, [clause[0]])
	}
	// The `=>` marker is the SECOND element of the clause: a clause is
	// (test => proc), so test is kids[0], the marker is kids[1], and the
	// procedure is kids[2]. Checking kids[0] for `=>` never matched.
	if clause.len == 3 && m.arena.node(clause[1]).tag == .sym
		&& m.arena.node(clause[1]).value == '=>' {
		// (cond (test => proc)) => (let ([f proc]) (if test (f) rest))
		f := m.sym_node('__cond_f')
		rest := m.cond_from(items[1..])
		body := m.node_of('if', [clause[0], m.call_node(f, []blip.NodeId{}), rest])
		// The lambda's PARAMETER list is (f). The binding form (f proc) is what
		// goes through `let`, not what a lambda takes.
		lam := m.node_of('lambda', [m.list_of([f]), body])
		return m.call_node(lam, [clause[2]])
	}
	rest := m.cond_from(items[1..])
	return m.node_of('if', [clause[0], m.make_begin(clause[1..]), rest])
}

// case => cond with `=` against the subject.
pub fn (mut m Machine) transform_case(kids []blip.NodeId) blip.NodeId {
	subject := kids[1]
	mut items := []blip.NodeId{}
	mut ci := 2
	for ci < kids.len {
		clause := m.arena.kids(kids[ci])
		if clause.len == 0 {
			ci++
			continue
		}
		head := m.arena.node(clause[0])
		if head.tag == .sym && head.value == 'else' {
			mut body := m.nil_node()
			if clause.len > 1 {
				body = m.make_begin(clause[1..])
			}
			items << m.list_of([m.sym_node('else'), body])
			// `else` ends the search: nothing after it can be reached, and keeping
			// it would make any later clause dead. So break, not continue.
			break
		}
		// A clause is [tests-list body...]: clause[0] holds the values to
		// compare against, and everything after it is the body. Reading the
		// body as another test value evaluated `(1 2)` as a call.
		tests := m.arena.kids(clause[0])
		if tests.len == 0 {
			ci++
			continue
		}
		mut body := m.nil_node()
		if clause.len > 1 {
			body = m.make_begin(clause[1..])
		}
		mut combined := m.call_node(m.sym_node('='), [subject, tests[0]])
		mut j := 1
		for j < tests.len {
			combined = m.node_of('or', [combined, m.call_node(m.sym_node('='), [
				subject,
				tests[j],
			])])
			j++
		}
		items << m.list_of([combined, body])
		ci++
	}
	return m.cond_from(items)
}

// loop is a named let: (loop name init body...) has the same shape as
// (let ([name init]) body...), and transform_let_at already builds the lambda
// application. Binding the name in the new frame is what makes the body able to
// refer to itself.
pub fn (mut m Machine) transform_loop(kids []blip.NodeId) blip.NodeId {
	// (loop name init test body...) has a DIFFERENT shape from let -- the name
	// and init are separate arguments, not a binding list -- so it cannot share
	// let's transform.
	//
	// It is a named let, whose standard definition is:
	//
	//   (let name ([name init]) body)
	//     =>  (letrec ([name (lambda (name) body)]) (name init))
	//
	// The inner lambda shadows `name` with itself, which is what lets the body
	// call `(name ...)` again. Without that self-binding the loop body would
	// refer to a dead binding and the first recursive call would fail.
	if kids.len < 4 {
		return m.make_begin(kids[2..])
	}
	name := kids[1]
	init := kids[2]
	test := kids[3]

	// `(loop i 0 ...)` names the variable `i`, and the loop function needs a
	// different name, or the body's `(f i)` would resolve `f` to the integer
	// parameter rather than the closure.
	fnname := m.sym_node(m.fresh('loop'))

	// The body has to advance the variable AND call itself, otherwise the
	// transform runs the body exactly once and returns. Both go at the end of
	// the body, and the call is in tail position of the lambda, so TCO still
	// holds: a million iterations use one frame.
	mut stmts := []blip.NodeId{}
	mut bi := 4
	for bi < kids.len {
		stmts << kids[bi]
		bi++
	}
	stmts << m.node_of('set!', [name, m.call_node(m.sym_node('+'), [name, m.int_node(1)])])
	stmts << m.call_node(fnname, [name])
	body := m.make_begin(stmts)

	// (lambda (name) (if test body nil))
	inner := m.node_of('if', [test, body, m.nil_node()])
	lam := m.node_of('lambda', [m.list_of([name]), inner])

	// (letrec ([f lam]) (f init))
	bindform := m.list_of([fnname, lam])
	letrec := m.node_of('letrec', [m.list_of([bindform]), m.call_node(fnname, [init])])
	return letrec
}

// dotimes => (loop i 0 (< i n) body...)
pub fn (mut m Machine) transform_dotimes(kids []blip.NodeId) !blip.NodeId {
	if kids.len < 3 {
		return error('dotimes needs a loop variable and a count')
	}
	loopvar := m.arena.node(kids[1])
	if loopvar.tag != .sym {
		return error('dotimes needs a symbol as its loop variable, got ${printer.write_datum(m.arena, kids[1])}')
	}
	lt := m.call_node(m.sym_node('<'), [kids[1], kids[2]])
	mut items := []blip.NodeId{}
	items << kids[1]
	items << m.int_node(0)
	items << lt
	mut i := 3
	for i < kids.len {
		items << kids[i]
		i++
	}
	return m.node_of('loop', items)
}

// binding_name extracts the name of a binding form: either a bare symbol or the
// head of (name expr). A lambda parameter list needs the NAME, not the form, so
// let has to map each binding through this before building its lambda.
//
// blip accepts both (name expr) and [name expr] as the binding form, because
// `[...]` is a VECTOR here and the documentation and examples write it that way.
// Checking only for `.list` silently passed the whole vector through as a
// parameter name, which surfaced as "lambda parameters must be symbols".
fn (mut m Machine) is_binding_form(b blip.NodeId) bool {
	tag := m.arena.node(b).tag
	return tag == .list || tag == .vector
}

pub fn (mut m Machine) binding_name(b blip.NodeId) blip.NodeId {
	if m.is_binding_form(b) {
		k := m.arena.kids(b)
		if k.len > 0 {
			return k[0]
		}
	}
	return b
}

// binding_value extracts the value expression of a binding form.
pub fn (mut m Machine) binding_value(b blip.NodeId) blip.NodeId {
	if m.is_binding_form(b) {
		k := m.arena.kids(b)
		if k.len > 1 {
			return k[1]
		}
	}
	return b
}

pub fn (m &Machine) is_destructuring(b blip.NodeId) bool {
	if !m.is_binding_form(b) {
		return false
	}
	k := m.arena.kids(b)
	if k.len == 0 {
		return false
	}
	bd := m.arena.node(k[0])
	return bd.tag in [.list, .table, .vector]
}

// binding_pattern is the left side of a destructuring binding.
pub fn (m &Machine) binding_pattern(b blip.NodeId) blip.NodeId {
	return m.arena.kids_view(b)[0]
}

// match_clause builds `(match subject [pattern body] [_ (error ...)])`.
//
// A destructuring binding is a promise, not a branch, so a mismatch is an error
// rather than a fall-through. That is the difference between `let` and `let assert`
// in the examples, and making it an error here means the destructuring case does
// not need a second implementation.
