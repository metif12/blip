module blip

// Value is the runtime representation of every blip datum, plus the environment
// and closure machinery the machine needs.
//
// Three V facts shaped this, all found by measurement rather than by reading the
// documentation (src/gc_probe.v, src/bench_value.v, tools/sumtype_local.v):
//
//  1. A boxed sum type cannot represent a pair. `struct cons_v { tail Lst }` is
//     rejected as `invalid recursive struct`, and a sum-type variant field
//     cannot be initialised from a local at all. The representation V would
//     hand us for free does not exist.
//
//  2. A `voidptr` field is not a GC root. An object reachable only through one
//     is collected: a 2,000,000-cell cons chain walked 25 cells. So the payload
//     must be a TYPED reference.
//
//  3. `&T` fields trigger V's reference and aliasing rules hard enough that
//     walking a linked list of them is not writable: `cur = cur.parent` is
//     rejected as "cannot be assigned outside unsafe". So environments are
//     referenced by i32 index into an arena, which sidesteps the question and
//     matches how the datum arena already works.
import strconv

@[flag]
pub enum Tag {
	nil // the empty value: absence of a result
	boolean
	integer
	float
	rune // code point, in `i`
	string
	symbol  // interned string
	keyword // interned string, self-evaluating, callable
	pair
	emptylist // the empty list: a sequence of length zero
	vector
	array  // mutable vector
	table  // immutable map
	buffer // mutable map
	closure
	primitive
	continuation
	struct_ // a struct instance; the constructor name is in the payload
}

// NodeId indexes the reader's flat arena. It lives here rather than in the
// reader so closures can name a body form without the core importing the
// reader, which would be circular: the reader needs Value.
pub type NodeId = i32

pub const no_node = NodeId(-1)

// Anything a Value can point at.
//
// The method is REQUIRED. A method-less marker interface holding a struct
// compiles and then dies with `invalid memory access` in both dev and -prod
// builds on V 0.5.2.
pub interface Payload {
	payload_tag() Tag
}

// Scalars share this zero-sized sentinel. V requires an interface field to be
// initialised, and none of the scalars allocate -- which is the entire reason
// Value is not a sum type.
pub struct NoPayload {}

pub fn (n &NoPayload) payload_tag() Tag {
	return .nil
}

pub const no_payload = Payload(&NoPayload{})

pub struct StringPayload {
pub:
	tag Tag
	s   string
}

pub fn (p &StringPayload) payload_tag() Tag {
	return p.tag
}

// Pair, Vector and Table are @[heap]: their mutators run through a `&T`
// receiver, and the compiler only permits the `mut` copy that makes the
// write legal when the struct is heap-allocated (see below).
@[heap]
pub struct Pair {
pub:
	tag Tag
pub mut:
	car Value
	cdr Value
}

pub fn (p &Pair) payload_tag() Tag {
	return p.tag
}

@[heap]
pub struct Vector {
pub:
	tag Tag
pub mut:
	data []Value
}

pub fn (v &Vector) payload_tag() Tag {
	return v.tag
}

// Table is an immutable string-keyed map. A buffer uses the same payload with a
// different tag, so `get`/`put` serve both and mutability is visible in the tag.
@[heap]
pub struct Table {
pub:
	tag Tag
pub mut:
	values map[string]Value
}

// StructVal is a struct instance. Fields are kept in DECLARATION order, not
// sorted: `(Point 1 2)` has to print the way it was written, and a sorted map
// prints `(Point 2 1)`. Table's `keys()` sorts because a table's order is not
// anyone's business; a struct's field order is the declaration.
pub struct StructVal {
pub:
	name   string
	fields []string
mut:
	// mutable because a `#:mutable` struct's generated mutator writes through
	// here in place; the immutable case still goes through `with`, which
	// builds a new map and never touches this field.
	values map[string]Value
}

pub fn (s &StructVal) payload_tag() Tag {
	return .struct_
}

pub fn (s &StructVal) get(k string) Value {
	if k in s.values {
		return s.values[k]
	}
	return nil_value()
}

pub fn (s &StructVal) has(k string) bool {
	return k in s.values
}

// at returns a field by its index in the declaration.
pub fn (s &StructVal) at(i int) Value {
	return s.values[s.fields[i]]
}

// update returns a copy with one field replaced. Structs are immutable, so
// `p.y := 99` builds a new value and leaves the original alone -- which is the
// whole reason the syntax exists instead of `set!`.
pub fn (s &StructVal) with(k string, v Value) &StructVal {
	mut mm := map[string]Value{}
	for f in s.fields {
		if f == k {
			mm[f] = v
		} else {
			mm[f] = s.values[f]
		}
	}
	return &StructVal{
		name:   s.name
		fields: s.fields
		values: mm
	}
}

// set writes a field IN PLACE and is what a `#:mutable` struct's generated
// mutator uses.
//
// `with` is the functional one: it builds a fresh map and hands back a new
// struct, which is right for the immutable case and useless for the mutable
// one -- the caller of `(set-counter-n! c 5)` ignores whatever the function
// returns, so the write has to land in the map the caller is still holding.
// A V map is a reference, so writing through this receiver reaches the same
// StructVal the variable points at.
pub fn (mut s StructVal) set(k string, v Value) {
	s.values[k] = v
}

pub fn (t &Table) payload_tag() Tag {
	return t.tag
}

// keys is sorted, not insertion-ordered. A table whose iteration order varied
// between runs would make every error message and every test output unstable.
pub fn (t &Table) keys() []string {
	mut out := []string{}
	out << t.values.keys()
	out.sort()
	return out
}

// get returns nil for an absent key. Absent is nil, not an error, which is what
// makes `(get tbl k)` total.
pub fn (t &Table) get(k string) Value {
	if k in t.values {
		return t.values[k]
	}
	return nil_value()
}

pub fn (t &Table) has(k string) bool {
	return k in t.values
}

// Mutators take `&Vector`/`&Table`. A `&T` receiver is immutable in V, so the
// write goes through a `mut` copy of the reference inside `unsafe` (allowed
// because the payloads are heap structs). They live here rather than in
// prims because the struct is declared here, and prims cannot reach
// through an immutable reference to a field of another module's struct.
pub fn (v &Vector) set_at(i int, val Value) {
	unsafe {
		mut w := v
		w.data[i] = val
	}
}

pub fn (v &Vector) push(val Value) {
	unsafe {
		mut w := v
		// `.clone()` and not a straight assignment: V treats `mut d := v.data` on an
		// immutable receiver as aliasing, and rejects it. Cloning is CORRECT here
		// rather than a copy that breaks sharing, because every accessor reads
		// `v.data` again -- nothing else holds the old slice descriptor.
		mut d := w.data.clone()
		d << val
		w.data = d
	}
}

pub fn (v &Vector) pop() Value {
	unsafe {
		mut w := v
		mut d := w.data.clone()
		last := d[d.len - 1]
		d = d[..d.len - 1]
		w.data = d
		return last
	}
}

pub fn (t &Table) set_at(k string, val Value) {
	unsafe {
		mut tt := t
		mut m := tt.values
		m[k] = val
		tt.values = m
	}
}

pub fn (t &Table) delete_at(k string) {
	unsafe {
		mut tt := t
		mut m := tt.values
		m.delete(k)
		tt.values = m
	}
}

// Not `@[packed]`: packing forces byte alignment, which misaligns the pointer
// inside the interface field and crashes. Natural alignment costs nothing here.
@[direct_array_access]
pub struct Value {
pub mut:
	tag     Tag
	i       i64
	f       f64
	payload Payload
	// Origin travels with the value, independently of its payload and equality.
	origin SourceLocation
}

// SourceLocation identifies the expression that produced a value. Lines and
// columns are 1-based; offsets are a half-open range of UTF-8 bytes. A zero
// line means unknown (for example a value supplied by a host).
pub struct SourceLocation {
pub:
	file  string
	line  int
	col   int
	start int
	end   int
}

pub fn (v Value) source_location() ?SourceLocation {
	if v.origin.line == 0 {
		return none
	}
	return v.origin
}

// with_origin preserves an existing origin: looking up a setting keeps its
// defining expression rather than replacing it with the lookup location.
pub fn (v Value) with_origin(origin SourceLocation) Value {
	if v.origin.line > 0 || origin.line == 0 {
		return v
	}
	return Value{
		...v
		origin: origin
	}
}

// ---- constructors ----------------------------------------------------------

pub fn nil_value() Value {
	return Value{
		tag:     .nil
		payload: no_payload
	}
}

// empty_list is the empty list, which is NOT the nil value.
//
// The examples assert both `(get {:a 1} :missing) ;=> nil` and `(list) ;=> ()`,
// so one value cannot print both ways. They are therefore two values, and
// `null?` / `nil?` are true of both -- which is also what Clojure does, and it
// is the only reading under which `nil` means "no result" while `(cdr '(1))`
// still reads back as `()`.
//
// The alternative, printing nil as `()`, makes every absent lookup and every
// missing argument indistinguishable from an empty sequence at a glance.
pub fn empty_list() Value {
	return Value{
		tag:     .emptylist
		payload: no_payload
	}
}

pub fn boolean(b bool) Value {
	return Value{
		tag:     .boolean
		i:       if b { 1 } else { 0 }
		payload: no_payload
	}
}

pub fn integer(n i64) Value {
	return Value{
		tag:     .integer
		i:       n
		payload: no_payload
	}
}

pub fn float(f f64) Value {
	return Value{
		tag:     .float
		f:       f
		payload: no_payload
	}
}

pub fn rune(r u32) Value {
	return Value{
		tag:     .rune
		i:       i64(r)
		payload: no_payload
	}
}

pub fn string(s string) Value {
	return Value{
		tag:     .string
		payload: &StringPayload{
			tag: .string
			s:   s
		}
	}
}

pub fn symbol(name string) Value {
	return Value{
		tag:     .symbol
		payload: &StringPayload{
			tag: .symbol
			s:   name
		}
	}
}

pub fn keyword(name string) Value {
	return Value{
		tag:     .keyword
		payload: &StringPayload{
			tag: .keyword
			s:   name
		}
	}
}

pub fn cons(car Value, cdr Value) Value {
	return Value{
		tag:     .pair
		payload: &Pair{
			tag: .pair
			car: car
			cdr: cdr
		}
	}
}

// list_from builds a cons chain right to left. An empty input gives the empty
// list, not nil: `list_from` is how a cons chain's base case is built, so the
// base case has to be a sequence.
pub fn list_from(items []Value) Value {
	if items.len == 0 {
		return empty_list()
	}
	mut out := empty_list()
	mut i := items.len - 1
	for i >= 0 {
		out = cons(items[i], out)
		i--
	}
	return out
}

pub fn vector(items []Value) Value {
	return Value{
		tag:     .vector
		payload: &Vector{
			tag:  .vector
			data: items
		}
	}
}

pub fn table(m map[string]Value) Value {
	return Value{
		tag:     .table
		payload: &Table{
			tag:    .table
			values: m
		}
	}
}

pub fn buffer(m map[string]Value) Value {
	return Value{
		tag:     .buffer
		payload: &Table{
			tag:    .buffer
			values: m
		}
	}
}

// ---- erased annotations (M10) ------------------------------------------------
//
// `(define (add (x int) (y int)) int ...)` annotates without checking at run
// time: the machine erases every annotation, and `blip check` is the
// separate command that reports mismatches. The vocabulary lives here so the
// machine (which erases), the emitter (which erases), and the checker (which
// verifies) cannot disagree on what names a type.
//
// `any` is the top type: an unannotated parameter, an unknown literal, or a
// call the checker has no signature for. It unifies with everything, which is
// what keeps the checker quiet rather than wrong.
pub const type_names = ['int', 'float', 'string', 'bool', 'any']

pub fn is_type_name(s string) bool {
	return s in type_names
}

// type_compatible reports whether a value known to have type `have` may flow
// into a position declared `want`. Unknown on either side is agreement, not
// conflict: the checker only speaks when both sides are known and differ.
pub fn type_compatible(have string, want string) bool {
	if have == 'any' || want == 'any' {
		return true
	}
	return have == want
}

// ---- accessors -------------------------------------------------------------
//
// Every accessor type-checks, and reports the mismatch as a returned error
// naming the accessor and the tag it met ("as_table: called on a integer,
// not a table"). The error composes with `or`: prims and machine paths
// propagate it, and the user sees an ordinary blip error -- never a dead
// process. That is the whole contract with hostile input: a config file that
// says something wrong must be answerable as an error.
//
// An earlier revision did this with a RECOVERABLE panic caught in the drive
// loop's defer/recover net (V asserts are not catchable -- the process dies
// with the printout and no defer can intercept). The 0.5.2 release has no
// recover, so the check lives in the return type instead: every call site
// ends in `or`, and the net is gone. Sites the tag-match above already
// proves safe still spell the `or` out, with a panic naming the invariant;
// if one ever fires it is a logic bug, and loud is correct.
//
// The payload itself is recovered with a smart cast, not `as`: stock 0.5.2
// miscompiles `iface as &T` for an interface holding a `&T` (the cast
// panics with "cannot cast `unknown`", while dispatch on the same value
// works), and only `as T` -- a copy -- succeeds. The smart cast keeps the
// live pointer, so in-place writers (push, set_at, with_tree_origin) still
// reach the shared struct.

fn tag_name(t Tag) string {
	return '${t}'.replace('Tag.', '')
}

@[inline]
pub fn (v Value) as_int() !i64 {
	if v.tag != .integer && v.tag != .rune {
		return error('as_int: called on a ${tag_name(v.tag)}, not an integer')
	}
	return v.i
}

@[inline]
pub fn (v Value) as_float() !f64 {
	if v.tag != .float {
		return error('as_float: called on a ${tag_name(v.tag)}, not a float')
	}
	return v.f
}

@[inline]
pub fn (v Value) as_bool() !bool {
	if v.tag != .boolean {
		return error('as_bool: called on a ${tag_name(v.tag)}, not a boolean')
	}
	return v.i != 0
}

// string_payload recovers the string payload without `as`: narrowing to a
// `&T` and touching the result in the same branch miscompiles on stock
// 0.5.2 (an extra indirection in the generated C), while returning the
// narrowed value through a helper keeps the live pointer intact.
fn string_payload(p Payload) !&StringPayload {
	if p is &StringPayload {
		return p
	}
	return error('payload is not a string')
}

@[inline]
pub fn (v Value) as_string() !string {
	if v.tag !in [.string, .symbol, .keyword, .primitive] {
		return error('as_string: called on a ${tag_name(v.tag)}, not a string')
	}
	sp := string_payload(v.payload) or { return error('as_string: payload is not a string') }
	return sp.s
}

@[inline]
pub fn (v Value) as_pair() !&Pair {
	if v.tag != .pair {
		return error('as_pair: called on a ${tag_name(v.tag)}, not a pair')
	}
	if v.payload is &Pair {
		return v.payload
	}
	return error('as_pair: payload is not a pair')
}

@[inline]
pub fn (v Value) as_vector() !&Vector {
	if v.tag != .vector && v.tag != .array {
		return error('as_vector: called on a ${tag_name(v.tag)}, not a vector')
	}
	if v.payload is &Vector {
		return v.payload
	}
	return error('as_vector: payload is not a vector')
}

@[inline]
pub fn (v Value) as_table() !&Table {
	if v.tag != .table && v.tag != .buffer {
		return error('as_table: called on a ${tag_name(v.tag)}, not a table')
	}
	if v.payload is &Table {
		return v.payload
	}
	return error('as_table: payload is not a table')
}

pub fn struct_value(name string, fields []string, vals map[string]Value) Value {
	return Value{
		tag:     .struct_
		payload: &StructVal{
			name:   name
			fields: fields
			values: vals
		}
	}
}

@[inline]
pub fn (v Value) as_struct() !&StructVal {
	if v.tag != .struct_ {
		return error('as_struct: called on a ${tag_name(v.tag)}, not a struct')
	}
	if v.payload is &StructVal {
		return v.payload
	}
	return error('as_struct: payload is not a struct')
}

// Only `#f` is false -- as in R5RS and Clojure. `0`, `""`, `nil`, `()` and
// `(quote ())` are all true. Ruby and JavaScript say the opposite, which is why
// everyone arriving from them has to relearn this.
@[inline]
pub fn (v Value) truthy() bool {
	return !(v.tag == .boolean && v.i == 0)
}

@[inline]
pub fn (v Value) is_nil() bool {
	return v.tag == .nil
}

// is_empty_seq is what `null?` asks: true for the empty list AND for nil, because
// both mean "no elements here", and the examples assert `(null? '())` is true.
@[inline]
pub fn (v Value) is_empty_seq() bool {
	return v.tag == .nil || v.tag == .emptylist
}

// ---- environments ----------------------------------------------------------

// Env is one lexical scope. Environments live in an arena and are referenced by
// index, for the reason given at the top of this file.
pub type EnvId = i32

pub const no_env = EnvId(-1)

pub struct Env {
pub mut:
	parent EnvId
	names  []string
	vals   []Value
	// index maps a binding name to its position in names/vals, so lookup and
	// set are O(1) in the frame size instead of a linear scan. Kept in sync
	// with names/vals by define and set; never mutated by readers.
	index map[string]int
	// linear marks call frames: 1-3 params where a map allocation + N hashed
	// inserts per call costs more than a linear scan per lookup. Lookup,
	// define and set branch on this and never touch index for such frames,
	// so behavior is identical with no map involved at all.
	linear bool
}

pub struct EnvArena {
pub mut:
	frames []Env
	// version bumps on every define/set, so a single-entry lookup cache can
	// validate with one integer compare instead of re-walking the chain.
	// It wraps on overflow; a wrap only causes a spurious miss, never a
	// wrong hit, because the cached generation must match exactly.
	version u64
}

pub fn (mut ea EnvArena) new_env(parent EnvId) EnvId {
	ea.frames << Env{
		parent: parent
		names:  []string{}
		vals:   []Value{}
		index:  map[string]int{}
	}
	return EnvId(ea.frames.len - 1)
}

// new_frame builds a call frame in one shot: names/vals cloned pre-sized, no
// map allocated, version bumped once. Call frames are marked linear (see Env):
// 1-3 params where hashing costs more than scanning. Behavior is identical to
// new_env + N defines: same names, same values, and the version is only ever
// compared for equality by the lookup cache, so one bump invalidates exactly
// like N bumps. The slices are cloned so the frame never aliases the
// closure's params or the caller's args.
pub fn (mut ea EnvArena) new_frame(parent EnvId, names []string, vals []Value) EnvId {
	ea.version++
	ea.frames << Env{
		parent: parent
		names:  names.clone()
		vals:   vals.clone()
		index:  map[string]int{}
		linear: true
	}
	return EnvId(ea.frames.len - 1)
}

pub fn (ea &EnvArena) get(id EnvId) &Env {
	if id == no_env {
		return unsafe { nil }
	}
	return &ea.frames[int(id)]
}

pub fn (mut ea EnvArena) define(id EnvId, name string, val Value) {
	mut frame := ea.get(id)
	ea.version++
	if frame.linear {
		// Call frames stay map-free: scan, update in place or append.
		for i := 0; i < frame.names.len; i++ {
			if frame.names[i] == name {
				frame.vals[i] = val
				return
			}
		}
		frame.names << name
		frame.vals << val
		return
	}
	if name in frame.index {
		idx := frame.index[name]
		frame.vals[idx] = val
		return
	}
	frame.names << name
	frame.vals << val
	frame.index[name] = frame.names.len - 1
}

pub fn (mut ea EnvArena) lookup(id EnvId, name string) ?Value {
	mut cur := id
	for cur != no_env {
		frame := ea.get(cur)
		if frame.linear {
			for i := frame.names.len - 1; i >= 0; i-- {
				if frame.names[i] == name {
					return frame.vals[i]
				}
			}
		} else if name in frame.index {
			idx := frame.index[name]
			return frame.vals[idx]
		}
		cur = frame.parent
	}
	return none
}

// set assigns to the frame that owns the binding, so a `set!` inside a closure
// is visible on that closure's next call.
pub fn (mut ea EnvArena) set(id EnvId, name string, val Value) bool {
	mut cur := id
	for cur != no_env {
		mut frame := ea.get(cur)
		if frame.linear {
			for i := 0; i < frame.names.len; i++ {
				if frame.names[i] == name {
					frame.vals[i] = val
					ea.version++
					return true
				}
			}
		} else if name in frame.index {
			idx := frame.index[name]
			frame.vals[idx] = val
			ea.version++
			return true
		}
		cur = frame.parent
	}
	return false
}

// ---- callables -------------------------------------------------------------

// Closure carries `rest` as a flag rather than a magic parameter name.
//
// The obvious version binds the rest to a parameter literally called `rest` and
// checks `params.last == 'rest'`. That makes `(define (f rest) ...)` -- a
// perfectly ordinary function of one argument -- silently variadic, and it makes
// the flag invisible in the parameter list, so a caller reading the signature
// cannot tell arity from arity-at-least.
//
// A flag costs one bool and keeps both cases unambiguous: `(define (f a . r) r)`
// is 1-or-more, `(define (f rest) rest)` is exactly 1.
pub struct Closure {
pub:
	params []string
	body   NodeId
	env    EnvId
	name   string
	arity  int
	rest   bool
	// rest_name is the name after the dot. It is kept out of `params` so that
	// binding it cannot collide with an ordinary parameter, and out of `arity` so
	// that arity counts only the FIXED parameters.
	rest_name string
	// Labelled parameters. `opt_from` is the index of the first one, or -1.
	// The keyword names and defaults are parallel arrays from there on, and a
	// default of `no_default` means the label is required.
	//
	// They are arena NodeIds rather than values because a default is evaluated at
	// the CALL, in the caller's scope -- `(connect #:port (+ port 1))` has to see
	// the caller's `port`. Baking the value into the closure at definition time
	// would evaluate it once, in the definition's scope, and be wrong.
	opt_from     int = -1
	opt_names    []string
	opt_defaults []NodeId
}

pub const no_default = NodeId(-2)

pub fn (c &Closure) payload_tag() Tag {
	return .closure
}

pub fn new_closure(params []string, body NodeId, env EnvId, name string) Value {
	return Value{
		tag:     .closure
		payload: &Closure{
			params: params
			body:   body
			env:    env
			name:   name
			arity:  params.len
		}
	}
}

// new_rest_closure is the variadic constructor. `params` EXCLUDES the rest
// name; the rest name is kept separately so binding it cannot collide with an
// ordinary parameter.
pub fn new_rest_closure(params []string, rest_name string, body NodeId, env EnvId, name string) Value {
	return Value{
		tag:     .closure
		payload: &Closure{
			params:    params
			body:      body
			env:       env
			name:      name
			arity:     params.len
			rest:      true
			rest_name: rest_name
		}
	}
}

// labelled builds the closure for a parameter list that has labelled parameters.
pub fn labelled(params []string, body NodeId, env EnvId, name string, opt_from int, opt_names []string, opt_defaults []NodeId) Value {
	return Value{
		tag:     .closure
		payload: &Closure{
			params:       params
			body:         body
			env:          env
			name:         name
			arity:        params.len
			opt_from:     opt_from
			opt_names:    opt_names
			opt_defaults: opt_defaults
		}
	}
}

@[inline]
pub fn (v Value) as_closure() !&Closure {
	if v.tag != .closure {
		return error('as_closure: called on a ${tag_name(v.tag)}, not a closure')
	}
	if v.payload is &Closure {
		return v.payload
	}
	return error('as_closure: payload is not a closure')
}

// PrimFn takes only its arguments, deliberately: if it took the machine, this
// module and the machine would be mutually dependent. The few builtins that need
// the interpreter are handled by the machine itself.
pub type PrimFn = fn (args []Value) !Value

// A primitive Value carries only its name; the implementation lives in the
// machine's table keyed by that name.
pub fn new_prim(name string) Value {
	return Value{
		tag:     .primitive
		payload: &StringPayload{
			tag: .primitive
			s:   name
		}
	}
}

// Kont is ONE tagged struct rather than a sum type. That is a workaround for a V
// 0.5.2 limitation: a sum-type variant cannot have a field initialised from a
// local (`if_k{outcome: x}` fails with "x evaluated but not used"), so
// continuations could not be a sum type at all.
@[flag]
pub enum KontTag {
	done
	app_fn  // operator evaluated; arguments remain
	app_arg // evaluating one argument
	if_k    // evaluating an if test
	seq     // begin: more expressions remain
	define_k
	set_k
	and_k
	or_k
	field_k   // p.y := value, building the new instance
	assert_k  // (assert test message)
	use_k     // binding the values of an ok Result
	match_k   // choosing a match clause
	guard_k   // evaluating a #:when guard
	collect_k // evaluating the elements of a vector, table or array literal
	try_k     // `try`: running one body form, or its #:finally
}

pub struct Kont {
pub mut:
	tag  KontTag
	expr NodeId // the form being evaluated when this frame was pushed
	env  EnvId
	slot int    // which child or argument index
	rest NodeId // the enclosing form
	acc  []Value
	name string
	// match_k and guard_k carry a clause list and an ordered binding list, which
	// is more state than the index/name fields hold. They live here rather than in
	// a second frame type because Kont is ONE struct on purpose: V 0.5.2 cannot
	// initialise a sum-type variant field from a local, so continuations cannot be
	// a sum type at all. See the note above the type.
	clauses []NodeId
	binds   []string
	vals    []Value
}

// ---- misc ------------------------------------------------------------------

// AtoF64Param is not exported by name in this V version, so it is built from its
// only public field. allow_extra_chars must be false: parsing "12abc" has to be
// rejected rather than silently yielding 12.
pub const strict_float = strconv.AtoF64Param{
	allow_extra_chars: false
}

pub fn format_error(path string, src string, line int, col int, msg string, length int) string {
	if line <= 0 {
		return 'error: ${msg}'
	}
	lines := src.split('\n')
	if line > lines.len {
		return 'error: ${msg}'
	}
	mut src_line := lines[line - 1]
	max_src := 200
	if src_line.len > max_src {
		src_line = src_line[..max_src] + '...'
	}
	ln := line.str()
	gutter := ' '.repeat(ln.len)
	mut out := 'error: ${msg}\n'
	out += '  --> ${path}:${line}:${col}\n'
	out += '${gutter} |\n'
	out += '${ln} | ${src_line}\n'
	out += '${gutter} | '
	underline_col := col - 1
	if underline_col > 0 {
		out += ' '.repeat(underline_col)
	}
	out += '^'.repeat(length)
	out += '\n'
	return out
}
