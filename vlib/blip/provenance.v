module blip

// with_tree_origin fills origins on newly constructed data, including values
// made inside primitives (string-split, range, result wrappers). Existing
// origins stop the walk, so returning an argument does not scan its contents.
// The worklist and visited set handle long lists and mutable cyclic containers.
pub fn (v Value) with_tree_origin(origin SourceLocation) Value {
	if v.origin.line > 0 || origin.line == 0 {
		return v
	}
	if v.tag !in [.pair, .vector, .array, .table, .buffer, .struct_] {
		return v.with_origin(origin)
	}
	mut work := [v]
	mut seen := map[voidptr]bool{}
	for work.len > 0 {
		mut x := work.pop()
		match x.tag {
			.pair {
				p := x.as_pair() or { panic('unreachable: pair arm') }
				if voidptr(p) in seen { continue }
				seen[voidptr(p)] = true
				for child in [p.car, p.cdr] {
					if child.origin.line == 0 { work << child }
				}
				unsafe {
					mut pp := p
					pp.car = pp.car.with_origin(origin)
					pp.cdr = pp.cdr.with_origin(origin)
				}
			}
			.vector, .array {
				p := x.as_vector() or { panic('unreachable: vector/array arm') }
				if voidptr(p) in seen { continue }
				seen[voidptr(p)] = true
				for i, child in p.data {
					if child.origin.line == 0 {
						work << child
						p.set_at(i, child.with_origin(origin))
					}
				}
			}
			.table, .buffer {
				p := x.as_table() or { panic('unreachable: table/buffer arm') }
				if voidptr(p) in seen { continue }
				seen[voidptr(p)] = true
				for key, child in p.values {
					if child.origin.line == 0 {
						work << child
						p.set_at(key, child.with_origin(origin))
					}
				}
			}
			.struct_ {
				mut p := x.as_struct() or { panic('unreachable: struct arm') }
				if voidptr(p) in seen { continue }
				seen[voidptr(p)] = true
				for key, child in p.values {
					if child.origin.line == 0 {
						work << child
						p.set(key, child.with_origin(origin))
					}
				}
			}
			else {}
		}
	}
	return v.with_origin(origin)
}
