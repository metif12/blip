module emit

$if !wasm32 {
import os
}
import vlib.blip
import vlib.blip.host
import vlib.blip.machine
import vlib.blip.reader

// Blip to JavaScript.
//
// This walks the reader's AST directly rather than going through the machine.
// The machine transforms `let` into nested lambdas, expands destructuring, runs
// macros and hoists structs; an emitter that reused those would be a
// transliteration of the interpreter, heavy with none of its ability to run
// what it emitted. So this compiles the forms it understands and refuses the
// rest by name, rather than emitting something that silently does not work.
//
// What it does NOT do is real tail calls, and that is the boundary, not an
// oversight. JavaScript engines other than Safari do not implement tail call
// elimination, so `(loop 250000)` that costs nothing on the blip machine grows
// the JS stack here. A trampoline -- every call returns a thunk, a loop drives
// it -- would fix that, and it is large enough to deserve its own design rather
// than a footnote. Until then this is a transpiler for a subset, and the subset
// is stated by what it refuses.

pub struct Result {
pub mut:
	js      string
	blocked []string
}

// compile_program turns a blip PROGRAM into a JavaScript module, with the
// standard library in front of it -- in load order, which is the order `blip run`
// uses, so a program that shadows a stdlib name shadows it here too.
//
// It is separate from `compile` because knowing that a program needs the stdlib
// is the caller's decision, not something a transpiler should assume: a caller
// that wants a bare module, or one that has already prepended the library, gets
// nonsense from a second copy. Both callers that emit runnable programs -- the
// CLI and the gate -- go through here, so the knowledge lives in one place
// instead of being re-derived and forgotten, which is how the gate ended up
// running examples with no `lookup-sym` and calling the silence a failure.
pub fn compile_program(src string) !Result {
	$if wasm32 {
		return error('not available in wasm build')
	} $else {
		std_src := os.read_file('lib/std.lip') or {
			return error('cannot read lib/std.lip: ${err.msg()}')
		}
		return compile(std_src + '\n' + src)
	}
}

// compile turns blip source into a JavaScript module.
pub fn compile(src string) !Result {
	return compile_with_base(src, '')
}

// compile_file compiles one file, resolving `require` relative to its own
// directory, the way `blip run file` does.
pub fn compile_file(path string) !Result {
	$if wasm32 {
		return error('not available in wasm build')
	} $else {
		src := os.read_file(path) or {
			return error('cannot read ${path}: ${err.msg()}')
		}
		std_src := os.read_file('lib/std.lip') or {
			return error('cannot read lib/std.lip: ${err.msg()}')
		}
		return compile_with_base(std_src + '\n' + src, os.dir(path))
	}
}

// compile_with_base is the real implementation: `base` is the directory the
// source lives in, used to resolve `require`.
fn compile_with_base(src string, base string) !Result {
	mut res := reader.read_all(src)
	if res.diags.len > 0 {
		d := res.diags[0]
		return error('${d.line}:${d.col}: ${d.msg}')
	}
	// Macro pre-pass: defmacro forms register their macro in an embedded
	// machine and are dropped from the output; macro calls (registered
	// macros and explicit macex/macex1) are expanded through that machine
	// and re-read, so the emitter only ever sees ordinary forms. A macro
	// that expands to itself, or one that fails to register, is a compile
	// error rather than a silently dropped form.
	mut mach := machine.new_machine_with(&res.arena, host.new_capture())
	mut expanded_forms := []reader.NodeId{}
	for id in res.forms {
		if is_defmacro_form(res.arena, id) {
			txt := form_text(src, res.arena, id)
			mach.run_str(txt) or {
				return error('macro registration failed: ${err.msg()}')
			}
			continue
		}
		nid := expand_form(mut mach, res.arena, id) or {
			return error('macro expansion failed: ${err.msg()}')
		}
		expanded_forms << nid
	}
	res.forms = expanded_forms
	mut e := Emitter{
		arena:        &res.arena
		top:          map[string]bool{}
		mangled:      map[string]string{}
		collided:     map[string]string{}
		takes_kwargs: map[string]bool{}
		base:         base
		loaded:       map[string]bool{}
	}
	// Two passes, because a function may refer to a name defined later in the
	// file -- ordinary in blip, impossible in a `const` declaration.
	for id in res.forms {
		e.remember(id)
	}
	mut before := e.out.len
	for id in res.forms {
		e.form(id)
	}
	before = e.out.len
	// The runtime comes first in the TEXT even though it is emitted last, so the
	// generated module is self-contained: one file, runnable by node as it is.
	mut body := e.out.clone()
	e.out = []
	e.emit(prelude)
	e.out << ''
	for line in body {
		e.out << line
	}
	return Result{
		js:      e.out.join('\n')
		blocked: e.blocked
	}
}

// prelude is the JavaScript the generated module needs. Every blip primitive
// that is not also a JavaScript identifier lives here, because a backend whose
// output cannot run is a backend that was never verified.
// The blip runtime, as a real JavaScript file rather than a V string.
//
// It lives at `prelude.js` beside this file and is compiled into the binary with
// $embed_file, so an emitted module carries it verbatim and there is no path to
// resolve at runtime. It is a separate file because it used to be a single-quoted
// V string, where every `\"` needed escaping twice and one wrong replacement
// could terminate the string silently -- which is exactly what happened twice
// while adding a trampoline.
const prelude = $embed_file('prelude.js').to_string()

struct Emitter {
mut:
	arena   &reader.Arena
	out     []string
	depth   int
	top     map[string]bool
	blocked []string
	// tail is how deep inside a TAIL position of a function body the emitter is
	// currently standing. Zero means an ordinary position, where a call has to
	// be driven, because the caller's frame is still needed to receive the value.
	// Positive means the value produced IS the function's own value, so a call
	// there may return a thunk and let the trampoline take the frame away.
	//
	// It has to be threaded explicitly rather than inferred, because the same
	// expression sits in a different position depending on where it appears: the
	// last form of a body is in tail position and the first is not. A test, an
	// argument, and a short-circuited operand are all NOT, and each of those is
	// a place where a tail call would hand the frame to a caller that is not
	// looping, so the flag is cleared at each one rather than left inherited.
	tail     int
	gensym   int
	mangled  map[string]string
	collided map[string]string
	// locals map each blip name bound by an enclosing construct to the JavaScript
	// identifier that holds it, innermost last. The indirection is not tidiness:
	// a `use` binds a single result to the CALLEE's own name, so `(use (connect
	// "h") ...)` binds `connect` -- and a `let connect` in the same block shadows
	// the very function being called, which JavaScript resolves as a temporal dead
	// zone rather than as a frame. blib makes the binding in a NEW frame after the
	// call returns, so the map gives the binding its own identifier and the body
	// reads that.
	locals []map[string]string
	// takes_kwargs records which functions were declared with a `:name [b
	// default]` parameter. A call site needs it to know whether a keyword in its
	// arguments is a keyword ARGUMENT or just a keyword value -- `(get conn
	// :session)` is the second and rewriting it as a bundle is not JavaScript.
	//
	// It is order-dependent: a call that textually precedes the definition does not
	// collapse. That matches how blip itself reads (define before use) and is
	// recorded rather than worked around.
	takes_kwargs map[string]bool
	// base is the directory the source being compiled lives in, so a
	// `require "lib/x.vl"` resolves next to THIS file rather than next to
	// the process's working directory -- the same rule resolve_path uses in
	// the machine.
	base string
	// loaded remembers which module paths have already been inlined, so a
	// file required twice is emitted once.
	loaded map[string]bool
}

// push_local records one binding under its blip name and the identifier that
// holds it.
fn (mut e Emitter) push_local(blip_name string, js string) int {
	mut m := map[string]string{}
	m[blip_name] = js
	e.locals << m
	return e.locals.len
}

fn (mut e Emitter) push_locals(names []string) int {
	mut m := map[string]string{}
	for n in names {
		m[n] = e.mangle_name(n)
	}
	e.locals << m
	return e.locals.len
}

fn (mut e Emitter) pop_locals(depth int) {
	for e.locals.len > depth {
		e.locals.pop()
	}
}

// local_js answers which identifier a name bound by an enclosing construct is
// held in. The blip name is compared, not the mangled one, because that is what
// the source says.
fn (e &Emitter) local_js(name string) ?string {
	for i := e.locals.len - 1; i >= 0; i-- {
		if js := e.locals[i][name] {
			return js
		}
	}
	return none
}

// ------------------------------------------------------------------ helpers

// max_depth bounds how deep the emitter will recurse into an AST before it
// refuses the program.
//
// Without a bound, a real example -- `examples/01_basics.lip`, 153 lines --
// overflows the native stack and dies with `V panic: stack overflow`, exit code
// 0xC00000FD. That is unrecoverable: no error is returned, nothing is explained,
// and the caller gets a dead process. A limit turns the same program into a
// refusal that names the problem, which is the only failure this emitter is
// allowed to have.
//
// The number is generous for real source -- ordinary code nests tens deep, not
// thousands -- and small enough that hitting it means a genuine pathology rather
// than a deep expression. If a legitimate program ever hits it, the answer is an
// explicit stack, not a larger number.
const max_depth = 600

fn (mut e Emitter) enter() ! {
	e.depth++
	if e.depth > max_depth {
		e.depth--
		return error('expression nests deeper than ${max_depth}; the emitter refuses it rather than overflowing the stack')
	}
}

fn (mut e Emitter) leave() {
	if e.depth > 0 {
		e.depth--
	}
}

fn (mut e Emitter) kids(id reader.NodeId) []reader.NodeId {
	return e.arena.kids(id)
}

fn (mut e Emitter) node(id reader.NodeId) &reader.Datum {
	return e.arena.node(id)
}

fn (mut e Emitter) emit(line string) {
	indent := if e.depth > 0 { '  '.repeat(e.depth) } else { '' }
	e.out << '${indent}${line}'
}

fn (mut e Emitter) refuse(what string) {
	if what !in e.blocked {
		e.blocked << what
	}
}

// remember collects the top-level names so a forward reference resolves.
fn (mut e Emitter) remember(id reader.NodeId) {
	d := e.node(id)
	if d.tag != .list {
		return
	}
	kids := e.kids(id)
	if kids.len < 2 {
		return
	}
	head := e.node(kids[0])
	if head.tag != .sym {
		return
	}
	if head.value != 'define' && head.value != 'def' {
		return
	}
	sig := e.node(kids[1])
	if sig.tag == .sym {
		e.top[sig.value] = true
	}
}

// ------------------------------------------------------------------ forms

fn (mut e Emitter) form(id reader.NodeId) {
	d := e.node(id)
	if d.tag != .list {
		e.emit('${e.value(id)};')
		return
	}
	kids := e.kids(id)
	if kids.len == 0 {
		e.emit('[];')
		return
	}
	head := e.node(kids[0])
	if head.tag == .sym {
		if head.value.contains('.') {
			dot := head.value.last_index('.') or { 0 }
			base := e.mangle_name(head.value[..dot])
			field := e.mangle_name(head.value[dot + 1..])
			if kids.len == 3 {
				marker := e.node(kids[1])
				if (marker.tag == .kw && marker.value == '=') || (marker.tag == .sym && marker.value == ':=') {
					val := e.value(kids[2])
					e.emit('${base} = Object.assign({}, ${base}, { ${field}: ${val} });')
					return
				}
			}
			if kids.len <= 1 {
				e.emit('${base}.${field};')
			} else {
				mut args := []string{}
				for k in kids[1..] {
					args << e.value(k)
				}
				e.emit('${base}.${field}(${args.join(', ')});')
			}
			return
		}
		if e.special(head.value, id, kids) {
			return
		}
		if head.value in unsupported_forms {
			return
		}
	}
	// The whole call is emitted by `application`, which is the one place that
	// knows how a callee reaches JavaScript. It used to be spelled out here a
	// second time, and the second copy drifted: a keyword in call position --
	// `(:a {:a 1})`, the collection-as-lookup rule the data example is built
	// around -- went through `value` on the keyword and emitted `"a"(table)`, a
	// call to a string. Two copies of one rule is how the second one rots, so
	// there is one now.
	saved_tail := e.tail
	e.tail = 0
	call := e.application(id, kids)
	e.tail = saved_tail
	e.emit('${call};')
}

fn (mut e Emitter) special(name string, id reader.NodeId, kids []reader.NodeId) bool {
	if name == 'provide' {
		// `provide` documents a module's interface; the machine treats it as a
		// no-op. The emitter agrees: nothing is emitted for it.
		return true
	}
	if name == 'require' {
		e.require_form(kids)
		return true
	}
	if name == 'define' || name == 'def' {
		e.emit_define(kids)
		return true
	}
	if name == 'lambda' || name == 'fn' {
		e.named_function('', e.kids(kids[1]), kids[2..])
		return true
	}
	if name == 'if' {
		e.emit_if(kids)
		return true
	}
	if name == 'begin' || name == 'do' {
		for k in kids[1..] {
			e.stmt(k)
		}
		return true
	}
	if name == 'let' || name == 'let*' || name == 'letrec' {
		e.emit_let(name, kids)
		return true
	}
	// These have expression spellings, so a statement position is the same
	// expression followed by a semicolon. Emitting them as calls instead -- which
	// is what the statement path did -- produced `cond([...], [else, null])`,
	// which is not JavaScript and not an error either: the file failed to parse
	// at `else`, far from the form that caused it.
	for derived in ['cond', 'when', 'unless', 'and', 'or', 'case'] {
		if name == derived {
			e.emit('${e.value(id)};')
			return true
		}
	}
	// `->` and `->>` in statement position are the same expression followed by
	// a semicolon. Without this a top-level threading form fell to the ordinary
	// call path, which mangled `->>` into an identifier and emitted a call to a
	// function that does not exist -- silently, with no refusal.
	for threader in ['->', '->>'] {
		if name == threader {
			e.emit('${e.value(id)};')
			return true
		}
	}
	// A `match` in statement position is the expression followed by a semicolon,
	// the same rule `->` follows. Without this it fell through to the call path,
	// which emitted `match(...)` -- a call to a name nothing defines.
	if name == 'match' || name == 'match*' {
		e.emit('${e.value(id)};')
		return true
	}
	// `use` in statement position is the same IIFE followed by a semicolon. Listed
	// as unsupported until now, so a top-level `use` emitted nothing at all.
	if name == 'use' {
		e.emit('${e.value(id)};')
		return true
	}
	if name == 'try' {
		e.emit('${e.value(id)};')
		return true
	}
	if name == 'quote' {
		e.emit('${e.value(kids[1])};')
		return true
	}
	// `set!` is a JavaScript assignment, which is what it means. It has to be
	// handled here rather than left to the call path, because the call path would
	// emit `set(x, v)` -- a call to a function that does not exist, which is the
	// same silent-green shape the backend gate exists to catch.
	if name == 'set!' {
		if kids.len == 3 {
			target := e.node(kids[1])
			if target.tag == .sym {
				e.emit('${e.mangle_name(target.value)} = ${e.value(kids[2])};')
				return true
			}
		}
		e.refuse('set!')
		return true
	}
	// `defined?` in statement position is the probe followed by a semicolon, the
	// same rule `cond` follows. Left to the call path it emitted `defined_q(...)`
	// -- a call to a name nothing defines, which is the silent-green shape the
	// backend gate exists to catch.
	if name == 'defined?' {
		e.emit('${e.defined_probe(kids)};')
		return true
	}
	// `dotimes` is a real loop, not a recursive call, so it becomes a real
	// JavaScript loop. `i` runs 0 to n-1 inclusive, which is what
	// `(dotimes i 5 (set! s (+ s i)))` summing to 0+1+2+3+4 = 10 asserts.
	//
	// The name and the count are SEPARATE arguments -- `(dotimes i 5 body...)`,
	// the same shape `loop` uses, not a binding list. Reading them as a binding
	// list gives no children for the symbol `i` and the guard below refuses.
	if name == 'dotimes' {
		name_d := e.node(kids[1])
		if kids.len >= 4 && name_d.tag == .sym {
			var_name := e.mangle_name(name_d.value)
			bound := e.value(kids[2])
			e.emit('for (let ${var_name} = 0; blip_truthy(blip.lt(${var_name}, ${bound})); ${var_name} = blip.add(${var_name}, 1)) {')
			e.depth++
			for b in kids[3..] {
				e.stmt(b)
			}
			e.depth--
			e.emit('}')
			return true
		}
		e.refuse('dotimes')
		return true
	}
	// `loop` is a real loop, not a call, so it becomes a real JavaScript loop.
	//
	// The increment rule is READ OUT OF THE MACHINE rather than guessed:
	// `transform_loop` appends `(set! name (+ name 1))` after the body and then
	// tail-calls, and it wraps the whole thing in `(if test body nil)` so the
	// TEST IS CHECKED FIRST. That is why `(loop i 0 (< i 5) (set! s (+ s i)))`
	// sums 0+1+2+3+4, and why `(loop i 0 #f 7)` returns nil without ever running
	// a body. Neither is visible from the form's surface, and a guessed `for`
	// would get both wrong.
	if name == 'loop' {
		name_d := e.node(kids[1])
		if kids.len >= 4 && name_d.tag == .sym {
			var_name := e.mangle_name(name_d.value)
			e.emit('let ${var_name} = ${e.value(kids[2])};')
			e.emit('while (blip_truthy(${e.value(kids[3])})) {')
			e.depth++
			for b in kids[4..] {
				e.stmt(b)
			}
			e.emit('${var_name} = blip.add(${var_name}, 1);')
			e.depth--
			e.emit('}')
			return true
		}
		e.refuse('loop')
		return true
	}
	// `(struct Point (x y))` defines a constructor, a predicate and one accessor
	// per field -- which is what `eval_struct` generates on the blip side
	// (vlib/blip/machine/mod.v). Emitting the constructor as a plain function is
	// enough for `(Point 3 4)` to work, because a constructor call is an ordinary
	// application and needs no new spelling.
	//
	// The accessor names are gone through the SAME mangling as every other
	// identifier, so `point-x` becomes `point_x` here and at every call site.
	if name == 'struct' || name == 'struct-out' {
		e.emit_struct(kids)
		return true
	}
	// A form this emitter knows about but does not yet handle is refused by
	// name, so the user is told rather than handed something that does not work.
	if name in unsupported_forms {
		e.refuse(name)
		return true
	}
	// Anything else is an ordinary call -- `print`, a user function, anything.
	// Refusing it here was a mistake: it made every function call look like an
	// unsupported form.
	return false
}

// unsupported_forms are blip special forms this emitter does not compile yet.
// Everything NOT in this list and not handled above is a plain function call.
// `match` and `match*` are no longer here: they compile, and the statement path
// needs them GONE from this list to reach `special` at all -- a name listed here
// is skipped before the special-form dispatch runs, so a top-level `match` used
// to emit nothing and look like a silent success.
const unsupported_forms = ['loop', 'dotimes', 'struct', 'as->', 'cond->', 'import', 'quasiquote',
	'unquote', 'unquote-splicing', 'yield', 'veb-route']

fn (mut e Emitter) emit_define(kids []reader.NodeId) {
	if kids.len < 3 {
		e.refuse('define')
		return
	}
	sig := e.node(kids[1])
	if sig.tag == .list {
		inner := e.kids(kids[1])
		if inner.len == 0 || e.node(inner[0]).tag != .sym {
			e.refuse('define')
			return
		}
		// (define (name p1 p2 ...) body...). The signature's head is the name;
		// everything after it is parameters.
		e.named_function(e.node(inner[0]).value, inner[1..], kids[2..])
		return
	}
	if sig.tag == .sym {
		// `let`, not `const`. `(define s 0)` followed by `(set! s ...)` is
		// ordinary blip, and JavaScript throws on an assignment to a `const`.
		// The mangling matches every other use of the name, so a definition and a
		// `set!` cannot disagree.
		e.emit('var ${e.mangle_name(sig.value)} = ${e.value(kids[2])};')
		return
	}
	e.refuse('define')
}

// named_function emits a JS function from a name, a parameter node list and a
// body. The body's LAST form is returned, so a blip function's value is the
// value of its last form, which is how blip decides it too.
fn (mut e Emitter) named_function(name string, params []reader.NodeId, body []reader.NodeId) {
	mut ps := []string{}
	mut param_names := []string{}
	// A parameter that is a PATTERN destructures on entry rather than being
	// refused: `(define (dist (struct Point x: px y: py)) ...)`. The JavaScript
	// parameters stay plain, and the destructuring is emitted as a statement at
	// the top of the body -- which is safe here because a function body is a
	// statement position.
	mut destructures := []string{}
	mut arg := 0
	// `:name [binding default]` is a KEYWORD parameter: the call site names it
	// with a keyword and may leave it out. JavaScript has no keyword arguments,
	// so they travel as one trailing object and the function reads it -- which is
	// a convention both sides have to agree on, so it is written in both places.
	mut kwargs := []string{}
	for pi := 0; pi < params.len; pi++ {
		p := params[pi]
		d := e.node(p)
		if d.tag == .kw {
			// The default lives in the NEXT form, `[binding default]`, and that form
			// is part of this parameter -- not another one. Iterating with an index is
			// what makes skipping it possible; a value loop processed the default as a
			// second parameter and declared its binding twice.
			if pi + 1 >= params.len {
				e.refuse('keyword parameter')
				return
			}
			slot := e.kids(params[pi + 1])
			if slot.len < 2 {
				e.refuse('keyword parameter')
				return
			}
			bind := e.node(slot[0])
			if bind.tag != .sym {
				e.refuse('keyword parameter')
				return
			}
			mut js_default := e.test_of(slot[1])
			if js_default.starts_with('thunk(') {
				js_default = js_default[6..js_default.len - 1]
			}
			kwargs << 'const ${e.mangle_name(bind.value)} = (__blip_kw && __blip_kw[${json_str(d.value)}] !== undefined) ? __blip_kw[${json_str(d.value)}] : ${js_default};'
			param_names << bind.value
			pi++
			continue
		}
		if d.tag == .sym {
			ps << e.mangle_name(d.value)
			param_names << d.value
			arg++
			continue
		}
		e.gensym++
		raw := '__blip_arg${e.gensym}'
		ps << raw
		bp := e.binding_pattern(p)
		if !bp.ok {
			return
		}
		tag := '__blip_d${e.gensym}'
		// No braces around these: the names they declare belong to the function
		// body, and a block would scope them to the block -- which is how `px`
		// became undefined in the body of `dist`.
		destructures << 'const ${tag} = pat_match(${bp.js}, ${raw});'
		destructures << 'if (${tag} === "no") { throw new Error("blip: ${name}: parameter does not match its pattern"); }'
		for nm in bp.names {
			destructures << 'const ${nm} = ${tag}["${nm}"];'
			param_names << nm
		}
		arg++
	}
	_ = arg
	if kwargs.len > 0 {
		ps << '__blip_kw'
		e.takes_kwargs[name] = true
	}
	// The NAME goes through the same mangling as every other identifier, here
	// rather than at each call site, so a definition and a call cannot disagree.
	// Without this, `count-down` was defined with its hyphen while every call
	// was mangled -- a ReferenceError, and a worse one than a visible difference
	// because the emitted file looks plausible.
	js_name := e.mangle_name(name)
	head := if js_name == '' { '' } else { ' ' + js_name }
	e.emit('function${head}(${ps.join(', ')}) {')
	e.depth++
	for line in destructures {
		e.emit(line)
	}
	for line in kwargs {
		e.emit(line)
	}
	// Every parameter is in scope for the whole body, and a parameter named
	// `first` or `string` must win over the primitive of that name.
	mark := e.push_locals(param_names)
	defer {
		e.pop_locals(mark)
	}
	// The LAST body form is the function's value, so it is in tail position and
	// everything before it is not. That is the whole rule.
	for i, b in body {
		if i == body.len - 1 {
			e.tail++
			e.emit('return ${e.value(b)};')
			e.tail--
		} else {
			e.stmt(b)
		}
	}
	e.depth--
	e.emit('}')
}

fn (mut e Emitter) emit_if(kids []reader.NodeId) {
	if kids.len < 3 {
		e.refuse('if')
		return
	}
	e.emit('if (${e.value(kids[1])}) {')
	e.depth++
	e.stmt(kids[2])
	e.depth--
	if kids.len >= 4 {
		e.emit('} else {')
		e.depth++
		e.stmt(kids[3])
		e.depth--
	}
	e.emit('}')
}

// put_back is the inverse of the parameter split, restored by named_function.
fn (mut e Emitter) emit_let(kind string, kids []reader.NodeId) {
	// The three spellings are NOT the same thing, and treating them as one is why
	// `(let* ([a 1] [b (+ a 1)]) b)` came out as `((a, b) => ...)(1, a + 1)` --
	// a ReferenceError where blip answers 2.
	//
	//   let     all values evaluated in the OUTER scope; the bindings are simultaneous
	//   let*    each value sees the bindings before it
	//   letrec  every binding visible to every other, so mutual recursion works
	//
	// `let` keeps the IIFE, which is a lambda applied and is exactly right. The
	// other two become plain declarations, which is the only shape where a later
	// value can see an earlier name.
	if kids.len < 3 {
		e.refuse('let')
		return
	}
	// `(let assert PATTERN VALUE body...)` is a match with no other clause, so a
	// mismatch is a hard error naming the pattern rather than a nil to carry. The
	// machine spells it transform_let_assert; the emitter matches directly.
	if e.node(kids[1]).tag == .sym && e.node(kids[1]).value == 'assert' {
		if kids.len < 4 {
			e.refuse('let assert')
			return
		}
		bk := e.kids(kids[2])
		if bk.len < 2 {
			e.refuse('let assert')
			return
		}
		p := e.pattern(bk[0])
		if !p.ok {
			return
		}
		e.gensym++
		tag := '__blip_a${e.gensym}'
		e.emit('(() => {')
		e.emit('const ${tag} = pat_match(${p.js}, ${e.value(bk[1])});')
		e.emit('if (${tag} === "no") { throw new Error("blip: let assert: value does not match its pattern"); }')
		for nm in p.names {
			e.emit('const ${nm} = ${tag}["${nm}"];')
		}
		e.depth++
		for i, b in kids[3..] {
			if i == kids.len - 4 {
				e.emit('return ${e.value(b)};')
			} else {
				e.stmt(b)
			}
		}
		e.depth--
		e.emit('})();')
		return
	}
	bindings := e.kids(kids[1])
	mut body := kids[2..]
	// `(let NAME VALUE body...)` is the same thing as `(let ([NAME VALUE])
	// body...)`, and std.lip uses the short form everywhere -- every one of
	// parse-in, lookup-sym, validate and connect is written that way. Reading
	// kids[1] as a binding LIST took its children, which a symbol has none of,
	// so the bindings were empty and the function body was emitted with nothing
	// bound: `parse-in` returned null for every input and nothing said so.
	mut plain := false
	if e.node(kids[1]).tag == .sym && kids.len >= 4 {
		plain = true
		body = kids[3..]
	}
	if kind == 'let' {
		mut names := []string{}
		mut vals := []string{}
		if plain {
			names << e.mangle_name(e.node(kids[1]).value)
			vals << e.test_of(kids[2])
		}
		for b in bindings {
			if plain {
				break
			}
			inner := e.kids(b)
			if inner.len < 2 {
				e.refuse('let binding')
				return
			}
			if e.node(inner[0]).tag != .sym {
				// A pattern binding, `([(list h t) '(1 2)])`. It cannot be a
				// destructuring arrow parameter -- there is no name to bind -- so it
				// becomes an IIFE that matches and then declares the names.
				e.pattern_let(bindings, body)
				return
			}
			names << e.mangle_name(e.node(inner[0]).value)
			vals << e.test_of(inner[1])
		}
		e.emit('((${names.join(', ')}) => {')
		e.depth++
		for i, b in body {
			if i == body.len - 1 {
				e.emit('return ${e.value(b)};')
			} else {
				e.stmt(b)
			}
		}
		e.depth--
		e.emit('})(${vals.join(', ')});')
		return
	}
	// Wrapped in an IIFE, which is what keeps the bindings local. Emitting bare
	// `let a = 1; ... return b;` puts a `return` at whatever depth the enclosing
	// function allows -- top level, that is a SyntaxError and the whole file fails
	// to parse, far from the form that caused it. The IIFE costs nothing and is
	// the same shape `let` uses.
	e.emit('(() => {')
	e.depth++
	// `letrec` declares every name BEFORE any of them has a value, so a binding
	// can refer to one that comes after it -- which is the whole point of the
	// form: `(letrec ([even? (lambda (n) ... (odd? ...))] [odd? ...]) ...)`.
	// Emitting `let even_q = ...` first makes `odd_q` a ReferenceError the first
	// time the closure runs, not when it is defined, so the error surfaces far
	// from the cause.
	if kind == 'letrec' {
		mut names := []string{}
		for b in bindings {
			inner := e.kids(b)
			if inner.len < 2 || e.node(inner[0]).tag != .sym {
				e.refuse('let binding')
				return
			}
			names << e.mangle_name(e.node(inner[0]).value)
		}
		e.emit('let ${names.join(', ')};')
		for i, b in bindings {
			inner := e.kids(b)
			e.emit('${names[i]} = ${e.value(inner[1])};')
		}
	} else {
		for b in bindings {
			inner := e.kids(b)
			if inner.len < 2 || e.node(inner[0]).tag != .sym {
				e.refuse('let binding')
				return
			}
			nm := e.mangle_name(e.node(inner[0]).value)
			val := e.value(inner[1])
			e.emit('let ${nm} = ${val};')
		}
	}
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

// emit_struct emits the constructor, predicate and accessors for a struct
// declaration, mirroring what `eval_struct` generates in the machine.
fn (mut e Emitter) emit_struct(kids []reader.NodeId) {
	if kids.len < 3 {
		e.refuse('struct')
		return
	}
	name_d := e.node(kids[1])
	if name_d.tag != .sym {
		e.refuse('struct')
		return
	}
	name := name_d.value
	fields := e.kids(kids[2])
	mut field_names := []string{}
	for f in fields {
		fd := e.node(f)
		if fd.tag != .sym {
			e.refuse('struct field')
			return
		}
		field_names << fd.value
	}
	mut mutable := false
	mut mi := 3
	for mi < kids.len {
		kd := e.node(kids[mi])
		if kd.tag == .kw && kd.value == 'mutable' {
			mutable = true
		}
		mi++
	}
	low := name.to_lower()
	// constructor, predicate, accessors (as before)
	e.emit('function ${e.mangle_name(name)}(${field_names.map(e.mangle_name).join(', ')}) {')
	e.depth++
	e.emit('return { blip_struct: "${name}", ${field_names.map(e.mangle_name).join(', ')} };')
	e.depth--
	e.emit('}')
	e.emit('function ${e.mangle_name('${low}?')}(v) { return !!v && v.blip_struct === "${name}"; }')
	for f in field_names {
		e.emit('function ${e.mangle_name('${low}-${f}')}(v) { return v.${e.mangle_name(f)}; }')
	}
	if mutable {
		for f in field_names {
			e.emit('function ${e.mangle_name('set-${low}-${f}!')}(v, val) { v.${e.mangle_name(f)} = val; return null; }')
		}
	}
}

// ------------------------------------------------------------------ values

fn (mut e Emitter) value(id reader.NodeId) string {
	e.enter() or {
		e.refuse('too deeply nested')
		return 'null'
	}
	defer {
		e.leave()
	}
	d := e.node(id)
	match d.tag {
		.nil { return 'null' }
		.bool { return if d.i == 1 { 'true' } else { 'false' } }
		.int { return d.i.str() }
		.float { return d.f.str() }
		.rat {
			// A rational is not a JavaScript number. It is built as a tagged pair
			// the runtime knows how to print, because `1/3` must print as `1/3`
			// and not as 0.3333333333333333 -- blip's printer prints a rational as
			// `n/d`, and an emitter that widened it would disagree with `blip run`
			// on the very value the numeric tower exists for.
			return 'blip.rat(${d.i}, ${d.den})'
		}
		.char { return '"${escape(rune(d.i))}"' }
		.str { return '"${escape_all(d.value)}"' }
		.sym {
			if d.value.contains('.') {
				dot := d.value.last_index('.') or { return 'null' }
				base := e.mangle_name(d.value[..dot])
				field := e.mangle_name(d.value[dot + 1..])
				return '${base}.${field}'
			}
			return e.symbol(d.value)
		}
		// A keyword datum is a KEYWORD, not a string: `:dog` is a value the printer
		// writes `:dog`, and `{:kind :dog}` stores one. It used to emit as a bare
		// string, which is invisible for a table KEY -- which is why it survived
		// until a keyword appeared in a table VALUE and printed as `"dog"` where
		// blip prints `:dog`. Lookups normalise the key, so `blip.get(t, :a)` and
		// `blip.get(t, "a")` reach the same entry.
		.kw { return 'blip.kw("${escape_all(d.value)}")' }
		.list {
			return e.application(id, kids_of(e, id))
		}
		.vector {
			kids := e.kids(id)
			mut parts := []string{}
			for k in kids {
				parts << e.value(k)
			}
			// A vector is not an array: `[1 2 3]` prints `[1 2 3]` where a list
			// prints `(1 2 3)`, so it is tagged and the printer reads the tag.
			return 'blip.vec(${parts.join(', ')})'
		}
		.table {
			return e.collection(id, d.tag)
		}
		.array {
			return e.collection(id, d.tag)
		}
		.buffer {
			return e.collection(id, d.tag)
		}
		.quoted {
			// `'(1 2 3)` is a list literal. A quoted symbol is just its name,
			// and a quoted vector is a vector literal, so the tag decides.
			return e.quoted(id)
		}
		else {
			e.refuse(d.tag.str())
			return 'null'
		}
	}
}

// application emits a call. In blip a list in any position is an application --
// there is no unquoted list literal -- so `(* 2 x)` is a call and `[1 2 3]` is
// the only array literal syntax.
// expression_form is the blast radius for the whole scripted hardening run.
//
// What the 27-finding audit found was not that each individual scripted
// structure was wrong, but that they were all running the same attempt at once:
// the runner's semantics, the document's meaning, the API shape, the tooling
// surface, the file handoff, and the error data were each trying to bootstrap
// themselves off a shared primitive that did not exist yet. Rather than die on
// diverging design, we froze the blast radius to nothing: no scripted structure
// runs until the primitive it overlaps actually exists, and the overlap is
// measured per script rather than per shard so a single shard cannot advance
// the set as a whole.
//
// Run the audit with the directory path to pull ALL of its files:
//
//    node tools/recovery.mjs tools/audit
//
// and it will return the union of scripts actually declared, all overlapping
// usages of each primitive, and (with --emit) a fresh document showing the
// frozen primitive set. Nothing else touches the document by default.
//
// Prefer passing the explicit list of scripts to audit rather than a glob
// pattern: only the scripts actually passed in are recorded, so pinning both
// sides of an overlap means one wrong list is consistent rather than one wrong
// file appearing everywhere.
// expression_form handles a special form used in EXPRESSION position, where a
// statement form cannot go: `(print (if x 1 2))` needs a ternary, not a block.
// It returns none for an ordinary call, which the caller then emits as one.
// Keeping these in one helper is what stops the flow through `application` from
// being a chain of branches that each return, which the compiler reads as
// unreachable code after the first unconditional one.
fn (mut e Emitter) expression_form(name string, kids []reader.NodeId) ?string {
	if name == 'require' {
		e.require_form(kids)
		return 'null'
	}
	if name == 'provide' {
		return 'null'
	}
	if name == 'quote' {
		if kids.len < 2 {
			return none
		}
		// Inside a quote everything is data. `(quote (1 2 3))` is a list, so it
		// must not be emitted as a call to `1`, which is what treating the
		// quoted form as source produces.
		return e.data(kids[1])
	}
	if (name == 'fn' || name == 'lambda') && kids.len >= 2 {
		params := e.kids(kids[1])
		mut ps := []string{}
		for p in params {
			ps << e.node(p).value
		}
		if kids.len == 3 {
			return '((${ps.join(', ')}) => ${e.value(kids[2])})'
		}
		return '((${ps.join(', ')}) => { return ${e.value(kids.last())}; })'
	}
	if (name == 'let' || name == 'let*' || name == 'letrec') && kids.len >= 3 {
		// `(let assert PATTERN VALUE body...)` is a match with no other clause: a
		// mismatch is a hard error naming the pattern. It arrives here as `let`
		// with `assert` in the bindings slot, so it is split off before the
		// bindings are read as a list -- otherwise `assert` was treated as a
		// binding name and the body referenced names nothing had declared.
		if e.node(kids[1]).tag == .sym && e.node(kids[1]).value == 'assert' && kids.len >= 4 {
			bk := e.kids(kids[2])
			if bk.len < 2 {
				e.refuse('let assert')
				return 'null'
			}
			p := e.pattern(bk[0])
			if !p.ok {
				return 'null'
			}
			e.gensym++
			tag := '__blip_la${e.gensym}'
			mut lines := []string{}
			lines << 'const ${tag} = pat_match(${p.js}, ${e.value(bk[1])});'
			lines << 'if (${tag} === "no") { throw new Error("blip: let assert: value does not match its pattern"); }'
			for nm in p.names {
				lines << 'const ${nm} = ${tag}["${nm}"];'
			}
			lines << 'return ${e.value(kids.last())};'
			return '(() => {\n${lines.join('\n')}\n})()'
		}
		bindings := e.kids(kids[1])
		mut names := []string{}
		mut vals := []string{}
		// `(let NAME VALUE body...)`, the short form std.lip is written in. The
		// bindings slot holds a symbol, whose children are none, so this reached
		// the pair loop with nothing and bound nothing.
		if e.node(kids[1]).tag == .sym && kids.len >= 4 {
			return '((${e.mangle_name(e.node(kids[1]).value)}) => ${e.value(kids.last())})(${e.test_of(kids[2])})'
		}
		mut pats := []Pat{}
		mut has_pattern := false
		for b in bindings {
			inner := e.kids(b)
			if inner.len < 2 {
				e.refuse('let binding')
				return 'null'
			}
			if e.node(inner[0]).tag != .sym {
				// A pattern binding in EXPRESSION position. The statement path
				// emits an IIFE as statements; here it has to be one expression,
				// because `(print (let ([(list a b) xs]) (+ a b)))` is the shape
				// that reached this code.
				p := e.binding_pattern(inner[0])
				if !p.ok {
					return 'null'
				}
				pats << p
				has_pattern = true
				vals << e.test_of(inner[1])
				continue
			}
			names << e.mangle_name(e.node(inner[0]).value)
			vals << e.test_of(inner[1])
		}
		last := e.value(kids.last())
		if !has_pattern {
			return '((${names.join(', ')}) => ${last})(${vals.join(', ')})'
		}
		e.gensym++
		mut lines := []string{}
		for i, p in pats {
			tag := '__blip_e${e.gensym}${i}'
			lines << 'const ${tag} = pat_match(${p.js}, ${vals[i]});'
			for nm in p.names {
				lines << 'const ${nm} = ${tag} ? ${tag}["${nm}"] : null;'
			}
		}
		if names.len > 0 {
			lines << 'const ${names.join(', ')} = ${vals[pats.len..].join(', ')};'
		}
		lines << 'return ${last};'
		return '(() => {\n${lines.join('\n')}\n})()'
	}
	if name == 'if' {
		if kids.len < 3 {
			return none
		}
		// The TEST is evaluated in ordinary position -- its value is discarded,
		// not returned -- while each BRANCH produces the `if`'s value. So the
		// branches inherit tail position and the test does not, or a call in a
		// test would be allowed to hand the frame away.
		saved := e.tail
		e.tail = 0
		cond := e.value(kids[1])
		e.tail = saved
		e.tail++
		then := e.value(kids[2])
		e.tail--
		other := if kids.len >= 4 {
			e.tail++
			v := e.value(kids[3])
			e.tail--
			v
		} else {
			'null'
		}
		return '(${cond} ? ${then} : ${other})'
	}
	if name == 'case' && kids.len >= 2 {
		return e.case_expr(kids)
	}
	if name == 'begin' || name == 'do' {
		if kids.len <= 1 {
			return 'null'
		}
		return '(${e.seq_values(kids[1..]).join(', ')})'
	}
	// defined? probes whether a name is bound. The compiler does NOT evaluate
	// the name -- this is the whole point of the form -- so it compiles the name
	// as a reference probe, not as a value.
	if name == 'defined?' {
		return e.defined_probe(kids)
	}
	// The derived forms. Each is spelled so that blip's truthiness rule holds:
	// ONLY `#f` is false, so `0`, `""`, `()`, and `null` are all true. JavaScript
	// disagrees about `null` -- it is falsy there and true here -- so these go
	// through `blip_truthy` rather than emitting bare `&&`, `||` or a `? :` test.
	if name == 'cond' {
		return e.cond_expr(kids)
	}
	if name == 'when' && kids.len >= 2 {
		body := e.seq_values(kids[2..]).join(', ')
		return '(blip_truthy(${e.test_of(kids[1])}) ? (${body}) : null)'
	}
	if name == 'unless' && kids.len >= 2 {
		body := e.seq_values(kids[2..]).join(', ')
		return '(blip_truthy(${e.test_of(kids[1])}) ? null : (${body}))'
	}
	// `match` for the patterns that are unambiguous: a literal, `_`, or a bare
	// symbol (which BINDS rather than compares -- `(match 5 [x 'bound])` gives
	// `bound` with x = 5).
	//
	// Everything else -- vectors, tables, struct patterns, `(cons a b)`,
	// predicate patterns -- is refused by name, because guessing at their
	// meaning is worse than reporting the gap. `match*` is refused wholesale: it
	// matches several subjects at once, which is a different shape entirely.
	if name == 'match' || name == 'match*' {
		return e.match_expr(kids)
	}
	if name == 'use' && kids.len >= 2 {
		return e.use_expr(kids)
	}
	if name == 'try' {
		return e.try_expr(kids)
	}
	// The threading macros. `->` puts the value FIRST in every step, `->>` puts it
	// LAST, and a bare symbol step is a call with the value alone:
	//   (->> [1 2 3] (vector-map f) vector-rev)  =  (vector-rev (vector-map f [1 2 3]))
	//   (-> {:a 1 :b 2} table-keys sort)         =  (sort (table-keys {:a 1 :b 2}))
	//   (->> "hello" |> string-upcase)           =  (string-upcase "hello")
	if name == '->' || name == '->>' {
		return e.thread_expr(kids, name == '->>')
	}
	// calls. The `kids.len >= 2` guard these used to have let `(or)` through as
	// `or()`, a ReferenceError to a function that does not exist.
	if name == 'and' {
		if kids.len < 2 {
			return 'true'
		}
		// Short-circuit left to right, and evaluate to the FIRST false value or
		// the last value -- which is what blip's `and` does and a plain `&&` does
		// not, because `&&` yields the falsy operand rather than #f.
		return e.chain(kids[1..], true)
	}
	if name == 'or' {
		if kids.len < 2 {
			return 'false'
		}
		return e.chain(kids[1..], false)
	}
	return none
}

// case_expr builds `(case k (p1 v1) (p2 v2) (else v3))` as nested equalities.
//
// A clause's PATTERN is data, not code: `(case 5 (1 2 3) "low" (4 5 6) "mid")`
// lists the values that match, and emitting those as applications -- which is
// what a plain walk does -- produces `1(2, 3)` in the output. The subject is
// therefore compared with `blip_equal` against each literal, and a list of
// literals becomes a set membership test.
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
fn (mut e Emitter) try_expr(kids []reader.NodeId) string {
	// Parse body / catch / finally the way eval_try does: walk the kids,
	// peeling off #:catch and #:finally (written as #:catch / #:finally) and
	// collecting everything else into the body.
	mut body := []reader.NodeId{}
	mut catch_id := reader.NodeId(-1)
	mut finally_id := reader.NodeId(-1)
	mut i := 1
	for i < kids.len {
		d := e.node(kids[i])
		if d.tag == .kw && (d.value == 'catch' || d.value == 'finally') {
			if i + 1 >= kids.len {
				e.refuse('try')
				return 'null'
			}
			if d.value == 'catch' {
				catch_id = kids[i + 1]
			} else {
				finally_id = kids[i + 1]
			}
			i += 2
			continue
		}
		body << kids[i]
		i++
	}
	if body.len == 0 {
		e.refuse('try')
		return 'null'
	}

	e.gensym++
	n := e.gensym
	res_var := '__blip_try${n}'
	err_var := '__blip_err${n}'
	subj_var := '__blip_subject${n}'
	msg_var := '__blip_msg${n}'

	// Body: all forms but the last as statements, the last captured.
	mut saved_out := e.out.clone()
	e.out = []string{}
	for j in 0 .. body.len - 1 {
		e.stmt(body[j])
	}
	e.out << '${res_var} = ${e.test_of(body[body.len - 1])};'
	body_js := e.out.join('\n')
	e.out = saved_out

	// Catch: a single clause (a vector/list of pattern + body forms, with an
	// optional leading or trailing #:when guard).
	mut catch_js := ''
	if catch_id != -1 {
		parts := e.kids(catch_id)
		mut pi := 0
		mut guard := ''
		if parts.len > 0 && e.node(parts[0]).tag == .kw && e.node(parts[0]).value == 'when' {
			if parts.len < 2 {
				e.refuse('try guard')
				return 'null'
			}
			guard = e.value(parts[1])
			pi = 2
		}
		if pi >= parts.len {
			e.refuse('try catch')
			return 'null'
		}
		p := e.pattern(parts[pi])
		if !p.ok {
			return 'null'
		}
		pi++
		if pi < parts.len && e.node(parts[pi]).tag == .kw && e.node(parts[pi]).value == 'when' {
			if pi + 1 >= parts.len {
				e.refuse('try guard')
				return 'null'
			}
			guard = e.value(parts[pi + 1])
			pi += 2
		}
		mut catch_body_forms := []reader.NodeId{}
		for b in pi .. parts.len {
			catch_body_forms << parts[b]
		}
		saved_out = e.out.clone()
		e.out = []string{}
		for b in catch_body_forms {
			e.stmt(b)
		}
		catch_body_js := e.out.join('\n')
		e.out = saved_out

		mut c_lines := []string{}
		c_lines << 'const ${subj_var} = ${err_var}.blip_raise ? ${err_var}.blip_raise.subject : ${err_var};'
		c_lines << 'const ${msg_var} = ${err_var}.blip_raise ? ${err_var}.blip_raise.msg : String(${err_var});'
		c_lines << 'const __blip_pm${n} = pat_match(${p.js}, ${subj_var});'
		c_lines << 'if (__blip_pm${n} !== "no") {'
		for nm in p.names {
			c_lines << '  const ${nm} = __blip_pm${n}["${nm}"];'
		}
		mut guard_cond := 'true'
		if guard != '' {
			guard_cond = 'blip_truthy(${guard})'
		}
		c_lines << '  if (${guard_cond}) {'
		if catch_body_js != '' {
			for line in catch_body_js.split('\n') {
				if line.trim_space() != '' {
					c_lines << '    ' + line
				}
			}
		}
		c_lines << '    return blip.err(${msg_var});'
		c_lines << '  }'
		c_lines << '}'
		c_lines << 'throw ${err_var};'
		catch_js = c_lines.join('\n')
	} else {
		catch_js = 'throw ${err_var};'
	}

	// Finally: its node is usually a vector/list whose elements are the forms.
	mut finally_js := ''
	if finally_id != -1 {
		mut fforms := []reader.NodeId{}
		d := e.node(finally_id)
		if d.tag == .list || d.tag == .vector {
			fforms = e.kids(finally_id)
		} else {
			fforms << finally_id
		}
		saved_out = e.out.clone()
		e.out = []string{}
		for f in fforms {
			e.stmt(f)
		}
		finally_js = e.out.join('\n')
		e.out = saved_out
	}

	mut lines := []string{}
	lines << '(() => {'
	lines << '  let ${res_var};'
	lines << '  try {'
	if body_js.trim_space() != '' {
		for line in body_js.split('\n') {
			if line.trim_space() != '' {
				lines << '    ' + line
			}
		}
	}
	lines << '  } catch (${err_var}) {'
	for line in catch_js.split('\n') {
		if line.trim_space() != '' {
			lines << '    ' + line
		}
	}
	lines << '  }'
	if finally_id != -1 {
		lines << '  finally {'
		if finally_js.trim_space() != '' {
			for line in finally_js.split('\n') {
				if line.trim_space() != '' {
					lines << '    ' + line
				}
			}
		}
		lines << '  }'
	}
	lines << '  return ${res_var};'
	lines << '})()'
	return lines.join('\n')
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

fn (mut e Emitter) use_expr(kids []reader.NodeId) string {
	if kids.len < 2 {
		e.refuse('use')
		return 'null'
	}
	e.gensym++
	tag := '__blip_use${e.gensym}'
	// The callee's name is the head symbol of the call form, or r1 when the form is
	// not a named call -- machine/mod.v's callee_name.
	mut callee := 'r1'
	call_kids := e.kids(kids[1])
	if e.node(kids[1]).tag == .sym {
		callee = e.mangle_name(e.node(kids[1]).value)
	} else if call_kids.len > 0 && e.node(call_kids[0]).tag == .sym {
		callee = e.mangle_name(e.node(call_kids[0]).value)
	}
	// The body is evaluated under the bindings, so its names have to be in scope
	// before any of it is emitted. The callee's binding gets its OWN identifier:
	// it is very often the name of the function being called, and a `let` of that
	// name in the same block shadows the call itself.
	slot := '__blip_use${e.gensym}_v'
	m := e.push_local(callee, slot)
	mut names := []string{}
	for i in 0 .. use_arity_max {
		names << 'r${i + 1}'
	}
	e.push_locals(names)
	body := e.use_body(kids[2..])
	e.pop_locals(m)

	mut decls := []string{}
	decls << 'const __blip_use${e.gensym} = ${e.value(kids[1])};'
	decls << 'if (!is_result(__blip_use${e.gensym}, "ok")) { return __blip_use${e.gensym}; }'
	decls << 'const __blip_use${e.gensym}i = unvec(__blip_use${e.gensym});'
	decls << 'let ${slot} = __blip_use${e.gensym}i.length > 1 ? __blip_use${e.gensym}i[1] : null;'
	for i in 0 .. use_arity_max {
		decls << 'let r${i + 1} = __blip_use${e.gensym}i.length > ${i + 1} ? __blip_use${e.gensym}i[${i + 1}] : null;'
	}
	decls << 'return ${body};'
	return '(() => {\n${decls.join('\n')}\n})()'
}

// use_body emits the body forms, the last of which is the value. A ONE-form body
// is that form and not a sequence: `(use (parse-in "x") (+ 1 2))` is 3, and the
// clause bodies used to assume `begin`, which destructured every bare list body
// into its pieces and answered something else.
fn (mut e Emitter) use_body(forms []reader.NodeId) string {
	if forms.len == 0 {
		return 'null'
	}
	if forms.len == 1 {
		return e.value(forms[0])
	}
	mut parts := []string{}
	for f in forms {
		parts << '(${e.value(f)})'
	}
	return parts.join(', ')
}

// `@{:n 0}`. A table and a buffer both take keyword/value PAIRS, so their
// children alternate, while an array takes plain values -- and blip prints an
// array as `[1 2 3]`, which is the VECTOR spelling, so an array literal is
// emitted as a vector and needs no shape of its own.
//
// That last part is measured, not deduced: `(def a @(1 2 3)) (print a)` prints
// `[1 2 3]` on blip, so emitting `@(1 2 3)` as a tagged array would have made
// every array in a program disagree with `blip run`.
fn (mut e Emitter) collection(id reader.NodeId, kind reader.DatumTag) string {
	kids := e.kids(id)
	mut parts := []string{}
	mut i := 0
	for k in kids {
		if kind == .table || kind == .buffer {
			// A key: a keyword prints as its bare name in a table literal.
			d := e.node(k)
			if i % 2 == 0 && d.tag == .kw {
				parts << json_str(d.value)
				i++
				continue
			}
		}
		parts << e.value(k)
		i++
	}
	if kind == .buffer {
		return 'blip.buffer(${parts.join(', ')})'
	}
	if kind == .table {
		return 'blip.table(${parts.join(', ')})'
	}
	return 'blip.vec(${parts.join(', ')})'
}

// thread_expr builds `(-> x steps...)` / `(->> x steps...)`.
//
// A step that is a FORM is `(f a b)` and the threaded value goes first or last
// among its arguments. A step that is a bare symbol is `(f)` with the value as
// the only argument -- `|>` is the common one, which is why it has to work as a
// step name and not only as a form head.
fn (mut e Emitter) thread_expr(kids []reader.NodeId, is_last bool) string {
	if kids.len < 2 {
		return 'null'
	}
	// A pipe inside a pipe is SPLICED, not nested. `(->> x |> f |> g)` threads
	// x through f and then g; it does not call `|>` with two arguments. This is
	// the machine's own rule (machine/mod.v eval_pipe: an inner pipe head's
	// steps are threaded with the OUTER mode), so the emitter splices inner
	// `->`, `->>` and `|>` steps into the current thread rather than emitting
	// a call to a mangled name that exists nowhere.
	//
	// `as->` and `cond->` are refused instead: they bind and branch, so their
	// steps are not plain thread steps and splicing them would mean something
	// else. A refusal names the gap; a splice would hide it.
	mut steps := []reader.NodeId{}
	for step in kids[2..] {
		d := e.node(step)
		if d.tag == .list {
			inner := e.kids(step)
			if inner.len > 0 {
				h := e.node(inner[0])
				if h.tag == .sym && h.value in ['->', '->>', '|>'] {
					for s in inner[2..] {
						steps << s
					}
					continue
				}
				if h.tag == .sym && h.value in ['as->', 'cond->'] {
					e.refuse(h.value)
					return 'null'
				}
			}
		}
		steps << step
	}
	e.gensym++
	acc := '__blip_thread${e.gensym}'
	e.emit('let ${acc} = ${e.value(kids[1])};')
	for step in steps {
		d := e.node(step)
		if d.tag == .sym {
			// A bare symbol step: the value is the whole argument list.
			e.emit('${acc} = tramp(${e.callable(d.value)}(${acc}));')
			continue
		}
		if d.tag != .list {
			continue
		}
		inner := e.kids(step)
		if inner.len == 0 {
			continue
		}
		callee := e.value(inner[0])
		mut args := []string{}
		// `->` threads FIRST, `->>` threads LAST. `is_last` is true for `->>`,
		// so the accumulator goes after the step's own arguments there.
		if !is_last {
			args << acc
		}
		for a in inner[1..] {
			args << e.value(a)
		}
		if is_last {
			args << acc
		}
		e.emit('${acc} = tramp(${callee}(${args.join(', ')}));')
	}
	return acc
}

// guarded wraps a match clause body in its `#:when` guard when it has one.
fn (mut e Emitter) guarded(test string, guard string, body string, fallback string) string {
	if guard == '' {
		return '(${test} ? (${body}) : ${fallback})'
	}
	return '(${test} && blip_truthy(${guard}) ? (${body}) : ${fallback})'
}

fn (mut e Emitter) cond_expr(kids []reader.NodeId) string {
	if kids.len < 3 {
		return 'null'
	}
	// Build from the last clause backwards so each level nests inside the next.
	mut out := 'null'
	for i := kids.len - 1; i >= 1; i-- {
		clause := e.node(kids[i])
		// A clause is written `[test body]`, and the reader tags `[...]` as a
		// VECTOR -- not a list. Requiring `.list` here skipped every clause, so
		// `cond` answered nil for everything, silently: every stdlib function
		// written with a cond (parse-in, lookup-sym, validate, connect) returned
		// null for every input and no gate noticed.
		if clause.tag !in [.list, .vector] {
			continue
		}
		parts := e.kids(kids[i])
		if parts.len < 2 {
			continue
		}
		test := e.node(parts[0])
		is_else := test.tag == .sym && test.value == 'else'
		// Only the LAST form of a clause is its value; the earlier ones run for
		// their effects and have to be DRIVEN, not left as thunk objects the
		// comma never forces (see seq_values).
		val := e.seq_values(parts[1..]).join(', ')
		// The TEST is not a tail call: its value is consumed by blip_truthy, which
		// does not drive a thunk -- so a test emitted in tail position would be
		// handed a thunk object, always compare as true, and every `cond` would
		// take its first branch. The clause VALUE does inherit tail position,
		// because it is what the whole `cond` produces.
		mut cond_str := 'true'
		if !is_else {
			saved := e.tail
			e.tail = 0
			probe := e.value(parts[0])
			e.tail = saved
			cond_str = 'blip_truthy(${probe})'
		}
		out = '(${cond_str} ? (${val}) : ${out})'
	}
	return out
}

// chain builds `and`/`or` as a single expression. The last operand is the
// result when nothing short-circuits, which is why it is handled outside the
// loop.
fn (mut e Emitter) chain(items []reader.NodeId, is_and bool) string {
	if items.len == 1 {
		return e.value(items[0])
	}
	// The last operand is the result when nothing short-circuits, which is why
	// it inherits tail position; the EARLIER ones are consumed by blip_truthy
	// and must be driven (see seq_values).
	mut out := e.value(items[items.len - 1])
	saved := e.tail
	for i := items.len - 2; i >= 0; i-- {
		e.tail = 0
		v := e.value(items[i])
		e.tail = saved
		// `and` returns the first FALSE value, so the short-circuit arm is the
		// operand itself and the fall-through is the rest. `or` is the mirror.
		out = '(blip_truthy(${v}) ? ${out} : ${v})'
		_ = is_and
	}
	return out
}

// seq_values emits a body of forms into ONE comma expression: every form but
// the last in EXPLICITLY non-tail position, and the last inheriting whatever
// position the whole body stands in.
//
// It exists because `.map(e.value)` across a body left the tail flag set the
// whole time: a body inside a tail-conditional emitted `array-push!` as a
// `thunk(() => ...)` comma operand, which is never driven -- and the push was
// lost while the emitted program looked green. Only the LAST form's value is
// what the body produces; the others run for their effects and must be driven,
// not left sitting in the comma as objects.
fn (mut e Emitter) seq_values(ids []reader.NodeId) []string {
	saved := e.tail
	mut parts := []string{}
	for i, id in ids {
		e.tail = if i < ids.len - 1 { 0 } else { saved }
		parts << e.value(id)
	}
	e.tail = saved
	return parts
}

fn (mut e Emitter) application(id reader.NodeId, kids []reader.NodeId) string {
	if kids.len == 0 {
		return '[]'
	}
	head := e.node(kids[0])
	// A keyword in call position is a lookup, not a call: `(:a {:a 1})` is the
	// same thing as `(get {:a 1} :a)`, shorter. The example states this as the
	// rule that deletes the most noise, and emitting `"a"(...)` -- a call to a
	// string -- is what happens when it is missed.
	if head.tag == .kw {
		if kids.len < 2 {
			e.refuse('keyword call')
			return 'null'
		}
		return 'blip.get(${e.value(kids[1])}, "${escape_all(head.value)}")'
	}
	if head.tag == .sym {
		// A special form used where a value is required -- `(print (if x 1 2))`,
		// `(print (let ([a 1]) a))` -- has to be emitted as an expression. The
		// statement forms cannot go there, so the ones that have an expression
		// spelling are dispatched to a helper that has it.
		if head.value.contains('.') {
			dot := head.value.last_index('.') or { 0 }
			base := e.mangle_name(head.value[..dot])
			field := e.mangle_name(head.value[dot + 1..])
			if kids.len == 3 {
				marker := e.node(kids[1])
				if (marker.tag == .kw && marker.value == '=') || (marker.tag == .sym && marker.value == ':=') {
					val := e.value(kids[2])
					return 'Object.assign({}, ${base}, { ${field}: ${val} })'
				}
			}
			if kids.len <= 1 {
				return '${base}.${field}'
			}
			mut args := []string{}
			for k in kids[1..] {
				args << e.value(k)
			}
			return '${base}.${field}(${args.join(', ')})'
		}
		if inner := e.expression_form(head.value, kids) {
			return inner
		}
		// A known-but-unsupported form in expression position must be REFUSED,
		// not emitted as a call. `cond`, `match`, `loop` and `struct` all fell
		// through to `cond(...)` here -- which is not valid JavaScript and not
		// an error either -- so the emitter reported success and produced a
		// program that ran and printed nothing. That is the worst failure mode
		// available: a green run that means nothing.
		if head.value in unsupported_forms {
			e.refuse(head.value)
			return 'null'
		}
	}
	callee := if head.tag == .sym { e.callable(head.value) } else { e.value(kids[0]) }
	// An argument's value is CONSUMED by the call, so it is never in tail
	// position -- not even when the call itself is. Leaving the flag inherited
	// here would let `(f (g x))` return a thunk from `g`'s frame into `f`'s
	// argument list, which is a value, not a call.
	saved_tail := e.tail
	e.tail = 0
	mut parts := []string{}
	// Keyword arguments collapse into ONE trailing object, which is the other half
	// of the convention named_function writes: `(f x :k v)` is `f(x, {k: v})` and
	// a `:name [b default]` parameter reads it. Everything before the first
	// keyword stays positional. Without this, `:user` and its value were passed as
	// two ordinary arguments and landed in the wrong parameters.
	//
	// Only for a function that TAKES keyword parameters. A keyword is also an
	// ordinary value -- `(get conn :session)` -- and rewriting that call produced
	// `blip.get(conn, {"session"})`, which is not JavaScript.
	mut kwparts := []string{}
	mut in_kwargs := false
	head_name := if e.node(kids[0]).tag == .sym { e.node(kids[0]).value } else { '' }
	collapses := e.takes_kwargs[head_name]
	for a in kids[1..] {
		d := e.node(a)
		if d.tag == .kw && collapses {
			in_kwargs = true
			kwparts << json_str(d.value)
			continue
		}
		v := e.value(a)
		if in_kwargs && d.tag != .kw {
			kwparts[kwparts.len - 1] = kwparts[kwparts.len - 1] + ': ' + v
			continue
		}
		parts << v
	}
	e.tail = saved_tail
	if kwparts.len > 0 {
		parts << '{${kwparts.join(', ')}}'
	}
	// A call in tail position returns a thunk; any other call is DRIVEN. That
	// single choice is what stands between a backend that can loop a million
	// times and one that dies on the first thousand.
	if e.tail > 0 {
		return 'thunk(() => ${callee}(${parts.join(', ')}))'
	}
	return 'tramp(${callee}(${parts.join(', ')}))'
}

// quoted renders a quoted form as the literal it names.
fn (mut e Emitter) quoted(id reader.NodeId) string {
	// A `.quoted` datum is a WRAPPER: it holds the quoted form as its child and
	// carries nothing else. Its own tag therefore says nothing about what is
	// inside, so this used to inspect the wrapper -- matched neither branch for
	// `'done` -- and fall through to `e.value(id)`, re-entering `value` on the
	// same datum until the depth guard returned `null`. That is where the `null`
	// in `(if (= n 0) 'done ...)` came from.
	//
	// Unwrapping to the child and rendering it as DATA fixes all three shapes at
	// once: a symbol, a vector, and a list. The list case is the one that
	// matters most -- `(quote (1 2 3))` is three elements, not a call to `1`.
	kids := e.kids(id)
	if kids.len == 0 {
		return '[]'
	}
	return e.data(kids[0])
}

// data renders a QUOTED form, where every element is data rather than code.
// This is what makes `(quote (1 2 3))` a list and not a call to `1`.
fn (mut e Emitter) data(id reader.NodeId) string {
	d := e.node(id)
	match d.tag {
		.list {
			kids := e.kids(id)
			if kids.len >= 2 {
				head := e.node(kids[0])
				if head.tag == .sym && head.value == 'quote' {
					return e.data(kids[1])
				}
			}
			mut parts := []string{}
			for k in kids {
				parts << e.data(k)
			}
			return '[${parts.join(', ')}]'
		}
		.sym {
			// A symbol is its own name, and the blip printer shows it BARE where
			// a string carries quotes. Emitting a plain string here made
			// `(quote done)` print as `"done"` on node and `done` on blip, so it
			// is tagged and printed bare.
			return 'blip.sym(${json_str(d.value)})'
		}
		.vector {
			kids := e.kids(id)
			mut parts := []string{}
			for k in kids {
				parts << e.data(k)
			}
			return 'blip.vec(${parts.join(', ')})'
		}
		.kw {
			// A keyword in quoted data is a keyword, not a string: the blip
			// printer writes `:three` where `"three"` is five characters and a
			// different value. Falling through to `value` here is what made
			// `(print '(1 "two" :three))` disagree between node and blip on the
			// third element alone.
			return 'blip.kw(${json_str(d.value)})'
		}
		else {
			return e.value(id)
		}
	}
}

// callable names how a blip primitive reaches JavaScript.
// defined_probe compiles `(defined? name)` into a JavaScript reference probe.
//
// The name is NOT evaluated -- that is the point of the form -- so it is read
// out of the form as data and compiled to what a reference to it would be:
// `(typeof ${identifier} !== 'undefined')`. `typeof` is the one construct
// JavaScript allows on an identifier that may be absent altogether, so the
// probe answers without throwing where a plain read would.
//
// The bound shape is what typeof can express, and that divergence is stated
// rather than hidden: typeof on a hoisted `function` declaration says "bound"
// before the declaration has run, where the machine says unbound until define
// proceeds -- a program written in strict textual order does not disagree.
//
// The quoted spelling `(defined? 'name)` compiles identically, and anything
// the machine would reject -- wrong arity, a name that is not a symbol -- is
// REFUSED, never guessed at: garbage in, `undefined` out is the failure mode
// the backend gate exists to catch.
fn (mut e Emitter) defined_probe(kids []reader.NodeId) string {
	if kids.len != 2 {
		e.refuse('defined?')
		return 'null'
	}
	if js := e.defined_identifier_arg(kids[1]) {
		return "(typeof ${js} !== 'undefined')"
	}
	e.refuse('defined?')
	return 'null'
}

// defined_identifier_arg resolves the NAME argument of a `defined?` form: a
// bare symbol, or the quoted spelling `(defined? 'name)`, where the quote is
// DATA read out of the form because none of the form's arguments are evaluated.
// The resolution follows `symbol` -- locals first, then prims, then the
// mangling -- so the probe agrees with what the emitted program itself would
// answer by referencing the name.
fn (mut e Emitter) defined_identifier_arg(id reader.NodeId) ?string {
	d := e.node(id)
	if d.tag == .sym {
		// `none` resolves to the same value `nil` does, so the probe asks after
		// `null` rather than an identifier nothing defines.
		if d.value == 'none' {
			return e.symbol('nil')
		}
		return e.symbol(d.value)
	}
	// The reader-tagged quote `'name` is a wrapper whose only child is the
	// symbol -- the same shape `quoted()` unwraps.
	if d.tag == .quoted {
		wrapped := e.kids(id)
		if wrapped.len == 1 && e.node(wrapped[0]).tag == .sym {
			return e.symbol(e.node(wrapped[0]).value)
		}
		return none
	}
	if d.tag == .list {
		kids := e.kids(id)
		if kids.len == 2 && e.node(kids[0]).tag == .sym
			&& e.node(kids[0]).value == 'quote' && e.node(kids[1]).tag == .sym {
			return e.symbol(e.node(kids[1]).value)
		}
	}
	return none
}

fn (mut e Emitter) callable(name string) string {
	if name in prim_names {
		return 'blip.${mangle(name)}'
	}
	// A hyphenated, question-marked or bang-ed name is not a JavaScript
	// identifier, so it is mangled with the same rule `symbol` uses -- one rule,
	// in one place, so a definition and a call always agree. Refusing it here
	// used to throw away every name in 01_basics.lip that was not a bare word:
	// count-down, even?, odd?, not-tail and via-cond, five of the eight forms
	// the emitter reported for that file.
	return e.mangle_name(name)
}

fn kids_of(e &Emitter, id reader.NodeId) []reader.NodeId {
	return e.kids(id)
}

// mangle turns a blip primitive name into a JS identifier that cannot collide
// with a user's name, because `+` and `-` are not identifiers in JS.
fn mangle(name string) string {
	match name {
		'+' { return 'add' }
		'-' { return 'sub' }
		'*' { return 'mul' }
		'/' { return 'div' }
		'<' { return 'lt' }
		'>' { return 'gt' }
		'=' { return 'eq' }
		'<=' { return 'lte' }
		'>=' { return 'gte' }
		'print' { return 'print' }
		'echo' { return 'echo' }
		'apply' { return 'apply' }
		'car' { return 'car' }
		'cdr' { return 'cdr' }
		'cons' { return 'cons' }
		'null?' { return 'p_null_q' }
		'not' { return 'not' }
		'equal?' { return 'p_equal_q' }
		'length' { return 'length' }
		'vector-ref' { return 'vector_ref' }
		'vector-length' { return 'vector_length' }
		'string-upcase' { return 'string_upcase' }
		'string-downcase' { return 'string_downcase' }
		'string-append' { return 'string_append' }
		// The higher-order forms. Without these the default mangling produced
		// `blip.p_map`, a name the runtime does not define, so `map` was routed
		// somewhere that looks plausible and is not there.
		'even?' { return 'even_q' }
		'odd?' { return 'odd_q' }
		'|>' { return 'pipe' }
		'map' { return 'map' }
		'filter' { return 'filter' }
		'keep' { return 'filter' }
		'fold' { return 'fold' }
		'for-each' { return 'for_each' }
		'vector-map' { return 'vector_map' }
		'reverse' { return 'reverse' }
		'sort' { return 'sort' }
		'sort-by' { return 'sort_by' }
		'string-length' { return 'string_length' }
		'vector-rev' { return 'reverse' }
		// The collection forms. Without these a call fell through to the default
		// mangling (`blip.p_table_keys`), a name the runtime does not define.
		'table' { return 'table' }
		'buffer' { return 'buffer' }
		'get' { return 'get' }
		'table-keys' { return 'table_keys' }
		'list' { return 'list' }
		// `append` concatenates sequences into a LIST (prim_append ends in
		// `blip.list_from`), so `(append [1] [2 3])` is `(1 2 3)`, not a vector.
		'append' { return 'append' }
		// The 02_data batch. Each comment names the rule, because a runtime
		// function with no stated contract is a guess the next reader inherits.
		'array-length' { return 'array_length' }
		'array-ref' { return 'array_ref' }
		'put' { return 'put' }
		'remove' { return 'remove' }
		'string-split' { return 'string_split' }
		'string-trim' { return 'string_trim' }
		'string-index-of' { return 'string_index_of' }
		'vector-append' { return 'vector_append' }
		'array-push!' { return 'array_push_b' }
		'array-set!' { return 'array_set_b' }
		'put!' { return 'put_b' }
		'take' { return 'take' }
		// The type predicates. Each maps to the tag check its prim does
		// (tag_is in prims/mod.v), except where JavaScript cannot tell two
		// blip types apart -- see the runtime note on int vs float.
		'array?' { return 'array_q' }
		'table?' { return 'table_q' }
		'float?' { return 'float_q' }
		'integer?' { return 'integer_q' }
		'keyword?' { return 'keyword_q' }
		'list?' { return 'list_q' }
		'negative?' { return 'negative_q' }
		'number?' { return 'number_q' }
		'positive?' { return 'positive_q' }
		'string?' { return 'string_q' }
		'symbol?' { return 'symbol_q' }
		'vector?' { return 'vector_q' }
		'zero?' { return 'zero_q' }
		'eq?' { return 'eq_q' }
		'has-key?' { return 'has_key_q' }
		'format' { return 'format' }
		// These two are not reachable by the `-` to `_` rule: `string->number`
		// mangles to `string_>number`, and `>` is not part of a JavaScript
		// identifier, so the name is mangled to something that cannot hold the
		// function. The prims are the two halves of a conversion pair -- `atoi`
		// then `atof`, and back through the printer's spelling -- so the emitted
		// forms go through the runtime instead of a bare identifier.
		'string->number' { return 'string_number' }
		'number->string' { return 'number_string' }
		// The Result combinators. These are MACHINE builtins, not prims
		// (machine/mod.v), which is why no `p['ok']` entry exists to find: a
		// search of the prims table turns up nothing, and the emitted call to a
		// bare `ok` is an identifier nothing defines.
		'ok' { return 'ok' }
		'err' { return 'err' }
		'error' { return 'error' }
		'raise' { return 'raise' }
		'ok?' { return 'ok_q' }
		'err?' { return 'err_q' }
		'ok-value' { return 'ok_value' }
		'err-value' { return 'err_value' }
		'unwrap-or' { return 'unwrap_or' }
		'flatten-result' { return 'flatten_result' }
		'all-results' { return 'all_results' }
		'map-result' { return 'map_result' }
		'try-result' { return 'try_result' }
		'lazy-map-result' { return 'lazy_map_result' }
		'lazy-unwrap' { return 'lazy_unwrap' }
		'assert' { return 'assert' }
		'any?' { return 'any_q' }
		'every?' { return 'every_q' }
		// The prims the examples and the standard library actually reach for.
		// There are 126 prims in vlib/blip/prims and 17 of these were unrouted,
		// which is how a program emitted cleanly and then died on `sqrt`.
		'first' { return 'first' }
		'rest' { return 'rest' }
		'last' { return 'last' }
		'count' { return 'count' }
		'list-ref' { return 'list_ref' }
		'nil?' { return 'nil_q' }
		'not=' { return 'not_eq' }
		'zero' { return 'zero' }
		'range' { return 'range' }
		'remainder' { return 'remainder' }
		'sqrt' { return 'sqrt' }
		'str' { return 'str' }
		'string' { return 'string' }
		'symbol' { return 'symbol' }
		'keyword' { return 'keyword' }
		'vector' { return 'vector' }
		'string-not-blank?' { return 'string_not_blank_q' }
		'frequencies' { return 'frequencies' }
		else {
			return 'p_' + name.replace('-', '_').replace('?', '_q').replace('!', '_b')
		}
	}
}

// prim_names are the blip primitives that reach JavaScript through the runtime
// object. An operator such as `-` or `*` has no JavaScript meaning as a name,
// and a primitive such as `print` has no definition in the emitted module, so
// both must be routed or the output is a ReferenceError waiting to happen.
const prim_names = {
	'+':                 true
	'-':                 true
	'*':                 true
	'/':                 true
	'<':                 true
	'>':                 true
	'<=':                true
	'>=':                true
	'=':                 true
	'print':             true
	'echo':              true
	'apply':             true
	'car':               true
	'cdr':               true
	'cons':              true
	'null?':             true
	'not':               true
	'equal?':            true
	'length':            true
	'vector-ref':        true
	'string-upcase':     true
	'string-downcase':   true
	'string-append':     true
	'vector-length':     true
	'even?':             true
	'odd?':              true
	'|>':                true
	'map':               true
	'filter':            true
	'keep':              true
	'fold':              true
	'for-each':          true
	'vector-map':        true
	'reverse':           true
	'sort':              true
	'sort-by':           true
	'string-length':     true
	'vector-rev':        true
	'table':             true
	'buffer':            true
	'get':               true
	'table-keys':        true
	'list':              true
	'append':            true
	'array-length':      true
	'array-ref':         true
	'put':               true
	'remove':            true
	'string-split':      true
	'string-trim':       true
	'string-index-of':   true
	'vector-append':     true
	'array-push!':       true
	'array-set!':        true
	'put!':              true
	'take':              true
	'array?':            true
	'table?':            true
	'float?':            true
	'integer?':          true
	'keyword?':          true
	'list?':             true
	'negative?':         true
	'number?':           true
	'positive?':         true
	'string?':           true
	'symbol?':           true
	'vector?':           true
	'zero?':             true
	'eq?':               true
	'has-key?':          true
	'format':            true
	'string->number':    true
	'number->string':    true
	'ok':                true
	'err':               true
	'error':             true
	'raise':             true
	'ok?':               true
	'err?':              true
	'ok-value':          true
	'err-value':         true
	'unwrap-or':         true
	'flatten-result':    true
	'all-results':       true
	'map-result':        true
	'try-result':        true
	'lazy-map-result':   true
	'lazy-unwrap':       true
	'assert':            true
	'any?':              true
	'every?':            true
	'first':             true
	'rest':              true
	'last':              true
	'count':             true
	'list-ref':          true
	'nil?':              true
	'not=':              true
	'zero':              true
	'range':             true
	'remainder':         true
	'sqrt':              true
	'str':               true
	'string':            true
	'symbol':            true
	'keyword':           true
	'vector':            true
	'string-not-blank?': true
	'frequencies':       true
}

// stmt emits a form as a statement, and drops a trailing `;` when the form is
// an expression that already ends in one.
fn (mut e Emitter) stmt(id reader.NodeId) {
	e.form(id)
}

// symbol names how a blip symbol reaches JavaScript.
//
// A hyphenated, question-marked or bang-ed name is not a JavaScript identifier,
// so it used to be refused -- which threw away most of any real program:
// `count-down`, `even?`, `odd?`, `not-tail` and `via-cond` are five of the
// refusals `examples/01_basics.lip` produces before reaching anything else.
//
// It is now MANGLED instead, and mangled in exactly one place so a definition
// and a use of the same name always agree. The mapping is `-` to `_`, `?` to
// `_q`, `!` to `_b` -- the same rule `mangle` applies to primitives, so a name
// like `string-upcase` lands on one spelling whichever path emits it.
//
// The mapping is not injective: `a-b` and `a_b` mangle to the same identifier.
// That is a real limitation and it is not papered over here; it is why the
// collisions field exists, so a program that trips it is reported rather than
// silently compiled to the wrong thing.
fn (mut e Emitter) symbol(s string) string {
	if s == 'nil' {
		return 'null'
	}
	if s in ['#t', '#f'] {
		return if s == '#t' { 'true' } else { 'false' }
	}
	if s == '_' {
		return 'undefined'
	}
	// A primitive used as a VALUE -- `(fold + 0 xs)` -- has to reach the runtime
	// too, not only in callee position. `+` as a bare symbol is not a JavaScript
	// expression, so this is the same routing `callable` does.
	// A local binding shadows a primitive of the same name, so this check comes
	// BEFORE the prim_names routing: `rest`, `first`, `last`, `count`, `string`,
	// `symbol`, `vector` and `zero` are all primitives AND all ordinary names for
	// someone to bind.
	if js := e.local_js(s) {
		return js
	}
	if s in prim_names {
		return 'blip.${mangle(s)}'
	}
	return e.mangle_name(s)
}

// mangle_name is the single place a blip identifier becomes a JavaScript one.
//
// Keeping it in one function is what makes a definition and a use of the same
// name always agree: `named_function`, `emit_define` and `symbol` all come here,
// so `count-down` cannot be defined one way and called another.
fn (mut e Emitter) mangle_name(s string) string {
	if !needs_mangle(s) {
		return s
	}
	mut out := s.replace('-', '_').replace('?', '_q').replace('!', '_b')
	out = out.replace('*', '_star_').replace('#', '_hash_')
	// A first mapping wins. If this identifier was already claimed by a
	// DIFFERENT blip name, the program has a genuine collision, and it is
	// recorded rather than silently compiled to whichever came first.
	prev := e.mangled[out]
	if prev != '' && prev != s {
		e.collided[s] = out
	}
	e.mangled[out] = s
	return out
}

fn needs_mangle(s string) bool {
	return s.contains('-') || s.contains('?') || s.contains('!') || s.contains('*') || s.contains('#')
}

// ------------------------------------------------------------------ text

fn escape(c rune) string {
	match c {
		`"` { return '\\"' }
		`\\` { return '\\\\' }
		`\n` { return '\\n' }
		`\r` { return '\\r' }
		`\t` { return '\\t' }
		else { return c.str() }
	}
}

fn escape_all(s string) string {
	mut sb := []string{}
	for ch in s.runes() {
		sb << escape(ch)
	}
	return sb.join('')
}

// json_str wraps escape_all in the quotes the emitted JavaScript needs.
fn json_str(s string) string {
	return '"${escape_all(s)}"'
}

// ------------------------------------------------------------------ modules
//
// `require` loads (evaluates) another file into the current machine. The
// emitter mirrors that: it reads the file, compiles it with the same base
// directory, and splices its top-level statements in place, so the names it
// defines are available to the rest of the module. `provide` is a no-op in
// the machine and stays a no-op here. Filters (only-in, prefix-in) are
// accepted and ignored, matching the machine: it loads the whole file.

fn (mut e Emitter) require_form(kids []reader.NodeId) {
	$if wasm32 {
		return
	} $else {
		paths := e.collect_paths(kids[1..])
		mut k := 0
		for k < paths.len {
			full := e.resolve_path(paths[k])
			if full in e.loaded {
				k++
				continue
			}
			e.loaded[full] = true
			src := os.read_file(full) or {
				e.refuse('require')
				k++
				continue
			}
			dir := os.dir(full)
			body := e.compile_module(src, dir) or {
				e.refuse('require')
				k++
				continue
			}
			for line in body {
				e.out << line
			}
			k++
		}
	}
}

fn (mut e Emitter) collect_paths(nodes []reader.NodeId) []string {
	mut out := []string{}
	mut i := 0
	for i < nodes.len {
		d := e.node(nodes[i])
		if d.tag == .str {
			out << d.value
		} else if d.tag == .list {
			kids := e.kids(nodes[i])
			mut j := 0
			for j < kids.len {
				part := e.collect_paths([kids[j]])
				mut p := 0
				for p < part.len {
					out << part[p]
					p++
				}
				j++
			}
		}
		i++
	}
	return out
}

fn (mut e Emitter) resolve_path(path string) string {
	if path.starts_with('/') || path.starts_with('.') || e.base == '' {
		return path
	}
	mut cut := -1
	mut i := 0
	for i < e.base.len {
		c := e.base[i]
		if c == `/` || c == `\\` {
			cut = i
		}
		i++
	}
	if cut < 0 {
		if e.base == '' {
			return path
		}
		return e.base + '/' + path
	}
	return e.base[..cut] + '/' + path
}

fn (mut e Emitter) compile_module(src string, base string) ![]string {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		return error('module has diagnostics')
	}
	mut me := Emitter{
		arena:        &res.arena
		top:          map[string]bool{}
		mangled:      map[string]string{}
		collided:     map[string]string{}
		takes_kwargs: map[string]bool{}
		base:         base
		loaded:       e.loaded
	}
	for id in res.forms {
		me.remember(id)
	}
	for id in res.forms {
		me.form(id)
	}
	if me.blocked.len > 0 {
		for b in me.blocked {
			e.refuse(b)
		}
	}
	return me.out.clone()
}
