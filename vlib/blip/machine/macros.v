module machine

$if !wasm32 {
	import os
}

import strconv
import blip
import blip.host
import blip.prims
import blip.printer
import blip.reader

// Frame is the datum_to_value worklist element. It lives beside its only
// user rather than in mod.v: V 0.5.2 mis-reports "evaluated but not used"
// for a variable used only as an argument to a recursive call inside a
// for-loop body, which is why datum_to_value is iterative at all.
struct Frame {
mut:
	id    blip.NodeId
	kids  []blip.NodeId
	start int
}

fn (mut m Machine) eval_defmacro(kids []blip.NodeId) ! {
	if kids.len < 4 {
		return error('defmacro needs a name, a parameter list and a body: (defmacro name (args) body)')
	}
	name_node := m.arena.node(kids[1])
	if name_node.tag != .sym {
		return error('defmacro needs a name')
	}
	name := name_node.value
	spec := m.parse_params(m.arena.kids(kids[2]), name)!
	body := m.apply_destructures(spec, m.make_begin(kids[3..]))
	m.envs.define(m.env, name, m.make_closure(spec, body, m.env, name))
	m.macros << name
	m.val = blip.symbol(name)
	m.ret()
}

// macex1 expands a macro form once and returns whatever came out, macro or not.
fn (mut m Machine) macex1(n blip.NodeId) !blip.Value {
	// The form is turned into a value first and expanded there, so `macex` can
	// loop on the RESULT -- which is a value -- without converting back and forth.
	return m.expand_macro_value(m.datum_to_value(n)!)
}

fn (m &Machine) is_macro_form(v blip.Value) bool {
	if v.tag != .pair {
		return false
	}
	head := (v.as_pair() or { return false }).car
	if head.tag != .symbol {
		return false
	}
	found := m.envs.lookup(m.globals, head.as_string() or { return false }) or {
		return false
	}
	return found.tag == .closure && m.is_macro_closure(found)
}

// is_macro_closure asks whether a closure was made by defmacro. It is recorded as
// a name in a set rather than guessed from, because a guess would expand every
// procedure that happens to take a form.
fn (m &Machine) is_macro_closure(v blip.Value) bool {
	if v.tag != .closure {
		return false
	}
	return (v.as_closure() or { return false }).name in m.macros
}

// expand_macro_value runs one macro over `v` when `v` is a macro call, and
// returns `v` unchanged when it is not.
//
// Everything here works on VALUES, not on forms. A macro's arguments are already
// values -- that is what "unevaluated" means once the reader has run -- so the
// expansion of one macro can be expanded again without a reader or an arena
// NodeId anywhere in the loop.
fn (mut m Machine) expand_macro_value(v blip.Value) !blip.Value {
	if !m.is_macro_form(v) {
		return v
	}
	name := (v.as_pair() or { return error(err.msg()) }).car.as_string() or {
		return error(err.msg())
	}
	macro := m.envs.lookup(m.globals, name) or {
		return error('macex: ${name} is not defined')
	}
	if !m.is_macro_closure(macro) {
		return error('macex: ${name} is not a macro')
	}
	args := prims.seq((v.as_pair() or { return error(err.msg()) }).cdr) or {
		return error('macex: ${name} has no arguments')
	}
	return m.call_value(macro, args)!
}

fn (mut m Machine) macex(n blip.NodeId) !blip.Value {
	mut v := m.macex1(n)!
	mut i := 0
	// Eight rounds is a bound, not a hope: a macro that expands to itself would
	// otherwise hang, and the failure a reader wants is "macex did not terminate",
	// not a machine at the step limit forty seconds later.
	for i < 8 {
		if !m.is_macro_form(v) {
			return v
		}
		v = m.expand_macro_value(v)!
		i++
	}
	if m.is_macro_form(v) {
		return error('macex: still a macro after 8 expansions; a macro is probably expanding to itself')
	}
	return v
}

// struct => a constructor, a predicate, an accessor per field, and (when mutable)
// a setter per field.
//
// It works by generating a few definitions in blip source and evaluating them in
// THIS machine. That looks roundabout next to building closures by hand, and it
// is the right trade for two reasons: a blip Closure needs an arena NodeId for its
// body, so building one by hand means synthesising source text anyway; and a
// primitive that takes a machine cannot be expressed in the prims table at all.
// The definitions land in the current frame, so `(define (f p) (point-x p))` can
// see `point-x` -- a struct you cannot name from another function is not a type.
pub fn (mut m Machine) datum_to_value(id blip.NodeId) !blip.Value {
	mut built := map[blip.NodeId]blip.Value{}
	mut work := []Frame{}
	work << Frame{
		id:    id
		kids:  m.arena.kids(id)
		start: 0
	}
	for work.len > 0 {
		mut f := work[work.len - 1]
		work = work[..work.len - 1]
		if f.start < f.kids.len {
			work << Frame{
				id:    f.id
				kids:  f.kids
				start: f.start + 1
			}
			work << Frame{
				id:    f.kids[f.start]
				kids:  m.arena.kids(f.kids[f.start])
				start: 0
			}
			continue
		}
		built[f.id] = (m.assemble(f.id, f.kids, built)!).with_tree_origin(m.arena.node(f.id).origin)
	}
	return built[id] or { blip.nil_value() }
}

fn (mut m Machine) assemble(id blip.NodeId, kids []blip.NodeId, built map[blip.NodeId]blip.Value) !blip.Value {
	d := m.arena.node(id)
	match d.tag {
		.nil { return blip.nil_value() }
		.bool { return blip.boolean(d.i != 0) }
		.int { return blip.integer(d.i) }
		.float { return blip.float(d.f) }
		.char { return blip.rune(u32(d.i)) }
		.str { return blip.string(d.value) }
		.sym { return blip.symbol(d.value) }
		.kw { return blip.keyword(d.value) }
		.quoted { return m.datum_to_value(m.arena.kids_view(id)[0])! }
		.unquote, .unquote_splice {
			// Nested inside a quasiquote. Evaluated here rather than treated as
			// data, which is the whole difference between `,x` and 'x.
			//
			// `assemble` has no other way to know, and it does not need to: a `.unquote`
			// node only ever appears inside a quasiquote in practice. It DOES appear
			// inside `'` too, and then `',x` evaluates -- which is surprising and is
			// why the examples never write it.
			return m.quasi_to_value(id)
		}
		.list {
			mut items := []blip.Value{}
			mut ki := 0
			for ki < kids.len {
				child := kids[ki]
				cd := m.arena.node(child)
				if cd.tag == .unquote_splice {
					// `,@xs` inside a list splices xs in. This is the one place a
					// node contributes more than one element, which is why the loop is
					// over the children and not over `built`.
					spliced := m.quasi_to_value(child)!
					parts := prims.seq(spliced) or {
						return blip.nil_value()
					}
					mut si := 0
					for si < parts.len {
						items << parts[si]
						si++
					}
				} else {
					items << built[child]
				}
				ki++
			}
			return blip.list_from(items)
		}
		.vector {
			mut items := []blip.Value{}
			mut ki := 0
			for ki < kids.len {
				items << built[kids[ki]]
				ki++
			}
			return blip.vector(items)
		}
		.table {
			mut mm := map[string]blip.Value{}
			mut i := 0
			for i + 1 < kids.len {
				k := built[kids[i]].as_string() or {
					return error('quoted table keys must be strings, got ${printer.write(built[kids[i]])}')
				}
				mm[k] = built[kids[i + 1]] or { blip.nil_value() }
				i += 2
			}
			return blip.table(mm)
		}
		.array {
			mut items := []blip.Value{}
			mut ki := 0
			for ki < kids.len {
				items << built[kids[ki]]
				ki++
			}
			return blip.Value{
				tag:     .array
				payload: &blip.Vector{
					tag:  .array
					data: items
				}
			}
		}
		.buffer {
			mut mm := map[string]blip.Value{}
			mut i := 0
			for i + 1 < kids.len {
				k := built[kids[i]].as_string() or {
					return error('quoted table keys must be strings, got ${printer.write(built[kids[i]])}')
				}
				mm[k] = built[kids[i + 1]] or { blip.nil_value() }
				i += 2
			}
			return blip.buffer(mm)
		}
		else { return blip.nil_value() }
	}
}

// quasi_to_value builds a form ready to be handed to a macro: an unquote is
// evaluated now, everything else becomes a literal.
//
// The save/restore is not optional. This runs in the MIDDLE of an evaluation --
// step_eval dispatches here for a quasiquoted form -- and eval_one resets the
// control state. Without the restore, evaluating an unquote would throw away the
// continuation frames of the form that contained it, and the macro expansion would
// return into the wrong place.
pub fn (mut m Machine) quasi_to_value(id blip.NodeId) !blip.Value {
	d := m.arena.node(id)
	if d.tag == .unquote || d.tag == .unquote_splice {
		inner := m.arena.kids_view(id)[0]
		// Evaluate `inner` in the CURRENT environment, not a reset one:
		// `eval_one` resets `m.env` to globals, which makes every unquoted
		// name in a macro body unbound (and therefore nil). Saving and
		// restoring `env` around it did not help, because the reset happened
		// inside. Drive the form directly so the macro's bound parameters
		// stay visible.
		saved_k := m.kstack
		saved_ctl := m.ctl
		saved_form := m.form
		saved_env := m.env
		m.kstack = []blip.Kont{}
		m.ctl = .eval_form
		m.form = inner
		out := m.drive() or { blip.nil_value() }
		m.kstack = saved_k
		m.ctl = saved_ctl
		m.form = saved_form
		m.env = saved_env
		return out
	}
	return m.datum_to_value(id)!
}

// value_to_datum is the reverse of datum_to_value: a runtime Value back into
// an AST node, for the emit-time macro path (macro_embed expands through a
// real machine, then converts back to source).
//
// Status: pure shapes + table/buffer/struct implemented; closure/primitive
// remain refused (they are not data literals). The returned node carries the
// value's origin, so expansion does not launder source spans.
pub fn (mut m Machine) value_to_datum(v blip.Value) !blip.NodeId {
	id := m.value_to_datum_inner(v)!
	m.arena.nodes[int(id)].origin = v.origin
	m.arena.nodes[int(id)].line = v.origin.line
	m.arena.nodes[int(id)].col = v.origin.col
	return id
}

fn (mut m Machine) value_to_datum_inner(v blip.Value) !blip.NodeId {
	match v.tag {
		.nil {
			return m.arena.leaf(.nil)
		}
		.boolean {
			return m.arena.int_leaf(.bool, if v.i == 1 { 1 } else { 0 })
		}
		.integer {
			return m.arena.int_leaf(.int, v.i)
		}
		.float {
			return m.arena.float_leaf(v.f)
		}
		.string {
			s := v.as_string() or { return error(err.msg()) }
			return m.arena.str_leaf(.str, s)
		}
		.symbol {
			s := v.as_string() or { return error(err.msg()) }
			return m.arena.str_leaf(.sym, s)
		}
		.keyword {
			s := v.as_string() or { return error(err.msg()) }
			return m.arena.str_leaf(.kw, s)
		}
		.pair {
			pair_v := v.as_pair() or { return error(err.msg()) }
			car_id := m.value_to_datum(pair_v.car)!
			cdr_id := m.value_to_datum(pair_v.cdr)!
			return m.node_of('', [car_id, cdr_id])
		}
		.vector {
			vec := v.as_vector() or { return error(err.msg()) }
			mut kids := []blip.NodeId{}
			for elem in vec.data {
				kids << m.value_to_datum(elem)!
			}
			return m.node_of('', kids)
		}
		.emptylist {
			id := m.arena.open(.list)
			m.arena.finish(id, []blip.NodeId{})
			return id
		}
		.table, .buffer {
			tbl := v.as_table() or { return error(err.msg()) }
			id_tag := if v.tag == .buffer { reader.DatumTag.buffer } else { reader.DatumTag.table }
			mut items := []blip.NodeId{}
			mut keys := []string{}
			for k, _ in tbl.values {
				keys << k
			}
			keys.sort()
			for k in keys {
				key_id := m.arena.str_leaf(.kw, k)
				val_id := m.value_to_datum(tbl.values[k])!
				items << key_id
				items << val_id
			}
			id := m.arena.open(id_tag)
			m.arena.finish(id, items)
			return id
		}
		.struct_ {
			sv := v.as_struct() or { return error(err.msg()) }
			mut items := []blip.NodeId{}
			items << m.sym_node(sv.name)
			for f in sv.fields {
				items << m.value_to_datum(sv.get(f))!
			}
			id := m.arena.open(.list)
			m.arena.finish(id, items)
			return id
		}
		else {
			return error('value_to_datum: complex shape ${v.tag} not yet implemented')
		}
	}
}

// ----------------------------------------------------------------- match

// eval_match pushes one `.match_k` frame and evaluates the subject.
//
// ONE frame for the whole `match`, not one per clause: a per-clause frame would
// mean a `match` in tail position grew the continuation stack by its clause count
// on every iteration, which is the same mistake `begin` used to make.
