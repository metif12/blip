module emit

$if !wasm32 {
	import os
}

import blip
import blip.host
import blip.machine
import blip.reader

fn (mut e Emitter) callable(name string) string {
	// A program definition shadows the runtime, exactly like the machine's
	// environment shadows a primitive: `remember` collected every top-level
	// `def`, so a std combinator (or any user function sharing a runtime
	// name) calls the definition on both engines. Without this the machine
	// ran the user's code and the emitter ran the runtime helper.
	if name in e.top {
		return e.mangle_name(name)
	}
	if name in prim_names {
		return 'blip.${mangle(name)}'
	}
	// A hyphenated, question-marked or bang-ed name is not a JavaScript
	// identifier, so it is mangled with the same rule `symbol` uses -- one rule,
	// in one place, so a definition and a call always agree. Refusing it here
	// used to throw away every name in 01_basics.blip that was not a bare word:
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
		'println' { return 'println' }
		'display' { return 'display' }
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
		'string-slice' { return 'string_slice' }
		// `string-join`, `string-repeat` and the with-affixes were machine-only
		// prims the backend did not route, so programs using them emitted calls
		// to names nothing defined -- the same gap `drop` closed in D2.
		'string-join' { return 'string_join' }
		'string-repeat' { return 'string_repeat' }
		'string-start-with?' { return 'string_start_with_q' }
		'string-ends-with?' { return 'string_ends_with_q' }
		'string-index-of' { return 'string_index_of' }
		'rational?' { return 'rational_q' }
		'module-paths' { return 'module_paths' }
		'min' { return 'min' }
		'max' { return 'max' }
		'vector-append' { return 'vector_append' }
		'array-push!' { return 'array_push_b' }
		'array-set!' { return 'array_set_b' }
		'put!' { return 'put_b' }
		'take' { return 'take' }
		// `drop` is the dual of `take`: the machine has always had it
		// (prim_drop) but the backend did not, so a program using it emitted a
		// call to a name nothing defined.
		'drop' { return 'drop' }
		// `now` is unix seconds as an integer. The machine reads the clock;
		// the backend reads the date, floored -- the same number except
		// across the single second the two calls happen to straddle.
		'now' { return 'now' }
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
		'string-blank?' { return 'string_blank_q' }
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
	'println':           true
	'display':           true
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
	'fold':              true
	'min':               true
	'max':               true
	'module-paths':      true
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
	'string-slice':      true
	'string-join':       true
	'string-repeat':     true
	'string-start-with?': true
	'string-ends-with?': true
	'string-index-of':   true
	'vector-append':     true
	'array-push!':       true
	'array-set!':        true
	'put!':              true
	'take':              true
	'drop':              true
	'now':               true
	'array?':            true
	'table?':            true
	'float?':            true
	'integer?':          true
	'keyword?':          true
	'list?':             true
	'negative?':         true
	'number?':           true
	'rational?':         true
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
	'string-blank?':     true
	'frequencies':       true
}

// stmt emits a form as a statement, and drops a trailing `;` when the form is
// an expression that already ends in one.
fn (mut e Emitter) mangle_name(s string) string {
	if !needs_mangle(s) {
		return s
	}
	// `->` first: it contains `-`, and a general dash replacement would
	// leave a bare `>` -- which is not a JavaScript identifier character.
	// `row->table` is the threaded naming blip reads naturally.
	mut out := s.replace('->', '_to_').replace('-', '_').replace('?', '_q').replace('!', '_b')
	out = out.replace('*', '_star_').replace('#', '_hash_')
	return out
}

// claim_name records a top-level definition's JavaScript identifier. Two
// DIFFERENT blip names reaching one identifier is a genuine collision --
// the module would run one definition as the other -- so the second claim
// is recorded for the end-of-compile check, which turns it into a refusal.
// Only definitions claim: parameters and locals live in their own scopes,
// so a local that shadows a mangled top-level name is shadowing, not
// colliding, and registering uses would cry wolf on every reference.
fn (mut e Emitter) claim_name(blip_name string, js string) {
	prev := e.mangled[js] or { '' }
	if prev != '' && prev != blip_name {
		e.collided[blip_name] = js
	}
	e.mangled[js] = blip_name
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

$if wasm32 {
	fn (mut e Emitter) require_form(kids []reader.NodeId) {
		return
	}
} $else {
	fn (mut e Emitter) require_form(kids []reader.NodeId) {
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
			// Modules as data: the machine appends each loaded path to its
			// registry as it loads, and the emitted program does the same
			// here, in load order, so `module-paths` agrees on both
			// engines -- including mid-evaluation queries.
			e.out << 'blip.note_module_loaded(${json_str(full)});'
			k++
		}
	}
}

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
	// A top-level definition shadows one too, for the same reason and in the
	// same order the machine resolves it: environment (here: enclosing
	// construct), then program definitions, then the runtime. `symbol` is the
	// value-position half of this rule; `callable` is the call-position half.
	if js := e.local_js(s) {
		return js
	}
	if s in e.top {
		return e.mangle_name(s)
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
