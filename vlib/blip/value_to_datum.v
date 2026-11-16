// value_to_datum — reverse of datum_to_value (machine/mod.v 2596).
// Status: pure shapes + table/buffer/struct implemented; closure/primitive
// remain refused (they are not data literals).

module blip

import vlib.blip.machine
import vlib.blip.reader

pub fn value_to_datum(mut m machine.Machine, v Value) !NodeId {
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
			s := v.as_string()
			return m.arena.str_leaf(.str, s)
		}
		.symbol {
			s := v.as_string()
			return m.arena.str_leaf(.sym, s)
		}
		.keyword {
			s := v.as_string()
			return m.arena.str_leaf(.kw, s)
		}
		.pair {
			car_id := value_to_datum(mut m, v.as_pair().car)!
			cdr_id := value_to_datum(mut m, v.as_pair().cdr)!
			return m.node_of('', [car_id, cdr_id])
		}
		.vector {
			vec := v.as_vector()
			mut kids := []NodeId{}
			for elem in vec.data {
				kids << value_to_datum(mut m, elem)!
			}
			return m.node_of('', kids)
		}
		.emptylist {
			id := m.arena.open(.list)
			m.arena.finish(id, []NodeId{})
			return id
		}
		.table, .buffer {
			tbl := v.as_table()
			id_tag := if v.tag == .buffer { reader.DatumTag.buffer } else { reader.DatumTag.table }
			mut items := []NodeId{}
			mut keys := []string{}
			for k, _ in tbl.values {
				keys << k
			}
			keys.sort()
			for k in keys {
				key_id := m.arena.str_leaf(.kw, k)
				val_id := value_to_datum(mut m, tbl.values[k])!
				items << key_id
				items << val_id
			}
			id := m.arena.open(id_tag)
			m.arena.finish(id, items)
			return id
		}
		.struct_ {
			sv := v.as_struct()
			mut items := []NodeId{}
			items << m.sym_node(sv.name)
			for f in sv.fields {
				items << value_to_datum(mut m, sv.values[f])!
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