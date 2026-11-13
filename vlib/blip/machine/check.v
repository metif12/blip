module machine

import blip

// check.v -- `blip check`: the static checker for erased annotations (M10).
//
// The machine erases every annotation: `(x int)` binds `x`, and a return
// position holds no runtime meaning at all. This file is the other half of
// that deal -- it reads the same source the machine would run and reports
// the mismatches running never does, as `file:line:col: message` diagnostics
// with a non-zero exit, without evaluating anything.
//
// Scope is deliberately v1 (every limit below is documented, not discovered):
//
//   * Only calls the checker has a signature for are judged: functions
//     defined with annotated `define` in the same file, `define/contract`
//     arities, and a small table of core prims. Anything else --
//     unannotated functions, the prelude, macros -- is `any`, and `any`
//     unifies with everything. An unknown name is never an error; the
//     checker proves mismatches, it does not guess at them.
//   * Types are `int`, `float`, `string`, `bool`, and `any`. No `number`,
//     no collections, no function types.
//   * `let` bindings are tracked only when the init is a literal. Pattern
//     positions (`match` patterns, `let-assert` patterns, quasiquoted
//     data) are data, never checked as calls.
//   * `define/contract` contributes arities, not types: contracts are
//     predicates checked at run time, and the checker does not evaluate.
//   * A `->/c` outside `define/contract` is reported where it stands: it is
//     syntax for the contract clause, not a callable.
//
// A file that passes is not proven correct. A file that fails names a real
// arity or literal-type mismatch at a real source position.

pub struct CheckDiag {
pub:
	line int
	col  int
	msg  string
}

struct CkParam {
	name string
	typ  string
}

struct CkSig {
	params []CkParam
	ret    string
	// arity is the exact argument count, or -1 when the checker cannot
	// know it (rest, labelled, or destructured parameters). A known
	// function called with the wrong count is always reported; an
	// unknown-arity one is never judged on count.
	arity int
}

// ck_prim_sig is the whole primitive table: arithmetic over numbers,
// comparisons and `not` to bool, `error` to anything. Small on purpose --
// every entry here is a promise the checker must keep, and a wrong promise
// is worse than silence.
fn ck_prim_sig(name string) ?CkSig {
	match name {
		'+', '-', '*', '/' {
			return CkSig{
				ret:   'int'
				arity: -1
			}
		}
		'=', '<', '>', '<=', '>=' {
			return CkSig{
				ret:   'bool'
				arity: -1
			}
		}
		'not' {
			return CkSig{
				ret:   'bool'
				arity: -1
			}
		}
		'error' {
			return CkSig{
				ret:   'any'
				arity: -1
			}
		}
		else {
			return none
		}
	}
}

// check_source checks already-read top-level forms and returns one
// diagnostic per mismatch, in source order.
pub fn (mut m Machine) check_source(forms []blip.NodeId) []CheckDiag {
	mut diags := []CheckDiag{}
	mut sigs := map[string]CkSig{}
	for f in forms {
		m.collect_sig(f, mut sigs)
	}
	for f in forms {
		m.check_top(f, sigs, mut diags)
	}
	return diags
}

fn (mut m Machine) check_diag(id blip.NodeId, msg string, mut diags []CheckDiag) {
	o := m.arena.node(id).origin
	diags << CheckDiag{
		line: o.line
		col:  o.col
		msg:  msg
	}
}

// collect_sig records one top-level function signature: annotated `define`
// (params and return) and `define/contract` (arity only -- contracts are
// predicates, not types, and the checker does not evaluate).
fn (mut m Machine) collect_sig(id blip.NodeId, mut sigs map[string]CkSig) {
	if m.arena.node(id).tag != .list {
		return
	}
	kids := m.arena.kids(id)
	if kids.len == 0 || m.arena.node(kids[0]).tag != .sym {
		return
	}
	head := m.arena.node(kids[0]).value
	if head != 'define' && head != 'define/contract' {
		return
	}
	if kids.len < 3 {
		return
	}
	if m.arena.node(kids[1]).tag != .list {
		return
	}
	sig := m.arena.kids(kids[1])
	if sig.len == 0 || m.arena.node(sig[0]).tag != .sym {
		return
	}
	name := m.arena.node(sig[0]).value
	if head == 'define/contract' {
		// Simple names only -- the machine refuses the rest at define
		// time, so the checker mirrors that rather than modelling it.
		mut ok := true
		mut n := 0
		for p in sig[1..] {
			if m.arena.node(p).tag != .sym {
				ok = false
			}
			n++
		}
		if ok {
			sigs[name] = CkSig{
				arity: n
			}
		}
		return
	}
	mut params := []CkParam{}
	mut simple := true
	mut skip_next := false
	for p in sig[1..] {
		pp := m.arena.node(p)
		if skip_next {
			skip_next = false
			continue
		}
		if pp.tag == .sym {
			if pp.value == '.' {
				// A rest parameter: the count is a minimum, not exact,
				// and the name after the dot is the rest name, not a
				// fixed parameter.
				simple = false
				skip_next = true
				continue
			}
			params << CkParam{
				name: pp.value
				typ:  'any'
			}
			continue
		}
		if m.is_erased_annotation(p) {
			an := m.arena.kids(p)
			params << CkParam{
				name: m.arena.node(an[0]).value
				typ:  m.arena.node(an[1]).value
			}
			continue
		}
		// Destructured, labelled, or keyword: the checker does not model
		// the binding, so the arity is unknown too.
		simple = false
	}
	mut ret := 'any'
	if kids.len > 3 && m.arena.node(kids[2]).tag == .sym
		&& blip.is_type_name(m.arena.node(kids[2]).value) {
		ret = m.arena.node(kids[2]).value
	}
	sigs[name] = CkSig{
		params: params
		ret:    ret
		arity:  if simple { params.len } else { -1 }
	}
}

// lit_type names the type of a self-evaluating literal, or '' when the node
// is not one.
fn (m &Machine) lit_type(id blip.NodeId) string {
	match m.arena.node(id).tag {
		.int { return 'int' }
		.float { return 'float' }
		.str { return 'string' }
		.bool { return 'bool' }
		else { return '' }
	}
}

fn (mut m Machine) check_top(id blip.NodeId, sigs map[string]CkSig, mut diags []CheckDiag) {
	_ = m.check_form(id, map[string]string{}, 'any', sigs, mut diags)
}

// check_form checks one form and returns its known type ('any' when unknown).
// `ret` is the enclosing define's declared return, or 'any' outside one.
fn (mut m Machine) check_form(id blip.NodeId, env map[string]string, ret string, sigs map[string]CkSig, mut diags []CheckDiag) string {
	d := m.arena.node(id)
	if d.tag != .list {
		if d.tag == .sym {
			return env[d.value] or { 'any' }
		}
		t := m.lit_type(id)
		if t != '' {
			return t
		}
		return 'any'
	}
	kids := m.arena.kids(id)
	if kids.len == 0 {
		return 'any'
	}
	if m.arena.node(kids[0]).tag != .sym {
		for k in kids {
			m.check_form(k, env, ret, sigs, mut diags)
		}
		return 'any'
	}
	head := m.arena.node(kids[0]).value
	args := if kids.len > 1 { kids[1..] } else { []blip.NodeId{} }
	match head {
		'quote', 'quasi', 'quasiquote' {
			return 'any'
		}
		'if' {
			if args.len == 0 {
				return 'any'
			}
			m.check_form(args[0], env, ret, sigs, mut diags)
			if args.len < 2 {
				return 'any'
			}
			t1 := m.check_form(args[1], env, ret, sigs, mut diags)
			if args.len < 3 {
				return 'any'
			}
			t2 := m.check_form(args[2], env, ret, sigs, mut diags)
			if t1 == t2 {
				return t1
			}
			return 'any'
		}
		'begin', 'do' {
			mut t := 'any'
			for a in args {
				t = m.check_form(a, env, ret, sigs, mut diags)
			}
			return t
		}
		'time' {
			if args.len == 0 {
				return 'any'
			}
			return m.check_form(args[0], env, ret, sigs, mut diags)
		}
		'let', 'let*', 'letrec' {
			return m.check_let(id, args, env, ret, sigs, mut diags)
		}
		'lambda', 'fn' {
			if args.len == 0 {
				return 'any'
			}
			mut inner := env.clone()
			for p in m.arena.kids(args[0]) {
				if m.arena.node(p).tag == .sym {
					inner[m.arena.node(p).value] = 'any'
					continue
				}
				if m.is_erased_annotation(p) {
					an := m.arena.kids(p)
					inner[m.arena.node(an[0]).value] = m.arena.node(an[1]).value
				}
			}
			for b in args[1..] {
				m.check_form(b, inner, 'any', sigs, mut diags)
			}
			return 'any'
		}
		'define' {
			return m.check_define(id, args, env, sigs, mut diags)
		}
		'define/contract' {
			// The contract clause is syntax, not a call: walking into it
			// would judge `(->/c even?)` as a call of unknown arity.
			if args.len < 3 {
				return 'any'
			}
			mut inner := env.clone()
			sig := m.arena.kids(args[0])
			for p in sig[1..] {
				if m.arena.node(p).tag == .sym {
					inner[m.arena.node(p).value] = 'any'
				}
			}
			for b in args[2..] {
				m.check_form(b, inner, 'any', sigs, mut diags)
			}
			return 'any'
		}
		'set!' {
			if args.len >= 2 {
				m.check_form(args[args.len - 1], env, ret, sigs, mut diags)
			}
			return 'any'
		}
		'assert' {
			if args.len >= 1 {
				m.check_form(args[0], env, ret, sigs, mut diags)
			}
			return 'any'
		}
		'cond' {
			for c in args {
				if m.arena.node(c).tag != .list {
					continue
				}
				ck := m.arena.kids(c)
				for b in ck {
					m.check_form(b, env, ret, sigs, mut diags)
				}
			}
			return 'any'
		}
		'case' {
			if args.len == 0 {
				return 'any'
			}
			m.check_form(args[0], env, ret, sigs, mut diags)
			for c in args[1..] {
				if m.arena.node(c).tag != .list {
					continue
				}
				ck := m.arena.kids(c)
				// ck[0] is the datum list -- data, not a call.
				for b in ck[1..] {
					m.check_form(b, env, ret, sigs, mut diags)
				}
			}
			return 'any'
		}
		'match', 'match*' {
			if args.len == 0 {
				return 'any'
			}
			m.check_form(args[0], env, ret, sigs, mut diags)
			for c in args[1..] {
				if m.arena.node(c).tag != .list {
					continue
				}
				ck := m.arena.kids(c)
				mut bi := 0
				// A leading #:when guard is code; the pattern after it
				// is data and is skipped, never checked as a call.
				if bi < ck.len && m.is_when_guard(ck[bi]) {
					if bi + 1 < ck.len {
						m.check_form(ck[bi + 1], env, ret, sigs, mut diags)
					}
					bi += 2
				}
				// The pattern itself.
				bi++
				// A trailing #:when guard is code too.
				if bi < ck.len && m.is_when_guard(ck[bi]) {
					if bi + 1 < ck.len {
						m.check_form(ck[bi + 1], env, ret, sigs, mut diags)
					}
					bi += 2
				}
				if bi > ck.len {
					bi = ck.len
				}
				for b in ck[bi..] {
					m.check_form(b, env, ret, sigs, mut diags)
				}
			}
			return 'any'
		}
		'and', 'or', 'when', 'unless', '->', '->>', '|>', 'as->', 'cond->', 'use', 'defined?' {
			for a in args {
				m.check_form(a, env, ret, sigs, mut diags)
			}
			return 'any'
		}
		'struct', 'struct-out', 'defmacro', 'macex', 'macex1', 'require', 'provide', 'import',
		'let-assert' {
			return 'any'
		}
		'->/c' {
			m.check_diag(id, '->/c outside define/contract', mut diags)
			return 'any'
		}
		else {
			return m.check_call(id, head, args, env, ret, sigs, mut diags)
		}
	}
}

// is_when_guard reports whether id is a match guard keyword. Both
// spellings are accepted: the reader keeps `#:when`, and either way the
// checker only needs to know the next form is code.
fn (m &Machine) is_when_guard(id blip.NodeId) bool {
	d := m.arena.node(id)
	return d.tag == .kw && (d.value == '#:when' || d.value == 'when')
}

// check_let checks a let-family form: inits are checked, literal-typed inits
// name their type, and the body is checked in the extended scope.
fn (mut m Machine) check_let(id blip.NodeId, args []blip.NodeId, env map[string]string, ret string, sigs map[string]CkSig, mut diags []CheckDiag) string {
	if args.len == 0 {
		return 'any'
	}
	if m.arena.node(args[0]).tag == .sym && m.arena.node(args[0]).value == 'assert' {
		// `(let assert [PATTERN VALUE] body...)`: the pattern is data.
		// The value and the bodies are code.
		if args.len >= 2 && m.arena.node(args[1]).tag == .list {
			bk := m.arena.kids(args[1])
			if bk.len == 2 {
				m.check_form(bk[1], env, ret, sigs, mut diags)
			}
		}
		mut t := 'any'
		if args.len > 2 {
			for b in args[2..] {
				t = m.check_form(b, env, ret, sigs, mut diags)
			}
		}
		_ = id
		return t
	}
	mut first := 0
	mut inner := env.clone()
	if m.arena.node(args[0]).tag == .sym {
		// Named let: the name binds nothing here.
		first = 1
	}
	if args.len < first + 1 {
		return 'any'
	}
	if m.arena.node(args[first]).tag == .list {
		for b in m.arena.kids(args[first]) {
			// A binding is a two-element vector, `[name init]`.
			if m.arena.node(b).tag != .vector {
				continue
			}
			bk := m.arena.kids(b)
			if bk.len < 2 || m.arena.node(bk[0]).tag != .sym {
				continue
			}
			t := m.check_form(bk[1], inner, ret, sigs, mut diags)
			if t != 'any' {
				inner[m.arena.node(bk[0]).value] = t
			}
		}
	}
	mut t := 'any'
	for b in args[first + 1..] {
		t = m.check_form(b, inner, ret, sigs, mut diags)
	}
	_ = id
	return t
}

// check_define checks a function or value define. A nested define registers
// nothing (signatures are top-level only) but its body is still checked
// against its own declared return.
fn (mut m Machine) check_define(id blip.NodeId, args []blip.NodeId, env map[string]string, sigs map[string]CkSig, mut diags []CheckDiag) string {
	if args.len == 0 {
		return 'any'
	}
	if m.arena.node(args[0]).tag != .list {
		if args.len >= 2 {
			m.check_form(args[1], env, 'any', sigs, mut diags)
		}
		return 'any'
	}
	sig := m.arena.kids(args[0])
	if sig.len == 0 || m.arena.node(sig[0]).tag != .sym {
		return 'any'
	}
	mut inner := env.clone()
	for p in sig[1..] {
		if m.arena.node(p).tag == .sym {
			inner[m.arena.node(p).value] = 'any'
			continue
		}
		if m.is_erased_annotation(p) {
			an := m.arena.kids(p)
			inner[m.arena.node(an[0]).value] = m.arena.node(an[1]).value
		}
	}
	mut body_at := 1
	mut fret := 'any'
	if args.len > 2 && m.arena.node(args[1]).tag == .sym
		&& blip.is_type_name(m.arena.node(args[1]).value) {
		fret = m.arena.node(args[1]).value
		body_at = 2
	}
	mut t := 'any'
	for b in args[body_at..] {
		t = m.check_form(b, inner, fret, sigs, mut diags)
	}
	if fret != 'any' && t != 'any' && t != fret {
		m.check_diag(id, '${m.arena.node(sig[0]).value} promises ${fret}, body gives ${t}', mut
			diags)
	}
	return 'any'
}

// check_call checks a call against a known signature: arity when fixed, and
// argument types where both sides are known. Unknown callees, unknown
// arguments, and `any` on either side are silence, not errors.
fn (mut m Machine) check_call(id blip.NodeId, head string, args []blip.NodeId, env map[string]string, ret string, sigs map[string]CkSig, mut diags []CheckDiag) string {
	mut atypes := []string{}
	for a in args {
		atypes << m.check_form(a, env, ret, sigs, mut diags)
	}
	if head.contains('.') {
		// A dotted head is a field read or update, not a function call.
		return 'any'
	}
	if head in sigs {
		s := sigs[head]
		if s.arity >= 0 && args.len != s.arity {
			m.check_diag(id, '${head} expects ${s.arity} arguments, got ${args.len}', mut diags)
			return s.ret
		}
		mut i := 0
		for i < args.len && i < s.params.len {
			want := s.params[i].typ
			if want != 'any' && atypes[i] != 'any' && atypes[i] != want {
				m.check_diag(id,
					'${head} expects ${want} for ${s.params[i].name}, got ${atypes[i]}', mut diags)
			}
			i++
		}
		return s.ret
	}
	if c := ck_prim_sig(head) {
		if head in ['+', '-', '*', '/'] {
			for t in atypes {
				if t != 'any' && t != 'int' && t != 'float' {
					m.check_diag(id, '${head} needs numbers, got ${t}', mut diags)
				}
			}
			if 'float' in atypes {
				return 'float'
			}
			return 'int'
		}
		return c.ret
	}
	return 'any'
}
