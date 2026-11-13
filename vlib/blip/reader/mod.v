module reader

import strconv
import blip

// strict_float rejects trailing junk. AtoF64Param is not exported by name in
// this V version, so the struct is built by its only public field.
const strict_float = strconv.AtoF64Param{
	allow_extra_chars: false
}

// Reader: source text to a flat node arena.
//
// The arena mirrors vlib/v/flat/flat.v -- one array of nodes, each carrying its
// own scalar payload inline, with children living in a single shared slice
// addressed by (start, count). Leaves have count == 0. Building a large program
// therefore performs no per-node allocation, and the machine can dispatch on a
// u8 tag.
//
// Errors are COLLECTED, not thrown: a file with three mistakes reports three
// mistakes. This follows vlib/v/scanner/scanner.v:15-24.

pub const no_node = NodeId(-1)

pub type NodeId = i32

// Delimiters as named constants. Writing them as `)` and `}` char literals
// inside match arms makes the brace structure of this file genuinely ambiguous
// to read -- and to parse.
pub const lparen = u8(40)
pub const rparen = u8(41)
pub const lbrack = u8(91)
pub const rbrack = u8(93)
pub const lbrace = u8(123)
pub const rbrace = u8(125)
pub const quote_c = u8(39)
pub const semi = u8(59)
pub const quasi_c = u8(96)
pub const unquote_c = u8(44)
pub const bar = u8(124)
pub const hash_c = u8(35)
pub const backslash = u8(92)
pub const underscore = u8(95)
pub const at_c = u8(64)
pub const colon = u8(58)
pub const dot = u8(46)
pub const dot_c = u8(46)
pub const minus_c = u8(45)
pub const plus_c = u8(43)
pub const zero_c = u8(48)
pub const nine_c = u8(57)
pub const x_c = u8(120)
pub const b_c = u8(98)
pub const o_c = u8(111)
pub const dquote = u8(34)
pub const backslash_bs = u8(92)
pub const nl = u8(10)
pub const tab_c = u8(9)
pub const cr = u8(13)
pub const sp = u8(32)

pub enum DatumTag as u8 {
	nil
	bool
	int
	rat
	float
	char
	str
	sym
	kw
	list
	vector
	table
	array
	bytes
	buffer
	quoted
	quasi
	unquote
	unquote_splice
}

pub fn (t DatumTag) is_collection() bool {
	return t in [.list, .vector, .table, .array, .bytes, .buffer]
}

pub fn (t DatumTag) is_stringy() bool {
	return t in [.str, .sym, .kw]
}

pub struct Datum {
pub mut:
	tag    DatumTag
	value  string // str / sym / kw payload
	i      i64    // int, char code point, bool
	f      f64    // float
	den    i64    // rational denominator
	start  i32    // children range into Arena.children
	count  i32
	line   int
	col    int
	origin blip.SourceLocation
}

pub struct Arena {
pub mut:
	nodes    []Datum
	children []NodeId
}

@[inline]
pub fn (mut a Arena) leaf(tag DatumTag) NodeId {
	a.nodes << Datum{
		tag: tag
	}
	return NodeId(a.nodes.len - 1)
}

@[inline]
pub fn (mut a Arena) str_leaf(tag DatumTag, s string) NodeId {
	a.nodes << Datum{
		tag:   tag
		value: s
	}
	return NodeId(a.nodes.len - 1)
}

@[inline]
pub fn (mut a Arena) int_leaf(tag DatumTag, n i64) NodeId {
	a.nodes << Datum{
		tag: tag
		i:   n
	}
	return NodeId(a.nodes.len - 1)
}

@[inline]
pub fn (mut a Arena) float_leaf(f f64) NodeId {
	a.nodes << Datum{
		tag: .float
		f:   f
	}
	return NodeId(a.nodes.len - 1)
}

// open creates a collection node with no children yet. The children are
// attached later by finish().
//
// open must NOT record a child offset. A nested list finishes its own children
// before the enclosing list appends its next child, so an offset captured at open
// time points into the middle of the inner list's children. That bug made
// `(+ (+ 1 2) (+ 3 4))` read as a flat `(+ + 1)`.
@[inline]
pub fn (mut a Arena) open(tag DatumTag) NodeId {
	a.nodes << Datum{
		tag: tag
	}
	return NodeId(a.nodes.len - 1)
}

// finish appends a node's children as one contiguous run and records where it
// began. Appending the run at the END, rather than interleaving with whatever a
// nested node appended meanwhile, is what makes (start, count) a valid range.
pub fn (mut a Arena) finish(id NodeId, items []NodeId) {
	start := i32(a.children.len)
	for it in items {
		a.children << it
	}
	mut node := &a.nodes[int(id)]
	node.start = start
	node.count = i32(items.len)
}

// add_child appends a single child immediately.
//
// It is only correct when the parent is the LAST thing that has appended to
// `children` -- that is, when the parent was created after everything already
// read. It cannot be used for a node that was created before other children were
// appended, because it leaves `start` at 0 and so writes into whatever form
// happened to occupy children[0].
//
// It was used for `'` and `` ` ``, whose wrapper node is created immediately
// before its operand. Every `'(...)` in a file whose first form was a list put
// its operand at children[0], i.e. as the first child of the FIRST top-level
// form. `'after` after a `define` therefore evaluated the symbol `define` and
// printed it -- silently, because the value it produced was a perfectly valid
// symbol. `finish` has no such precondition; use it.
@[inline]
pub fn (mut a Arena) add_child(parent NodeId, child NodeId) {
	start := i32(a.children.len)
	a.children << child
	mut node := &a.nodes[int(parent)]
	node.count = 1
	node.start = start
}

@[inline]
pub fn (a &Arena) node(id NodeId) &Datum {
	return &a.nodes[int(id)]
}

@[inline]
pub fn (mut a Arena) set_pos(id NodeId, line int, col int) {
	mut node := &a.nodes[int(id)]
	node.line = line
	node.col = col
}

// set_pos_origin records both the line/col and the full origin in one arena
// access. read() stamped them separately -- two bounds-checked indexings
// per form -- which is pure overhead on small dense forms, where the stamp
// is a large share of the per-form cost.
@[inline]
pub fn (mut a Arena) set_pos_origin(id NodeId, line int, col int, origin blip.SourceLocation) {
	mut node := &a.nodes[int(id)]
	node.line = line
	node.col = col
	node.origin = origin
}

// kids returns a COPY of a node's children.
//
// The machine evaluates a form, transforms it into new arena nodes, and then
// reads its children again. If kids returned a view into the shared children
// slice, the append performed by the transform would reallocate that slice and
// leave the caller holding a dangling reference. Copying is cheap next to the
// failure mode it removes.
pub fn (a &Arena) kids(id NodeId) []NodeId {
	d := a.nodes[int(id)]
	mut out := []NodeId{}
	n := int(d.start)
	mut i := 0
	for i < int(d.count) {
		out << a.children[n + i]
		i++
	}
	return out
}

// kids_view returns a zero-copy view into the arena's children slice for `id`.
//
// It allocates nothing, but the view is invalidated if anything appends to the
// arena's children slice afterwards (which reallocates the backing store). It is
// therefore only safe where every read of a child NodeId happens before any
// transform that could append -- i.e. extract the scalar NodeId values first and
// never hold the slice across a goto/transform. `kids` (the copying version)
// remains the default; this is an opt-in fast path.
pub fn (a &Arena) kids_view(id NodeId) []NodeId {
	d := a.nodes[int(id)]
	start := int(d.start)
	count := int(d.count)
	return unsafe { a.children[start..start + count] }
}

pub fn (a &Arena) count() int {
	return a.nodes.len
}

// ------------------------------------------------------------------ reader

pub struct Diagnostic {
pub:
	msg  string
	line int
	col  int
	// incomplete marks "this form is not finished yet", which is a different
	// thing from "this form is wrong". A file reader turns it into a syntax error,
	// because a file that ends mid-bracket IS broken. A REPL has to keep reading
	// instead, and cannot tell the two cases from the message text.
	incomplete bool
}

pub fn (d &Diagnostic) render(path string) string {
	return '${path}:${d.line}:${d.col}: ${d.msg}'
}

pub struct Reader {
pub:
	src    string
	source string
mut:
	arena   &Arena
	off     int
	line    int = 1
	line_at int
	diags   []Diagnostic
}

fn (mut r Reader) fail(msg string) {
	r.diags << Diagnostic{
		msg:  msg
		line: r.line
		col:  r.off - r.line_at + 1
	}
}

// short is the same, but says the form is unfinished rather than wrong. The only
// difference is the flag, which is the whole point: a REPL keeps reading on it.
fn (mut r Reader) short(msg string) {
	r.diags << Diagnostic{
		msg:        msg
		line:       r.line
		col:        r.off - r.line_at + 1
		incomplete: true
	}
}

@[inline]
fn (r &Reader) at(i int) u8 {
	if i < 0 || i >= r.src.len {
		return 0
	}
	return r.src[i]
}

@[inline]
fn (r &Reader) peek() u8 {
	return r.at(r.off)
}

@[inline]
fn (r &Reader) eof() bool {
	return r.off >= r.src.len
}

fn (mut r Reader) next() u8 {
	c := r.peek()
	r.off++
	if c == nl {
		r.line++
		r.line_at = r.off
	}
	return c
}

@[inline]
fn is_delim_byte(c u8) bool {
	// A match on a byte compiles to a jump table, where the fourteen-way
	// OR chain it replaces is fourteen branches per byte. The set is
	// exactly is_delimiter's -- control bytes other than \t\n\r are symbol
	// characters, and changing that would change what reads.
	match c {
		0, 9, 10, 13, 32, 34, 40, 41, 59, 91, 93, 123, 125 { return true }
		else { return false }
	}
}

fn (mut r Reader) is_delimiter(c u8) bool {
	return is_delim_byte(c)
}

@[direct_array_access; inline]
fn (mut r Reader) skip_ws() {
	// Raw index loop, not peek()/next() per byte: each of those is a call
	// plus bounds checks, and whitespace is the most common byte. Newlines
	// still count -- positions below depend on it.
	for r.off < r.src.len {
		c := r.src[r.off]
		if c == sp || c == tab_c || c == cr {
			r.off++
			continue
		}
		if c == nl {
			r.off++
			r.line++
			r.line_at = r.off
			continue
		}
		if c == semi {
			for r.off < r.src.len && r.src[r.off] != nl {
				r.off++
			}
			continue
		}
		if c == hash_c && r.off + 1 < r.src.len && r.src[r.off + 1] == bar {
			r.skip_block_comment()
			continue
		}
		if c == hash_c && r.off + 1 < r.src.len && r.src[r.off + 1] == semi {
			r.off += 2
			r.skip_ws()
			r.read() // datum comment: consume exactly one form
			continue
		}
		break
	}
}

fn (mut r Reader) skip_block_comment() {
	r.off += 2 // #|
	mut depth := 1
	for r.off + 1 < r.src.len && depth > 0 {
		c := r.src[r.off]
		if c == nl {
			r.line++
			r.line_at = r.off + 1
		}
		if c == hash_c && r.src[r.off + 1] == bar {
			r.off += 2
			depth++
		} else if c == bar && r.src[r.off + 1] == hash_c {
			r.off += 2
			depth--
		} else {
			r.off++
		}
	}
	// A truncated tail ("#| abc") leaves off at the end, exactly where the
	// next()-driven version stopped: past every byte it looked at.
	for r.off < r.src.len && depth > 0 {
		if r.src[r.off] == nl {
			r.line++
			r.line_at = r.off + 1
		}
		r.off++
	}
}

// read returns the next form's NodeId, or none at end of input.
//
// It wraps read_inner with position tracking: the line and column of the first
// byte of the form are recorded on the node, so an error message can later show
// where in the source the form was written.
@[direct_array_access; inline]
pub fn (mut r Reader) read() ?NodeId {
	r.skip_ws()
	if r.eof() {
		return none
	}
	line := r.line
	col := r.off - r.line_at + 1
	start := r.off
	id := r.read_inner() or { return none }
	r.arena.set_pos_origin(id, line, col, blip.SourceLocation{
		file:  r.source
		line:  line
		col:   col
		start: start
		end:   r.off
	})
	return id
}

@[direct_array_access; inline]
fn (mut r Reader) read_inner() ?NodeId {
	c := r.peek()
	match c {
		lparen {
			r.next()
			return r.read_collection(.list, rparen)
		}
		lbrack {
			r.next()
			return r.read_collection(.vector, rbrack)
		}
		lbrace {
			r.next()
			return r.read_collection(.table, rbrace)
		}
		at_c {
			// `@(...)`, `@[...]`, `@{...}` -- the mutable counterparts of the three
			// literal collection forms. The tag is on the VALUE, which is how
			// mutability is made visible without a type system: `@(1 2 3)` is an
			// array and `(1 2 3)` is a list.
			//
			// Without this the `@` read as an ordinary symbol and the collection
			// after it as an ordinary list, so `@(1 2 3)` failed at the symbol `@`
			// with "unbound identifier: @" -- which says nothing about where the
			// problem is.
			nxt := r.at(r.off + 1)
			if nxt == lparen {
				r.next()
				r.next()
				return r.read_collection(.array, rparen)
			}
			if nxt == lbrack {
				r.next()
				r.next()
				return r.read_collection(.array, rbrack)
			}
			if nxt == lbrace {
				r.next()
				r.next()
				return r.read_collection(.buffer, rbrace)
			}
			return r.read_atom()
		}
		rparen | rbrack | rbrace {
			r.fail('unexpected byte 0x' + c.hex())
			r.next()
			return r.read()
		}
		quote_c, quasi_c, unquote_c {
			r.next()
			tag := match c {
				quote_c { DatumTag.quoted }
				quasi_c { DatumTag.quasi }
				else { DatumTag.unquote }
			}

			// `,@x` is one form, so the splice marker is consumed before the
			// operand is read. Otherwise the operand reader would see `@x` and
			// treat the `@` as the head of a character literal.
			if tag == .unquote && r.peek() == at_c {
				r.next()
				inner := r.read() or { return none }
				id := r.arena.leaf(.unquote_splice)
				r.arena.add_child(id, inner)
				return id
			}
			inner := r.read() or { return none }
			id := r.arena.leaf(tag)
			r.arena.add_child(id, inner)
			return id
		}
		`"` {
			return r.read_string()
		}
		`|` {
			// `|...|` is a symbol written literally, but `|>`, `|*>`, `||` and the
			// rest are OPERATORS, and the two are told apart by what follows the
			// bar: a space or a closing bracket means a literal symbol, anything else
			// means an operator name that ends at the next delimiter.
			//
			// Without this, `(->> x |> string-upcase)` read `|> string-upcase ` as
			// one bar-symbol and then reported `unbound identifier: > string-upcase`.
			// The reader's own diagnostic count was zero, which is the useful part:
			// `|>` is a perfectly valid token, just the wrong one.
			nxt := r.at(r.off + 1)
			if nxt == u8(0) || nxt == sp || nxt == tab_c || nxt == nl || nxt == cr || nxt == rparen
				|| nxt == rbrack || nxt == rbrace {
				return r.read_bar_symbol()
			}
			mut op := []u8{}
			for !r.eof() {
				ch := r.peek()
				if ch == sp || ch == tab_c || ch == nl || ch == cr || ch == rparen || ch == rbrack
					|| ch == rbrace {
					break
				}
				op << r.next()
			}
			return r.arena.str_leaf(.sym, op.bytestr())
		}
		`#` {
			return r.read_hash()
		}
		else {
			return r.read_atom()
		}
	}
}

@[direct_array_access; inline]
fn (mut r Reader) read_collection(tag DatumTag, close u8) ?NodeId {
	id := r.arena.open(tag)
	// Most collections are small: a capacity of 8 means one allocation
	// and no growth for the common case, instead of 0->1->2->4->8.
	mut items := []NodeId{cap: 8}
	for {
		r.skip_ws()
		if r.eof() {
			r.short('unclosed ' + tag.str() + ', expected byte 0x' + close.hex())
			break
		}
		if r.peek() == close {
			r.next()
			break
		}
		before := r.off
		child := r.read() or { break }
		if r.off == before {
			break
		}
		items << child
	}
	// Children are gathered locally and attached as one contiguous run, so a
	// nested list's children cannot end up interleaved with this node's.
	r.arena.finish(id, items)
	return id
}

@[direct_array_access; inline]
fn (mut r Reader) read_string() ?NodeId {
	start := r.off + 1 // past the opening quote
	// Fast scan for the closing quote: most strings have no escapes, and
	// for those the interior is used verbatim -- no buffer, no copy. The
	// slow path below only runs when a backslash actually appears.
	//
	// Line counting stays with whoever walks: the fast scan counts (its
	// count stands on success), and on the escape fallback the saved
	// position is restored so the slow walk counts the same lines once.
	sline := r.line
	sline_at := r.line_at
	mut i := start
	for i < r.src.len {
		c := r.src[i]
		if c == dquote {
			r.off = i + 1
			return r.arena.str_leaf(.str, r.src[start..i])
		}
		if c == backslash_bs {
			break
		}
		if c == nl {
			r.line++
			r.line_at = i + 1
		}
		i++
	}
	// Slow path: escapes, or a truncated tail. off resumes after the
	// opening quote; the loop below re-walks the plain prefix, which is
	// bounded by the string length and only paid for when escapes exist.
	// Positions are restored first so lines are counted exactly once.
	r.off = start
	r.line = sline
	r.line_at = sline_at
	mut buf := []u8{cap: 32}
	for {
		if r.eof() {
			r.short('unterminated string')
			break
		}
		c := r.next()
		if c == dquote {
			break
		}
		if c != `\\` {
			buf << c
			continue
		}
		if r.eof() {
			r.fail('unterminated string escape')
			break
		}
		e := r.next()
		match e {
			`n` {
				buf << `\n`
			}
			`t` {
				buf << `\t`
			}
			`r` {
				buf << `\r`
			}
			`0` {
				buf << 0
			}
			`\\` {
				buf << `\\`
			}
			`"` {
				buf << `"`
			}
			else {
				buf << `\\`
				buf << e
			}
		}
	}
	return r.arena.str_leaf(.str, buf.bytestr())
}

@[inline]
fn (mut r Reader) read_bar_symbol() ?NodeId {
	start := r.off + 1 // |
	mut i := start
	for i < r.src.len && r.src[i] != `|` {
		if r.src[i] == nl {
			r.line++
			r.line_at = i + 1
		}
		i++
	}
	if i >= r.src.len {
		r.off = i
		r.short('unterminated |symbol|')
		return r.arena.str_leaf(.sym, r.src[start..i])
	}
	r.off = i + 1 // closing |
	return r.arena.str_leaf(.sym, r.src[start..i])
}

// read_symbol_text consumes the run of non-delimiter bytes at the cursor and
// returns them, without allocating an arena node. The text is a slice of the
// source, not a copy: symbols are immutable and the arena already retains
// every value, so pinning the source costs nothing new.
@[inline]
fn (mut r Reader) read_symbol_text() string {
	start := r.off
	for r.off < r.src.len {
		if is_delim_byte(r.src[r.off]) {
			break
		}
		r.off++
	}
	return r.src[start..r.off]
}

fn (mut r Reader) read_hash() ?NodeId {
	r.next() // consume #
	c := r.peek()
	match c {
		// #:name -- a keyword written with the Racket-style #: prefix, used for
		// labelled arguments and struct options. The '#' is a dispatch character
		// here, not part of the name.
		colon {
			r.next()
			name := r.read_symbol_text()
			return r.arena.str_leaf(.kw, name)
		}
		lparen {
			r.next()
			return r.read_collection(.bytes, rparen)
		}
		backslash {
			r.next()
			return r.read_character()
		}
		`"` {
			return r.read_string()
		}
		`t`, `f` {
			r.next()
			return r.arena.int_leaf(.bool, if c == `t` { 1 } else { 0 })
		}
		else {
			r.fail('unknown # syntax')
			r.next()
			return r.read()
		}
	}
}

fn (mut r Reader) read_character() ?NodeId {
	mut name := []u8{}
	for !r.eof() && !r.is_delimiter(r.peek()) {
		name << r.next()
	}
	s := name.bytestr()
	cp := match s {
		'newline', 'linefeed' {
			u8(10)
		}
		'space' {
			u8(32)
		}
		'tab' {
			u8(9)
		}
		'return', 'carriage-return' {
			u8(13)
		}
		'backspace' {
			u8(8)
		}
		'escape' {
			u8(27)
		}
		'null', 'nul' {
			u8(0)
		}
		'alpha' {
			u8(7)
		}
		else {
			// A single character, or an escape such as #\n or #\x41.
			if s.len == 1 {
				u8(s[0])
			} else if s.len > 2 && (s[0] == x_c || s[0] == `X`) {
				hexv := strconv.parse_uint(s[1..], 16, 32) or {
					r.fail('bad hex character ${s}')
					return r.arena.int_leaf(.char, 63)
				}
				u8(hexv)
			} else if s.len == 2 {
				match u8(s[1]) {
					nl { u8(10) }
					tab_c { u8(9) }
					cr { u8(13) }
					zero_c { u8(0) }
					else { u8(s[1]) }
				}
			} else {
				r.fail('unknown character name ${s}')
				u8(63)
			}
		}
	}

	return r.arena.int_leaf(.char, i64(cp))
}

// read_atom handles keywords, numbers, and symbols.
@[direct_array_access; inline]
fn (mut r Reader) read_atom() ?NodeId {
	start := r.off
	for r.off < r.src.len {
		if is_delim_byte(r.src[r.off]) {
			break
		}
		r.off++
	}
	if r.off == start {
		r.fail('unexpected byte 0x' + r.peek().hex())
		r.next()
		return r.read()
	}

	// Keyword: :foo, :foo/bar, and bare : alone.
	if r.src[start] == `:` {
		return r.arena.str_leaf(.kw, r.src[start + 1..r.off])
	}

	// Integer fast path: an optional sign followed by digits only. One
	// pass, no allocation; the token string is never materialised. Anything
	// else -- floats, rationals, radix prefixes, symbols, overflow -- falls
	// through to try_number, which reproduces atoi64-then-atof64 exactly.
	mut i := start
	if r.src[i] == minus_c || r.src[i] == plus_c {
		i++
	}
	if i < r.off {
		c := r.src[i]
		if c >= zero_c && c <= nine_c {
			neg := r.src[start] == minus_c
			limit := if neg { u64(9223372036854775808) } else { u64(9223372036854775807) }
			mut acc := u64(0)
			mut ok := true
			mut j := i
			for j < r.off {
				d := r.src[j]
				if d < zero_c || d > nine_c {
					ok = false
					break
				}
				dig := u64(d - zero_c)
				if acc > (limit - dig) / 10 {
					ok = false
					break
				}
				acc = acc * 10 + dig
				j++
			}
			if ok {
				if neg {
					if acc == u64(9223372036854775808) {
						return r.arena.int_leaf(.int, i64(-9223372036854775807 - 1))
					}
					return r.arena.int_leaf(.int, -i64(acc))
				}
				return r.arena.int_leaf(.int, i64(acc))
			}
		}
	}
	s := r.src[start..r.off]

	if id := r.try_number(s) {
		return id
	}

	return r.arena.str_leaf(.sym, s)
}

// try_number returns none for anything that is not a number.
@[inline]
fn (mut r Reader) try_number(s string) ?NodeId {
	if s.len == 0 {
		return none
	}
	first := s[0]
	is_digit := first >= `0` && first <= `9`
	if !is_digit && first != minus_c && first != plus_c && first != dot_c {
		return none
	}
	// A token with no digit in it is never a number, so "abc" and "-" stay
	// symbols rather than becoming parse errors.
	mut has_digit := false
	for ch in s {
		if ch >= `0` && ch <= `9` {
			has_digit = true
			break
		}
	}
	if !has_digit {
		return none
	}

	// Rational: 1/3
	idx := s.index('/') or { -1 }
	if idx > 0 {
		n := strconv.atoi64(s[..idx]) or { return none }
		d := strconv.atoi64(s[idx + 1..]) or { return none }
		if d == 0 {
			r.fail('rational with zero denominator')
			return r.arena.int_leaf(.int, 0)
		}
		id := r.arena.leaf(.rat)
		mut node := r.arena.node(id)
		node.i = n
		node.den = d
		return id
	}

	// Radix prefixes: 0xff, 0b1010, 0o17
	if s.len > 2 && s[0] == zero_c {
		base := match s[1] {
			`x`, `X` { 16 }
			`b`, `B` { 2 }
			`o`, `O` { 8 }
			else { 0 }
		}

		if base != 0 {
			v := strconv.parse_uint(s[2..], base, 64) or {
				r.fail('bad ${s} literal')
				return r.arena.int_leaf(.int, 0)
			}
			return r.arena.int_leaf(.int, i64(v))
		}
	}

	if n := strconv.atoi64(s) {
		return r.arena.int_leaf(.int, n)
	}
	// Float forms: 3.14, 1e10, 6.02e23, -0.5, +1.
	if f := strconv.atof64(s, strict_float) {
		return r.arena.float_leaf(f)
	}
	// ".5" and "-.5" land here, because atof64 wants a digit before the point.
	if s.len > 1 {
		if f := strconv.atof64(zero_c.str() + s, strict_float) {
			return r.arena.float_leaf(f)
		}
	}
	return none
}

// Depth is how far into a form the REPL is, and whether a string is open.
//
// A second, independent scan rather than a mode on Reader, because the REPL needs
// this before it decides to read: the buffer is re-parsed on every keystroke-line,
// and the answer it wants -- "is anything still open?" -- has to be computable
// without reading anything.
//
// `;` comments and `#| ... |#` blocks are skipped, and a `|`-delimited symbol is
// NOT a string: `(a |x| b)` is balanced, while `(a "x` is not. Getting that
// backwards makes the prompt lie about the one case a prompt exists for.
pub struct Depth {
pub mut:
	n          int
	in_string  bool
	in_comment bool
}

// depth scans `src` and reports how many brackets are still open.
//
// The obvious version counts `(`, `[` and `{` and forgets about strings, so
// `(print "(")` looks unterminated forever and the REPL waits for a bracket the
// user has no intention of typing. Byte iteration, not rune iteration: V iterates
// a string as bytes, and a rune loop mangles every multi-byte character -- which
// here would mean the offset arithmetic is wrong for any input containing one.
pub fn depth(src string) Depth {
	mut d := Depth{
		n: 0
	}
	mut i := 0
	for i < src.len {
		c := src[i]
		// A `#|` block comment, nested like the lexer reads it. Non-nested
		// handling would still be right for all but commented-out blocks that
		// contain their own terminator, which is vanishingly rare in a REPL
		// buffer.
		if c == hash_c && i + 1 < src.len && src[i + 1] == bar {
			mut level := 1
			i += 2
			for i + 1 < src.len && level > 0 {
				if src[i] == hash_c && src[i + 1] == bar {
					level++
					i += 2
				} else if src[i] == bar && src[i + 1] == hash_c {
					level--
					i += 2
				} else {
					i++
				}
			}
			continue
		}
		if c == semi {
			for i < src.len && src[i] != nl {
				i++
			}
			continue
		}
		if c == dquote {
			i++
			mut closed := false
			for i < src.len {
				if src[i] == backslash_bs {
					i += 2
					continue
				}
				if src[i] == dquote {
					closed = true
					i++
					break
				}
				i++
			}
			if !closed {
				d.in_string = true
			}
			continue
		}
		if c == lparen || c == lbrack || c == lbrace {
			d.n++
		} else if c == rparen || c == rbrack || c == rbrace {
			if d.n > 0 {
				d.n--
			}
		}
		i++
	}
	d.in_comment = d.n > 0 || d.in_string
	return d
}

// ------------------------------------------------------------------ entry

pub struct ReadResult {
pub mut:
	arena Arena
	forms []NodeId
	diags []Diagnostic
}

// Forms is the result of reading into an arena someone else owns. It carries no
// arena, because copying one would invalidate every NodeId in it.
pub struct Forms {
pub mut:
	forms []NodeId
	diags []Diagnostic
}

// read_forms parses `src` and appends every node it creates to this arena.
//
// This exists for one reason: a machine that evaluates a second file has to keep
// the first file's nodes alive, because closures and continuation frames hold
// NodeIds and nothing else. Reading into a fresh arena and swapping the machine's
// pointer would leave every existing closure pointing at indices in the wrong
// array -- silently, and only for code defined before the second read. Appending
// to one arena costs the memory of every program the machine has ever run and is
// correct by construction.
//
// It is a method rather than a free function taking `mut a &Arena` because that
// spelling does not compile on V 0.5.2, and the alternative -- taking the arena by
// value and trusting that V passes `mut` parameters by reference -- makes the
// aliasing depend on a language rule, which is exactly the sort of thing this
// project has been bitten by before.
pub fn (mut a Arena) read_forms(src string) Forms {
	return a.read_source(src, 'blip')
}

// read_source retains a stable filename on every node, including nested forms.
pub fn (mut a Arena) read_source(src string, source string) Forms {
	mut r := Reader{
		src:    src
		source: source
		arena:  unsafe { &a }
	}
	mut forms := []NodeId{}
	for {
		before := r.off
		id := r.read() or { break }
		forms << id
		if r.off == before {
			break
		}
	}
	return Forms{
		forms: forms
		diags: r.diags
	}
}

// read_all parses a whole source file into top-level forms, in a fresh arena.
pub fn read_all(src string) ReadResult {
	mut a := Arena{}
	f := a.read_forms(src)
	return ReadResult{
		arena: a
		forms: f.forms
		diags: f.diags
	}
}
