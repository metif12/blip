#!/usr/bin/env -S v run

// tools/genprims.vsh -- generate blip primitives from vlib signatures.
//
// Reads `v ast -p` JSON for allowlisted (module, file, fn) triples,
// classifies each signature, and emits vlib/blip/prims/gen_<module>.v with
// wrapper prims plus a register_gen_<module> function. One hand-written line
// per module wires it into the table in vlib/blip/prims/mod.v.
//
// This runs on every V sync (docs/010-roadmap.md 7.1) and in CI with
// --check: an upstream rename, reorganization, or signature change fails
// loudly instead of shipping a stale binding.
//
// Design rules, all load-bearing:
//
//   * Allowlist, not bulk import. `v ast` reports no visibility, so "all pub
//     fns" is unimplementable from its JSON; curation also keeps the prim
//     table reviewable and collision-free. New upstream fns surface in the
//     "convertible but not allowlisted" report for a human to bless.
//   * Only exact, total mappings generate. Narrowing (f32), options,
//     results, and collections are recognized and reported as deferred, not
//     silently emitted; everything else is unsupported. The pilot stays on
//     proven paths, and untested template branches do not ship.
//   * Generated files are never hand-edited. The header says how to regen,
//     and --check enforces that the checked-in copy matches.
import os
import strings

// ------------------------------------------------------------------ config

// GenTarget is one vlib module to bind: the files to read (explicit, so an
// upstream reorganization fails here with a filename instead of silently
// binding nothing) and the function names to take from them.
struct GenTarget {
	mod_name string
	files    []string
	fns      []string
}

const allowlist = [
	GenTarget{
		mod_name: 'math'
		files:    ['floor.v', 'sin.v', 'log.v', 'exp.v', 'factorial.v']
		fns:      ['floor', 'sin', 'cos', 'log', 'log10', 'log2', 'factorial', 'exp']
	},
]

const int_types = ['i8', 'i16', 'int', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64', 'byte', 'isize',
	'usize']

// ------------------------------------------------------------------ ast

struct Param {
	name   string
	typ    string
	is_mut bool
}

struct Sig {
	name string
	ret  string
mut:
	params []Param
}

// ------------------------------------------------------------------ json
//
// `v ast -p` JSON is read with a minimal hand-written parser, not the `json`
// module: stock 0.5.2 has no `json2` (dynamic `Any` traversal), and classic
// `json.decode` needs a static target type, which an AST has no use for.
// The DOM below is the smallest thing the collector needs: objects keyed by
// string, arrays, strings, booleans. Numbers keep their raw text; only
// strings, booleans, and structure are ever read.
//
// kinds: 0=null 1=true 2=false 3=string 4=number 5=array 6=object.
struct JNode {
	kind int
mut:
	s string
	// kids holds array items or object values; keys the object keys, so
	// keys[i] names kids[i]. ([]string and []int are reference types, so a
	// node keeps its own slices rather than windows into a shared array:
	// nested values would interleave and a start/len window cannot work.)
	kids []int
	keys []string
}

struct JParser {
	text string
mut:
	failed bool
	pos    int
	nodes  []JNode
}

fn (mut p JParser) add(kind int) int {
	p.nodes << JNode{
		kind: kind
	}
	return p.nodes.len - 1
}

// add_kid appends one child with an explicit write-back: indexing a slice
// yields a copy, so `p.nodes[id].kids << c` would grow a temporary.
fn (mut p JParser) add_kid(id int, key string, val int) {
	mut n := p.nodes[id]
	n.kids << val
	n.keys << key
	p.nodes[id] = n
}

fn (mut p JParser) skip_ws() {
	for p.pos < p.text.len && p.text[p.pos] in [` `, `\t`, `\n`, `\r`] {
		p.pos++
	}
}

fn (mut p JParser) expect(lit string) {
	if p.text[p.pos..].starts_with(lit) {
		p.pos += lit.len
		return
	}
	p.failed = true
}

fn (mut p JParser) parse_value() int {
	p.skip_ws()
	if p.pos >= p.text.len {
		p.failed = true
		return p.add(0)
	}
	c := p.text[p.pos]
	match c {
		`{` {
			return p.parse_object()
		}
		`[` {
			return p.parse_array()
		}
		`"` {
			return p.parse_string()
		}
		`t` {
			p.expect('true')
			return p.add(1)
		}
		`f` {
			p.expect('false')
			return p.add(2)
		}
		`n` {
			p.expect('null')
			return p.add(0)
		}
		else {
			return p.parse_number()
		}
	}
}

fn (mut p JParser) parse_object() int {
	id := p.add(6)
	p.pos++ // {
	p.skip_ws()
	if p.pos < p.text.len && p.text[p.pos] == `}` {
		p.pos++
		return id
	}
	for {
		p.skip_ws()
		if p.pos >= p.text.len || p.text[p.pos] != `"` {
			p.failed = true
			return id
		}
		key := p.parse_string()
		p.skip_ws()
		if p.pos >= p.text.len || p.text[p.pos] != `:` {
			p.failed = true
			return id
		}
		p.pos++
		val := p.parse_value()
		p.add_kid(id, p.nodes[key].s, val)
		p.skip_ws()
		if p.pos >= p.text.len {
			p.failed = true
			return id
		}
		if p.text[p.pos] == `,` {
			p.pos++
			continue
		}
		if p.text[p.pos] == `}` {
			p.pos++
			break
		}
		p.failed = true
		return id
	}
	return id
}

fn (mut p JParser) parse_array() int {
	id := p.add(5)
	p.pos++ // [
	p.skip_ws()
	if p.pos < p.text.len && p.text[p.pos] == `]` {
		p.pos++
		return id
	}
	for {
		val := p.parse_value()
		p.add_kid(id, '', val)
		p.skip_ws()
		if p.pos >= p.text.len {
			p.failed = true
			return id
		}
		if p.text[p.pos] == `,` {
			p.pos++
			continue
		}
		if p.text[p.pos] == `]` {
			p.pos++
			break
		}
		p.failed = true
		return id
	}
	return id
}

fn (mut p JParser) parse_string() int {
	// The caller has checked the opening quote; the stored text is unescaped,
	// so a key lookup never sees backslashes.
	id := p.add(3)
	p.pos++ // "
	mut out := []u8{}
	for p.pos < p.text.len {
		c := p.text[p.pos]
		if c == `"` {
			p.pos++
			break
		}
		if c != `\\` {
			out << c
			p.pos++
			continue
		}
		p.pos++
		if p.pos >= p.text.len {
			break
		}
		e := p.text[p.pos]
		p.pos++
		match e {
			`"` {
				out << `"`
			}
			`\\` {
				out << `\\`
			}
			`/` {
				out << `/`
			}
			`b` {
				out << `\b`
			}
			`f` {
				out << `\f`
			}
			`n` {
				out << `\n`
			}
			`r` {
				out << `\r`
			}
			`t` {
				out << `\t`
			}
			`u` {
				cp := p.parse_hex4()
				if cp < 0x80 {
					out << u8(cp)
				} else if cp < 0x800 {
					out << u8(0xc0 | (u32(cp) >> 6))
					out << u8(0x80 | (u32(cp) & 0x3f))
				} else {
					out << u8(0xe0 | (u32(cp) >> 12))
					out << u8(0x80 | ((u32(cp) >> 6) & 0x3f))
					out << u8(0x80 | (u32(cp) & 0x3f))
				}
			}
			else {
				out << e
			}
		}
	}
	p.nodes[id].s = out.bytestr()
	return id
}

fn (mut p JParser) parse_hex4() u32 {
	mut cp := u32(0)
	mut i := 0
	for i < 4 && p.pos < p.text.len {
		c := p.text[p.pos]
		d := if c >= `0` && c <= `9` {
			u32(c - `0`)
		} else if c >= `a` && c <= `f` {
			u32(c - `a` + 10)
		} else if c >= `A` && c <= `F` {
			u32(c - `A` + 10)
		} else {
			p.failed = true
			return 0xfffd
		}
		cp = cp * 16 + d
		p.pos++
		i++
	}
	return cp
}

fn (mut p JParser) parse_number() int {
	id := p.add(4)
	start := p.pos
	for p.pos < p.text.len
		&& (p.text[p.pos].is_digit() || p.text[p.pos] in [`-`, `+`, `.`, `e`, `E`]) {
		p.pos++
	}
	if p.pos == start {
		p.failed = true
	}
	p.nodes[id].s = p.text[start..p.pos]
	return id
}

fn (p &JParser) obj_get(idx int, key string) int {
	if idx < 0 || idx >= p.nodes.len || p.nodes[idx].kind != 6 {
		return -1
	}
	for i, k in p.nodes[idx].keys {
		if k == key {
			return p.nodes[idx].kids[i]
		}
	}
	return -1
}

fn (p &JParser) obj_str(idx int, key string) string {
	c := p.obj_get(idx, key)
	if c < 0 || p.nodes[c].kind != 3 {
		return ''
	}
	return p.nodes[c].s
}

fn (p &JParser) obj_bool(idx int, key string) bool {
	c := p.obj_get(idx, key)
	if c < 0 {
		return false
	}
	return p.nodes[c].kind == 1
}

fn (p &JParser) arr_len(idx int) int {
	if idx < 0 || idx >= p.nodes.len || p.nodes[idx].kind != 5 {
		return 0
	}
	return p.nodes[idx].kids.len
}

fn (p &JParser) arr_at(idx int, i int) int {
	return p.nodes[idx].kids[i]
}

// collect_sigs reads every top-level FnDecl in one `v ast -p` document:
// short name, return type string, params in order. The 0.5.2 AST carries
// `is_pub`, `short_name`, `return_type`, and a `params` array directly, so
// no recursive walk is needed; a method (non-void receiver type) is skipped
// here rather than later, because its dotted name would otherwise read as a
// plain function of the module.
fn collect_sigs(p &JParser) []Sig {
	mut out := []Sig{}
	stmts := p.obj_get(0, 'stmts')
	for i in 0 .. p.arr_len(stmts) {
		n := p.arr_at(stmts, i)
		if p.obj_str(n, 'ast_type') != 'FnDecl' {
			continue
		}
		recv := p.obj_get(n, 'receiver')
		if recv >= 0 && p.obj_str(recv, 'typ') !in ['', 'void'] {
			continue
		}
		mut nm := p.obj_str(n, 'short_name')
		if nm == '' {
			nm = p.obj_str(n, 'name')
		}
		mut s := Sig{
			name: nm
			ret:  p.obj_str(n, 'return_type')
		}
		ps := p.obj_get(n, 'params')
		for j in 0 .. p.arr_len(ps) {
			c := p.arr_at(ps, j)
			s.params << Param{
				name:   p.obj_str(c, 'name')
				typ:    p.obj_str(c, 'typ')
				is_mut: p.obj_bool(c, 'is_mut')
			}
		}
		out << s
	}
	return out
}

// ------------------------------------------------------------------ classify

// param_class is '' when the parameter maps exactly, else the skip reason.
fn param_class(t string) string {
	if t in int_types {
		return ''
	}
	if t == 'f64' || t == 'string' {
		return ''
	}
	if t == 'bool' {
		return 'deferred: bool params need a tag check nobody has reviewed'
	}
	if t == 'f32' {
		return 'deferred: f32 params narrow f64 silently'
	}
	if t.starts_with('?') || t.starts_with('!') || t.starts_with('[') || t.starts_with('map[') {
		return 'deferred: option/result/collection params'
	}
	return 'unsupported type: ${t}'
}

// ret_class is '' when the return maps exactly, else the skip reason.
fn ret_class(t string) string {
	if t == '' || t == 'void' {
		return ''
	}
	if t in int_types {
		return ''
	}
	if t == 'f64' || t == 'string' || t == 'bool' {
		return ''
	}
	if t == 'f32' {
		return 'deferred: f32 return widens, unreviewed'
	}
	if t.starts_with('?') || t.starts_with('!') || t.starts_with('[') || t.starts_with('map[') {
		return 'deferred: option/result/collection returns'
	}
	return 'unsupported type: ${t}'
}

// ------------------------------------------------------------------ emit

fn kebab(s string) string {
	return s.replace('_', '-')
}

// extract lines emit the argument conversions; call_args are the converted
// variable names to pass to the V call.
fn extract_lines(pname string, params []Param) (string, string) {
	mut decls := strings.new_builder(256)
	mut call_args := []string{}
	mut i := 0
	for p in params {
		v := 'a${i}'
		if p.typ == 'f64' {
			decls.write_string("\t${v} := as_f64(args[${i}]) or { return error('${pname} expects a number, got \${printer.write(args[${i}])}') }\n")
			call_args << v
		} else if p.typ in int_types {
			decls.write_string("\ta${i} := need_int('${pname}', args[${i}])!\n")
			call_args << '${p.typ}(${v})'
		} else {
			decls.write_string("\t${v} := need_str('${pname}', args[${i}])!\n")
			call_args << v
		}
		i++
	}
	return decls.str(), call_args.join(', ')
}

fn return_lines(ret string, call string) string {
	if ret == '' || ret == 'void' {
		return '\t${call}\n\treturn blip.nil_value()'
	}
	if ret == 'f64' {
		return '\treturn blip.float(${call})'
	}
	if ret in int_types {
		return '\treturn blip.integer(i64(${call}))'
	}
	if ret == 'string' {
		return '\treturn blip.string(${call})'
	}
	return '\treturn blip.boolean(${call})'
}

struct Emitted {
	pname    string
	vname    string
	sig_text string
	body     string
}

fn emit_fn(mod_name string, s Sig) Emitted {
	pname := '${mod_name}-' + kebab(s.name)
	decls, cargs := extract_lines(pname, s.params)
	call := '${mod_name}.${s.name}(${cargs})'
	mut sb := strings.new_builder(512)
	sb.write_string('// ${pname} wraps ${mod_name}.${s.name}(${param_text(s)}) ${s.ret}.\n')
	sb.write_string('fn prim_gen_${mod_name}_${s.name}(args []blip.Value) !blip.Value {\n')
	sb.write_string('\tif args.len != ${s.params.len} {\n')
	sb.write_string("\t\treturn error('${pname} expects ${s.params.len} argument(s), got \${args.len}')\n")
	sb.write_string('\t}\n')
	sb.write_string(decls)
	sb.write_string(return_lines(s.ret, call) + '\n')
	sb.write_string('}\n')
	return Emitted{
		pname:    pname
		vname:    s.name
		sig_text: '${mod_name}.${s.name}(${param_text(s)}) ${s.ret}'
		body:     sb.str()
	}
}

fn param_text(s Sig) string {
	mut parts := []string{}
	for p in s.params {
		parts << '${p.name} ${p.typ}'
	}
	return parts.join(', ')
}

// ------------------------------------------------------------------ driver

fn vlib_dir() string {
	// Use @VEXE (the compiler running this script), not `v` on PATH: on this
	// host PATH resolves to a different V build, which is exactly the kind of
	// "works on my machine" mismatch the pin exists to prevent.
	mut cands := []string{}
	vexe := @VEXE
	if vexe != '' {
		cands << os.dir(vexe)
	}
	from_env := os.getenv('VEXE')
	if from_env != '' {
		cands << os.dir(from_env)
	}
	for c in cands {
		mut d := c
		for _ in 0 .. 4 {
			cand := os.join_path(d, 'vlib')
			if os.is_dir(cand) {
				return cand
			}
			d = os.dir(d)
		}
	}
	eprintln('genprims: no vlib found near `${vexe}`; set VEXE')
	exit(1)
}

fn v_version() string {
	// @VEXE, not bare `v`: a `v run` script that shells out to `v version`
	// otherwise stamps itself with whichever V is on PATH, which is a
	// different build from the one running the script (local release install
	// dd6834e vs the pinned v-pin 0137eb5 was a real mismatch).
	r := os.execute('"${@VEXE}" version')
	if r.exit_code != 0 {
		return 'unknown'
	}
	return r.output.trim_space()
}

// strip_stamp removes the header's `at V <version>` build stamp, so --check
// compares generated CONTENT. The stamp records which build produced the
// file, but local and CI regenerate from the same pinned sources against
// the same vlib, so a differing stamp alone is not staleness.
fn strip_stamp(t string) string {
	nl := t.index('\n') or { return t }
	head := t[..nl]
	if !head.contains(' at V ') {
		return t
	}
	// Plain concatenation only: a `${...}` interpolation with a nested
	// single-quoted literal once turned this check into a tautology; the
	// same string came back for both sides, and content corruption was
	// accepted silently. Keep this line dumb. The controls, to rerun after
	// any edit here: corrupt ONLY the stamp → --check passes; corrupt a
	// body line → --check fails.
	return head.all_before(' at V ') + '.' + t[nl..]
}

// existing_prims text-scans the hand-written table for registered names, so
// a generated name can never shadow one silently.
fn existing_prims() []string {
	mut out := []string{}
	files := os.ls('vlib/blip/prims') or { return out }
	for f in files {
		if !f.ends_with('.v') || f.starts_with('gen_') {
			continue
		}
		body := os.read_file(os.join_path('vlib/blip/prims', f)) or { continue }
		for line in body.split_into_lines() {
			trimmed := line.trim_space()
			if trimmed.starts_with("p['") {
				name := trimmed.all_after("p['").all_before("']")
				if name != '' {
					out << name
				}
			}
		}
	}
	return out
}

fn is_pub(source string, name string) bool {
	short := name.all_after_last('.')
	return source.contains('pub fn ${short}(') || source.contains('pub fn ${short}[')
}

fn main() {
	check_only := '--check' in os.args
	mut only_module := ''
	mut ai := 0
	for ai < os.args.len {
		if os.args[ai] == '--module' && ai + 1 < os.args.len {
			only_module = os.args[ai + 1]
		}
		ai++
	}
	vlib := vlib_dir()
	ver := v_version()
	known := existing_prims()
	mut fails := 0
	mut generated := map[string]string{}

	for target in allowlist {
		if only_module != '' && target.mod_name != only_module {
			continue
		}
		mut sigs := map[string]Sig{}
		mut dupes := []string{}
		for file in target.files {
			path := os.join_path(vlib, target.mod_name) + os.path_separator + file
			r := os.execute('"${@VEXE}" ast -p ${path}')
			if r.exit_code != 0 && r.output.trim_space() == '' {
				eprintln('genprims: v ast failed on ${target.mod_name}/${file}:')
				eprintln(r.output)
				eprintln('genprims: file moved upstream? update the allowlist files')
				fails++
				continue
			}
			mut parser := JParser{
				text: r.output
			}
			root := parser.parse_value()
			if parser.failed {
				eprintln('genprims: bad ast json for ${path}')
				fails++
				continue
			}
			_ = root
			for s in collect_sigs(&parser) {
				if s.name in sigs {
					dupes << s.name
					continue
				}
				sigs[s.name] = s
			}
		}
		for d in dupes {
			eprintln('genprims: ${target.mod_name}.${d} defined twice in the listed files; disambiguate the file list')
			fails++
		}
		mut fns := []Emitted{}
		mut skipped := []string{}
		mut missing := []string{}
		for want in target.fns {
			if want !in sigs {
				missing << want
				continue
			}
			s := sigs[want]
			if s.name.contains('.') {
				skipped << '${want}: method, needs a receiver blip cannot name'
				continue
			}
			if s.params.any(it.is_mut) {
				skipped << '${want}: mut params mutate the caller, unmappable'
				continue
			}
			mut reason := ''
			for p in s.params {
				reason = param_class(p.typ)
				if reason != '' {
					break
				}
			}
			if reason == '' {
				reason = ret_class(s.ret)
			}
			if reason != '' {
				skipped << '${want}: ${reason}'
				continue
			}
			// Visibility is textual: the AST reports no pub flag, so the
			// source itself is asked below. A private fn compiles nowhere
			// as math.name from another module.
			fns << emit_fn(target.mod_name, s)
		}
		// pub + collision checks need file sources; re-read cheaply.
		mut pub_src := ''
		for file in target.files {
			pub_src += os.read_file(os.join_path(vlib, target.mod_name) + os.path_separator + file) or {
				''
			}
		}
		mut kept := []Emitted{}
		for e in fns {
			if !is_pub(pub_src, e.vname) {
				eprintln('genprims: ${target.mod_name}.${e.vname} is not pub upstream; drop it from the allowlist')
				fails++
				continue
			}
			if e.pname in known {
				eprintln('genprims: ${e.pname} collides with a hand-written prim; rename or drop it')
				fails++
				continue
			}
			kept << e
		}
		kept.sort_with_compare(fn (a &Emitted, b &Emitted) int {
			if a.pname < b.pname {
				return -1
			}
			if a.pname > b.pname {
				return 1
			}
			return 0
		})
		mut sb := strings.new_builder(4096)
		sb.write_string('// Code generated by tools/genprims.vsh from vlib/${target.mod_name} at ${ver}.\n')
		sb.write_string('// DO NOT EDIT: rerun `v run tools/genprims.vsh` instead.\n')
		sb.write_string('// Wired into the table by one line in table(): register_gen_${target.mod_name}(mut p).\n')
		sb.write_string('module prims\n\nimport math\nimport blip\nimport blip.printer\n\n')
		for e in kept {
			sb.write_string(e.body + '\n')
		}
		sb.write_string('fn register_gen_${target.mod_name}(mut p map[string]blip.PrimFn) {\n')
		for e in kept {
			sb.write_string("\tp['${e.pname}'] = prim_gen_${target.mod_name}_${e.vname}\n")
		}
		sb.write_string('}\n')
		generated['vlib/blip/prims/gen_${target.mod_name}.v'] = sb.str()

		println('== ${target.mod_name}: ${kept.len} prims, ${skipped.len} skipped, ${missing.len} missing')
		for e in kept {
			println('   + ${e.pname}  (${e.sig_text})')
		}
		for s in skipped {
			println('   - ${s}')
		}
		for m in missing {
			eprintln('genprims: ${target.mod_name}.${m} not found in the AST; renamed upstream?')
			fails++
		}
		// Curation aid: convertible fns nobody allowlisted, so the sync
		// review sees what upstream added.
		mut unlisted := []string{}
		for name, s in sigs {
			if name in target.fns || name.contains('.') {
				continue
			}
			mut ok := true
			for p in s.params {
				if p.is_mut || param_class(p.typ) != '' {
					ok = false
					break
				}
			}
			if ok && ret_class(s.ret) == '' {
				unlisted << '${name}(${param_text(s)}) ${s.ret}'
			}
		}
		unlisted.sort()
		for u in unlisted {
			println('   ? convertible but not allowlisted: ${u}')
		}
	}

	if fails > 0 {
		exit(1)
	}
	// Stale files: a generated module dropped from the allowlist must not
	// linger, or --check would bless a ghost.
	mut stale := []string{}
	for f in os.ls('vlib/blip/prims') or { []string{} } {
		if f.starts_with('gen_') && f.ends_with('.v') {
			if 'vlib/blip/prims/${f}' !in generated {
				stale << f
			}
		}
	}
	if check_only {
		mut dirty := false
		for path, body in generated {
			cur := os.read_file(path) or {
				eprintln('genprims --check: missing ${path}; rerun without --check')
				dirty = true
				continue
			}
			// Line endings are not content: a CRLF checkout on Windows and
			// an LF one on Linux must both pass against the same output.
			if strip_stamp(cur.replace('\r\n', '\n')) != strip_stamp(body) {
				eprintln('genprims --check: stale ${path}; rerun without --check and review the diff')
				dirty = true
			}
		}
		for f in stale {
			eprintln('genprims --check: stale generated file vlib/blip/prims/${f}; remove it')
			dirty = true
		}
		if dirty {
			exit(1)
		}
		println('genprims --check: all generated files current')
		return
	}
	for f in stale {
		os.rm('vlib/blip/prims/${f}') or {}
		println('removed stale vlib/blip/prims/${f}')
	}
	for path, body in generated {
		os.write_file(path, body) or {
			eprintln('genprims: cannot write ${path}: ${err.msg()}')
			exit(1)
		}
		println('wrote ${path}')
	}
}
