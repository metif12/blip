module emit

$if !wasm32 {
	import os
}

import blip
import blip.host
import blip.machine
import blip.reader

fn pat(js string, names []string) Pat {
	// Names are made UNIQUE here, once, because a pattern may bind the same name
	// twice -- `(nil nil)` in 03_match's match* does exactly that -- and blip's
	// frame defines a name once no matter how many bindings mention it. Emitting
	// `const nil` twice in one block is a JavaScript SyntaxError, so the file
	// would not parse at all.
	mut uniq := []string{}
	for n in names {
		if n !in uniq {
			uniq << n
		}
	}
	return Pat{
		js:    js
		names: uniq
		ok:    true
	}
}

fn bad_pat() Pat {
	return Pat{}
}

// pattern compiles a blip pattern into the tagged-array form `pat_match` reads.
//
// The rules are machine/match.v's, read rather than reinvented:
//   _ / else        ["wc"]
//   a bare symbol   ["sym", name]              binds the whole subject
//   a literal       ["lit", value]             and nil-as-pattern, which match.v
//                                                reads as the EMPTY sequence
//   (list p ...)    ["list", p...]              (vector p...) is the same shape
//   (cons p t)      ["cons", p, t]
//   {:k p}          ["table", "k", p...]
//   (struct N f: p) ["struct", "N", "f", p...]
//   (and p ...)     ["and", p...]
//   (or p ...)      ["or", p...]
//   (f a ...)       ["pred", f, a...]          subject first, and only for the
//                                                names match.v lists
//   (a b ...)       positional, the headless form `match*` produces
//
// A pattern is COMPILED once, when the module is emitted, rather than re-read on
// every match: the shape is fixed by then, so a mistake in one rule is one
// broken pattern shape instead of a slow program.
fn (mut e Emitter) pattern(id reader.NodeId) Pat {
	d := e.node(id)
	match d.tag {
		.sym {
			if d.value == '_' || d.value == 'else' {
				return pat('["wc"]', [])
			}
			return pat('["sym", ${json_str(e.mangle_name(d.value))}]',
				[e.mangle_name(d.value)])
		}
		.nil {
			return pat('["lit", null]', [])
		}
		.int, .float, .str, .bool, .char, .rat, .kw {
			return pat('["lit", ${e.value(id)}]', [])
		}
		.table, .array, .buffer {
			kids := e.kids(id)
			mut parts := ['"table"']
			mut names := []string{}
			mut i := 0
			for i + 1 < kids.len {
				k := e.node(kids[i])
				if k.tag != .kw {
					e.refuse('table pattern')
					return bad_pat()
				}
				sub := e.pattern(kids[i + 1])
				if !sub.ok {
					return bad_pat()
				}
				parts << json_str(k.value)
				parts << sub.js
				names << sub.names
				i += 2
			}
			return pat('[${parts.join(', ')}]', names)
		}
		.list, .vector {
			return e.sequence_pattern(e.kids(id))
		}
		else {
			e.refuse('pattern')
			return bad_pat()
		}
	}
}

// sequence_pattern compiles a list-shaped pattern, dispatching on its head the
// way match_list_at does. An empty pattern is the empty sequence, and a head
// that is not a symbol is the positional form a match* clause becomes.
fn (mut e Emitter) sequence_pattern(kids []reader.NodeId) Pat {
	if kids.len == 0 {
		return pat('["lit", null]', [])
	}
	head := e.node(kids[0])
	// A headless pattern, `(1 2 x)`, is the shape a match* clause becomes. It is
	// NOT the same rule as the `list`-headed form: measured, `(a b c)` on
	// '(1 2 3) binds c to (2 3) while `(list a b c)` binds it to 3. blip's
	// match_list_tail tail-captures on a bare last symbol unconditionally and the
	// `list` branch tests the length first, so the two compile to different nodes.
	if head.tag != .sym {
		return e.positional_pattern(kids, 'pos')
	}
	match head.value {
		'list', 'vector' {
			return e.positional_pattern(kids[1..], 'list')
		}
		'cons' {
			if kids.len != 3 {
				e.refuse('cons pattern')
				return bad_pat()
			}
			h := e.pattern(kids[1])
			t := e.pattern(kids[2])
			if !h.ok || !t.ok {
				return bad_pat()
			}
			mut names := []string{}
			names << h.names
			names << t.names
			return pat('["cons", ${h.js}, ${t.js}]', names)
		}
		'and', 'or' {
			mut parts := [json_str(head.value)]
			mut names := []string{}
			for k in kids[1..] {
				p := e.pattern(k)
				if !p.ok {
					return bad_pat()
				}
				parts << p.js
				names << p.names
			}
			return pat('[${parts.join(', ')}]', names)
		}
		'struct' {
			if kids.len < 2 {
				e.refuse('struct pattern')
				return bad_pat()
			}
			nm := e.node(kids[1])
			if nm.tag != .sym {
				e.refuse('struct pattern')
				return bad_pat()
			}
			mut parts := ['"struct"', json_str(nm.value)]
			mut names := []string{}
			mut i := 2
			for i < kids.len {
				f := e.node(kids[i])
				mut field := ''
				if f.tag == .kw {
					field = f.value
				} else if f.tag == .sym && f.value.ends_with(':') {
					field = f.value[..f.value.len - 1]
				} else {
					e.refuse('struct pattern')
					return bad_pat()
				}
				if i + 1 >= kids.len {
					e.refuse('struct pattern')
					return bad_pat()
				}
				sub := e.pattern(kids[i + 1])
				if !sub.ok {
					return bad_pat()
				}
				parts << json_str(field)
				parts << sub.js
				names << sub.names
				i += 2
			}
			return pat('[${parts.join(', ')}]', names)
		}
		else {
			// `(>= 100)`: a call to a known procedure with the SUBJECT as its
			// first argument (match.v pushes the subject, then the operands).
			// Recognised by name from match.v's own list, so a user function
			// named `list` cannot change what a pattern means.
			if !pattern_predicate(head.value) {
				return e.positional_pattern(kids, 'pos')
			}
			mut parts := ['"pred"', e.symbol(head.value)]
			for k in kids[1..] {
				parts << e.value(k)
			}
			return pat('[${parts.join(', ')}]', [])
		}
	}
}

// positional_pattern is the `(a b c)` shape, with the last position allowed to
// take the remainder. Whether it does is decided by the RUNTIME, because that
// depends on the subject's length: positional first, tail second.
//
// The `pos` node DROPS its first element. That is not a quirk of the emitter:
// machine/match.v's positional() is handed the whole `kids` and match_list_tail
// then reads `rest := kids[1..]`, so a headless pattern's first element is
// treated as a head and never tested. Measured, and the rule explains all three:
// `(a b c)` on '(1 2 3) is [b c], so `c` takes (2 3); `(_ _ x)` is [_ x], so `x`
// takes (2 3); and `(x _)` is [_], which binds nothing at all -- which is why blip
// reports `x` unbound in that clause's body.
fn (mut e Emitter) positional_pattern(kids []reader.NodeId, node string) Pat {
	mut parts := [json_str(node)]
	mut names := []string{}
	mut rest := if node == 'pos' { kids[1..] } else { kids }
	for k in rest {
		p := e.pattern(k)
		if !p.ok {
			return bad_pat()
		}
		parts << p.js
		names << p.names
	}
	return pat('[${parts.join(', ')}]', names)
}

// binding_pattern compiles a pattern used to DESTROY rather than to match, in a
// `let` binding or a function parameter. It is not `pattern`, and the difference
// is not cosmetic: `machine/mod.v` destructuring is positional with NO tail
// capture, because `(list h t)` binding `h` alone and calling `t` the remainder
// would be the wrong reading in a binding. So a sequence binding compiles to
// `["fix", ...]` and a table binding to `["btab", ...]`, both of which the
// runtime treats differently from their matching counterparts.
fn (mut e Emitter) binding_pattern(id reader.NodeId) Pat {
	d := e.node(id)
	match d.tag {
		.sym {
			if d.value == '_' || d.value == 'else' {
				return pat('["wc"]', [])
			}
			return pat('["sym", ${json_str(e.mangle_name(d.value))}]',
				[e.mangle_name(d.value)])
		}
		.nil, .int, .float, .str, .bool, .char, .rat, .kw {
			return pat('["lit", ${e.value(id)}]', [])
		}
		.table, .array, .buffer {
			kids := e.kids(id)
			mut parts := ['"btab"']
			mut names := []string{}
			mut i := 0
			for i + 1 < kids.len {
				k := e.node(kids[i])
				if k.tag != .kw {
					e.refuse('table binding')
					return bad_pat()
				}
				sub := e.binding_pattern(kids[i + 1])
				if !sub.ok {
					return bad_pat()
				}
				parts << json_str(k.value)
				parts << sub.js
				names << sub.names
				i += 2
			}
			return pat('[${parts.join(', ')}]', names)
		}
		.list, .vector {
			kids := e.kids(id)
			if kids.len == 0 {
				return pat('["fix"]', [])
			}
			head := e.node(kids[0])
			// `and`, `or` and the predicate forms test; a binding cannot, so they
			// are refused rather than compiled into something that binds nothing.
			if head.tag == .sym && (head.value == 'and' || head.value == 'or'
				|| pattern_predicate(head.value)) {
				e.refuse('binding pattern')
				return bad_pat()
			}
			if head.tag == .sym && head.value == 'struct' {
				return e.struct_binding(kids)
			}
			if head.tag == .sym && head.value == 'cons' {
				if kids.len != 3 {
					e.refuse('cons binding')
					return bad_pat()
				}
				h := e.binding_pattern(kids[1])
				t := e.binding_pattern(kids[2])
				if !h.ok || !t.ok {
					return bad_pat()
				}
				mut names := []string{}
				names << h.names
				names << t.names
				return pat('["cons", ${h.js}, ${t.js}]', names)
			}
			// `(list a b)` and the headless `(a b)` are both just positions.
			mut positions := if head.tag == .sym && (head.value == 'list' || head.value == 'vector') {
				kids[1..]
			} else {
				kids
			}
			mut parts := ['"fix"']
			mut names := []string{}
			for k in positions {
				sub := e.binding_pattern(k)
				if !sub.ok {
					return bad_pat()
				}
				parts << sub.js
				names << sub.names
			}
			return pat('[${parts.join(', ')}]', names)
		}
		else {
			e.refuse('binding pattern')
			return bad_pat()
		}
	}
}

// struct_binding is `(struct Point x: px y: py)` in a parameter or a binding: the
// name is checked, then each field is bound to its own sub-pattern.
fn (mut e Emitter) struct_binding(kids []reader.NodeId) Pat {
	if kids.len < 2 {
		e.refuse('struct binding')
		return bad_pat()
	}
	nm := e.node(kids[1])
	if nm.tag != .sym {
		e.refuse('struct binding')
		return bad_pat()
	}
	mut parts := ['"struct"', json_str(nm.value)]
	mut names := []string{}
	mut i := 2
	for i < kids.len {
		f := e.node(kids[i])
		mut field := ''
		if f.tag == .kw {
			field = f.value
		} else if f.tag == .sym && f.value.ends_with(':') {
			field = f.value[..f.value.len - 1]
		} else {
			e.refuse('struct binding')
			return bad_pat()
		}
		if i + 1 >= kids.len {
			e.refuse('struct binding')
			return bad_pat()
		}
		sub := e.binding_pattern(kids[i + 1])
		if !sub.ok {
			return bad_pat()
		}
		parts << json_str(field)
		parts << sub.js
		names << sub.names
		i += 2
	}
	return pat('[${parts.join(', ')}]', names)
}

// pattern_let emits a `let` whose bindings are PATTERNS rather than names.
//
// The values are evaluated first, in order, before any pattern is matched --
// `let` binds simultaneously, and a value that has a side effect must run even
// if a later pattern misses. A pattern that misses binds nil for the plain
// `let`, because blip's destructuring builds `get` and `list-ref` calls and
// those answer rather than fail; `let assert` is the spelling that fails loudly.
fn (mut e Emitter) pattern_let(bindings []reader.NodeId, body []reader.NodeId) {
	mut vals := []string{}
	mut pats := []Pat{}
	for b in bindings {
		inner := e.kids(b)
		if inner.len < 2 {
			e.refuse('let binding')
			return
		}
		vals << e.test_of(inner[1])
		p := e.binding_pattern(inner[0])
		if !p.ok {
			return
		}
		pats << p
	}
	e.gensym++
	e.emit('(() => {')
	for i, v in vals {
		tag := '__blip_l${e.gensym}${i}'
		e.emit('const ${tag} = pat_match(${pats[i].js}, ${v});')
		for nm in pats[i].names {
			e.emit('const ${nm} = ${tag} ? ${tag}["${nm}"] : null;')
		}
	}
	e.depth++
	for i, b in body {
		if i == body.len - 1 {
			e.emit('return ${e.value(b)};')
		} else {
			e.stmt(b)
		}
	}
	e.depth--
	e.emit('})();')
}

// pattern_predicate is machine/match.v's own list, copied rather than
// imported: the emitter is a separate module and matching one name here against
// that list is what keeps `(list 1 2)` a list pattern rather than a predicate.
fn pattern_predicate(name string) bool {
	return name in ['<', '>', '<=', '>=', '=', 'not=', 'eq?', 'zero?', 'even?', 'odd?', 'positive?',
		'negative?', 'list?', 'pair?', 'vector?', 'table?', 'array?', 'string?', 'symbol?', 'keyword?',
		'integer?', 'float?', 'number?', 'boolean?', 'rune?', 'nil?', 'null?', 'function?']
}

// match_expr emits a whole `match` or `match*` as ONE IIFE.
//
// It used to emit a `let` statement for the subject and a chain of ternaries as
// the expression. That works only where a statement is legal: in EXPRESSION
// position -- `(print (match x ...))` -- it put a `let` in the middle of an
// expression, which is not JavaScript. An IIFE is legal everywhere, and it also
// gives the clause bindings a real scope, which the guard needs: a guard is
// evaluated with the pattern's bindings in scope and falls through when false.
fn (mut e Emitter) match_expr(kids []reader.NodeId) string {
	head_node := e.node(kids[0])
	if kids.len < 3 {
		e.refuse('match')
		return 'null'
	}
	// `match*` is a macro over `match` whose shape is fixed here, exactly as
	// transform_match_star fixes it in the machine: every subject goes into ONE
	// `list` call, so each is evaluated exactly once, and each clause becomes a
	// pattern with one position per subject.
	is_star := head_node.value.ends_with('*')
	mut subject := ''
	if is_star {
		subj_kids := e.kids(kids[1])
		mut parts := []string{}
		for s in subj_kids {
			parts << e.value(s)
		}
		subject = 'blip.list(${parts.join(', ')})'
	} else {
		subject = e.value(kids[1])
	}
	e.gensym++
	subj := '__blip_subject${e.gensym}'
	mut lines := []string{}
	lines << 'const ${subj} = ${subject};'
	for i := 2; i < kids.len; i++ {
		parts := e.kids(kids[i])
		if parts.len == 0 {
			continue
		}
		mut pi := 0
		mut guard := ''
		// A guard may lead the clause or follow the pattern; machine/mod.v reads
		// both now, and the example writes the trailing one.
		if e.node(parts[0]).tag == .kw && e.node(parts[0]).value == 'when' {
			if parts.len < 2 {
				e.refuse('match guard')
				return 'null'
			}
			guard = e.value(parts[1])
			pi = 2
		}
		if pi >= parts.len {
			continue
		}
		mut p := bad_pat()
		if is_star {
			// Each sub-pattern gets its own position in the subject list, which is
			// what makes a clause try only when ALL of them match, and what makes
			// every subject exactly-once.
			mut pp := []string{}
			mut names := []string{}
			for k in e.kids(parts[pi]) {
				sp := e.pattern(k)
				if !sp.ok {
					return 'null'
				}
				pp << sp.js
				names << sp.names
			}
			p = pat('["list", ${pp.join(', ')}]', names)
		} else {
			p = e.pattern(parts[pi])
		}
		if !p.ok {
			return 'null'
		}
		pi++
		// The clause bindings are in scope for the GUARD and the body, and both
		// are emitted after this. A guard that cannot see what its pattern bound
		// cannot work, and a body that says `rest` means the binding rather than
		// the primitive -- so the scope goes up before either is emitted, not
		// after.
		mark := e.push_locals(p.names)
		if pi < parts.len && e.node(parts[pi]).tag == .kw && e.node(parts[pi]).value == 'when' {
			if pi + 1 >= parts.len {
				e.pop_locals(mark)
				e.refuse('match guard')
				return 'null'
			}
			guard = e.value(parts[pi + 1])
			pi += 2
		}
		if pi >= parts.len {
			e.pop_locals(mark)
			continue
		}
		// The value of the clause is its LAST form. Earlier ones run for their
		// effects, and the comma operator is what makes that true in an
		// expression position. seq_values keeps the earlier ones driven: built
		// with `.map(e.value)`, a clause whose body was emitted whole in a tail
		// position emitted `thunk(...)` operands the comma never forces, and
		// the clause silently did nothing but look plausible.
		body := e.seq_values(parts[pi..]).join(', ')
		tag := '__blip_b${e.gensym}${i}'
		lines << '{ const ${tag} = pat_match(${p.js}, ${subj});'
		lines << 'if (${tag} !== "no") {'
		for name in p.names {
			lines << 'const ${name} = ${tag}["${name}"];'
		}
		if guard == '' {
			lines << 'return ${body};'
		} else {
			lines << 'if (blip_truthy(${guard})) { return ${body}; }'
		}
		lines << '} }'
		e.pop_locals(mark)
	}
	// No clause matched: a `match` answers nil, the way the machine does.
	lines << 'return null;'
	return '(() => {\n${lines.join('\n')}\n})()'
}

// test_of emits a value in ORDINARY position, for a place whose result is
// CONSUMED rather than returned: a `cond` test, a `when` test, a `let` binding
// value.
//
// It matters because a test is wrapped in `blip_truthy`, which does not drive a
// thunk -- so a test emitted in tail position handed it a thunk object, always
// compared as true, and every `cond` took its first branch. A binding value
// emitted in tail position was a thunk too, so the binding held a function and
// the first use of it failed somewhere else entirely.
fn (mut e Emitter) case_expr(kids []reader.NodeId) string {
	if kids.len < 3 {
		return 'null'
	}
	subject := e.value(kids[1])
	mut out := 'null'
	for i := kids.len - 1; i >= 2; i-- {
		parts := e.kids(kids[i])
		if parts.len < 2 {
			continue
		}
		pattern := e.node(parts[0])
		is_else := pattern.tag == .sym && pattern.value == 'else'
		body := e.seq_values(parts[1..]).join(', ')
		if is_else {
			out = '(${body})'
			continue
		}
		// A pattern that is a LIST is "any of these", not "equal to this list":
		// `(case 5 [(1 2 3) 'low'] [(4 5 6) 'mid'])` matches on 5 because it is
		// in the first group. Emitting the group as a value would compare 5 to
		// `[1, 2, 3]` and never match.
		if pattern.tag == .list {
			alts := e.kids(parts[0])
			if alts.len == 0 {
				continue
			}
			mut tests := []string{}
			for a in alts {
				ad := e.node(a)
				if ad.tag !in literal_tags {
					e.refuse('case pattern')
					return 'null'
				}
				tests << 'blip.p_equal_q(${subject}, ${e.value(a)})'
			}
			out = '((${tests.join(' || ')}) ? (${body}) : ${out})'
			continue
		}
		// A pattern that is not a literal cannot be matched by equality, and
		// guessing at its meaning would be worse than refusing it.
		if pattern.tag !in literal_tags {
			e.refuse('case pattern')
			return 'null'
		}
		out = '(blip.p_equal_q(${subject}, ${e.value(parts[0])}) ? (${body}) : ${out})'
	}
	return out
}

// literal_tags are the datums case and match can compare by equality.
const literal_tags = [reader.DatumTag.int, .float, .str, .char, .bool, .nil, .kw, .rat]

// match_expr builds `(match subject [pattern result] ...)` as nested tests.
//
// A bare symbol in a pattern is a BINDING, not a comparison -- that is the one
// rule that surprises everyone, and it is why `(match 5 [x 'bound])` answers
// `bound` rather than falling through. `_` matches anything without binding.
// pattern compiles a blip pattern into the tagged-array form `pat_match` reads.
// It returns false when the pattern cannot be compiled, and says why through
// `refuse`.
//
// The rules are machine/match.v's, read rather than reinvented:
//   _ / else        ["wc"]
//   a bare symbol   ["sym", name]              binds the whole subject
//   a literal       ["lit", value]             nil included, and nil-as-pattern
//                                                means the EMPTY SEQUENCE
//   (list p ...)    ["list", p...]              and the same for (vector p...)
//   (cons p t)      ["cons", p, t]
//   {:k p}          ["table", "k", p...]
//   (struct N f: p) ["struct", "N", "f", p...]
//   (and p ...)     ["and", p...]
//   (or p ...)      ["or", p...]
//   (f a ...)       ["pred", f, a...]          f is subject-first, and only
//                                                for the names match.v lists
//   (a b ...)       positional, the headless form match* produces
//
// A pattern is COMPILED rather than re-interpreted on every call: the shape is
// fixed when the module is emitted, so the runtime walks data instead of
// re-reading syntax, and a mistake in one rule shows up as one broken pattern
// shape rather than a slow program.
// Pat is a compiled pattern: the JavaScript expression `pat_match` reads, and
// the names it binds. Only the emitter knows the names -- the runtime collects
// them into an object -- so they travel back with the compiled form.
struct Pat {
	js    string
	names []string
	ok    bool
}

fn (mut e Emitter) test_of(id reader.NodeId) string {
	saved := e.tail
	e.tail = 0
	v := e.value(id)
	e.tail = saved
	return v
}

// use_expr emits `(use (f args...) body...)` as one IIFE.
//
// The rules, from machine/mod.v's `.use_k`:
//
//   - the CALL runs, and an (err _) result SKIPS the body and becomes the value
//     of the whole `use`. That is what makes `use` safe to chain: nothing after a
//     failure sees a half-bound name.
//   - a single value binds to the CALLEE's name -- `(use (connect "h") ...)`
//     binds `conn`, which is what makes the stacked form read as four flat lines.
//   - several values bind positionally to r1, r2, ... because a body you can read
//     without counting parens is the entire point.
//
// How MANY names to bind is not knowable when the module is emitted, which is why
// this is a continuation in the machine and not a transform: a transform would
// have to guess from the number of body forms. So the emitted body declares a
// window of rN names and reads out of the result. That window (use_arity_max) is
// the one honest limitation here -- a call returning more values than that binds
// the first windowful and drops the rest, rather than emitting a name nobody can
// predict. The alternative, emitting the body twice for the one-value and
// many-value paths, is exponential in the nesting: the example stacks four
// levels.
const use_arity_max = 8
