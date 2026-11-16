// vlib/blip/migrate/mod.v -- v1 to v2 migration.
//
// `blip migrate <file|dir>` rewrites v1 spellings to their v2 canonical
// forms so a program keeps running after the A2 removals:
//
//   (define ...)  -> (def ...)            (define/contract is kept + warned)
//   (lambda (p) ) -> (fn [p] ...)          (list params become a vector)
//   (λ [p] ...)   -> (fn [p] ...)
//   (do ...)      -> (begin ...)
//   (first x)     -> (car x)    (rest x) -> (cdr x)    (keep ..) -> (filter ..)
//   (case X ...)  -> (match X ...)        (literal clauses expand)
//   (when C B...) -> (if C (begin B...) nil)
//
// The rewrite is byte-span surgery anchored on reader origins, not text
// search: comments, blank lines, `;=>` markers and string contents are never
// touched, because only the renamed head symbols and restructured forms are
// replaced. A `;=>` on a form's own line stays on that line, so `blip test`
// keeps checking what it checked.
//
// What migrate does NOT do, on purpose:
//   - `quote` subtrees are data and are never touched.
//   - `quasiquote` templates are left alone with a warning (a template head
//     may be future code or plain data; guessing wrong corrupts silently,
//     while leaving it produces a loud removal error at runtime).
//   - `define/contract` is kept with a warning (def/contract lands separately).
// A `.lip` file IS renamed to `.blip`: the v2 loader reads `.blip` only,
// so leaving the old extension would migrate the content and still refuse
// to load it.
module migrate

import blip.reader
import os

pub struct MigrateResult {
pub:
	text     string
	changed  bool
	warnings []string
}

pub struct FileReport {
pub:
	path     string
	changed  bool
	renamed  bool
	warnings []string
}

struct Edit {
	start int
	end   int
	text  string
}

// Byte classes as ASCII codes, so no rune-literal spelling is involved.
fn is_ws(b u8) bool {
	return b == 32 || b == 9 || b == 10 || b == 13
}

// apply_edits splices non-overlapping edits into src, back to front, so
// earlier offsets stay valid. Overlapping edits are dropped; the fixpoint
// loop in migrate_source handles nested forms on later passes.
fn apply_edits(src string, edits []Edit) string {
	mut order := []int{}
	for i, _ in edits {
		order << i
	}
	mut o := 0
	for o < order.len {
		mut m := o
		mut j := o + 1
		for j < order.len {
			if edits[order[j]].start > edits[order[m]].start {
				m = j
			}
			j++
		}
		tmp := order[o]
		order[o] = order[m]
		order[m] = tmp
		o++
	}
	mut out := src
	mut floor := src.len + 1
	for k in order {
		e := edits[k]
		if e.start < 0 || e.end > out.len || e.start >= e.end {
			continue
		}
		if e.end > floor {
			continue
		}
		out = out[..e.start] + e.text + out[e.end..]
		floor = e.start
	}
	return out
}

fn trimmed_right(src string, a int, b int) string {
	mut e := b
	for e > a && is_ws(src[e - 1]) {
		e--
	}
	return src[a..e]
}

fn warn(mut warnings []string, line int, msg string) {
	w := 'line ${line}: ${msg}'
	if w !in warnings {
		warnings << w
	}
}

fn is_literal_tag(t reader.DatumTag) bool {
	return t in [.nil, .bool, .int, .rat, .float, .char, .str, .sym, .kw]
}

// expand_case builds (match X ...) from a (case X ...) form. Each
// [(v1 v2 ...) body] clause becomes one [vi body] clause per literal;
// [else body] becomes [_ body]. Gaps between clauses (whitespace and
// comments) are preserved verbatim from the source.
fn expand_case(a &reader.Arena, kids []reader.NodeId, form_end int, src string, mut edits []Edit, mut warnings []string, line int) {
	if kids.len < 3 {
		return
	}
	subj := a.node(kids[1])
	subj_text := src[subj.origin.start..subj.origin.end]
	mut parts := []string{}
	parts << '(match ${subj_text}'
	mut ci := 2
	for ci < kids.len {
		c := a.node(kids[ci])
		ckids := a.kids(kids[ci])
		if ckids.len == 0 {
			return
		}
		f0 := a.node(ckids[0])
		mut body_text := ''
		if ckids.len > 1 {
			body_text = trimmed_right(src, a.node(ckids[1]).origin.start, c.origin.end - 1)
		}
		if f0.tag == .sym && f0.value == 'else' {
			if ckids.len < 2 {
				return
			}
			parts << ' [${body_text}]'
			ci++
			continue
		}
		if f0.tag != .list {
			warn(mut warnings, line, 'case with a non-list pattern left untouched (migrate by hand)')
			return
		}
		alts := a.kids(ckids[0])
		if alts.len == 0 || ckids.len < 2 {
			return
		}
		for ai in alts {
			ad := a.node(ai)
			if !is_literal_tag(ad.tag) {
				warn(mut warnings, line, 'case with a non-literal pattern left untouched (migrate by hand)')
				return
			}
			parts << ' [${src[ad.origin.start..ad.origin.end]} ${body_text}]'
		}
		ci++
	}
	// Preserve the original gaps: text between the subject and the first
	// clause, between clauses, and before the closing paren all survive,
	// so comments inside the form are never lost.
	head := a.node(kids[0])
	_ = head
	mut out := parts[0]
	out += src[a.node(kids[1]).origin.end..a.node(kids[2]).origin.start]
	mut gi := 0
	for gi < parts.len - 1 {
		out += parts[gi + 1]
		if gi + 2 < kids.len {
			out += src[a.node(kids[gi + 2]).origin.end..a.node(kids[gi + 3]).origin.start]
		}
		gi++
	}
	out += src[a.node(kids[kids.len - 1]).origin.end..form_end]
	_ = out
}

// NOTE: expand_case above is superseded below by expand_case_at, which keeps
// a single canonical assembly. It is kept out of the walk; do not call it.
fn expand_case_at(a &reader.Arena, id reader.NodeId, src string, mut edits []Edit, mut warnings []string) {
	d := a.node(id)
	kids := a.kids(id)
	if kids.len < 3 {
		return
	}
	subj := a.node(kids[1])
	mut gen := []string{}
	mut gen_clause := []int{}
	mut ci := 2
	for ci < kids.len {
		c := a.node(kids[ci])
		ckids := a.kids(kids[ci])
		if ckids.len == 0 {
			return
		}
		f0 := a.node(ckids[0])
		if ckids.len < 2 {
			warn(mut warnings, d.origin.line, 'case clause without a body left untouched (migrate by hand)')
			return
		}
		body_text := trimmed_right(src, a.node(ckids[1]).origin.start, c.origin.end - 1)
		if f0.tag == .sym && f0.value == 'else' {
			gen << '[_ ${body_text}]'
			gen_clause << ci
			ci++
			continue
		}
		if f0.tag != .list {
			warn(mut warnings, d.origin.line, 'case with a non-list pattern left untouched (migrate by hand)')
			return
		}
		alts := a.kids(ckids[0])
		if alts.len == 0 {
			return
		}
		for ai in alts {
			ad := a.node(ai)
			if !is_literal_tag(ad.tag) {
				warn(mut warnings, d.origin.line, 'case with a non-literal pattern left untouched (migrate by hand)')
				return
			}
			gen << '[${src[ad.origin.start..ad.origin.end]} ${body_text}]'
			gen_clause << ci
		}
		ci++
	}
	mut out := '(match ${src[subj.origin.start..subj.origin.end]}'
	out += src[subj.origin.end..a.node(kids[2]).origin.start]
	mut gi := 0
	mut last_ci := -1
	for gi < gen.len {
		ci2 := gen_clause[gi]
		if gi > 0 {
			if ci2 != last_ci {
				out += src[a.node(kids[ci2 - 1]).origin.end..a.node(kids[ci2]).origin.start]
			} else {
				out += ' '
			}
		}
		out += gen[gi]
		last_ci = ci2
		gi++
	}
	out += src[a.node(kids[kids.len - 1]).origin.end..d.origin.end]
	edits << Edit{d.origin.start, d.origin.end, out}
}

// expand_when builds (if C (begin B...) nil) from (when C B...).
fn expand_when(a &reader.Arena, id reader.NodeId, src string, mut edits []Edit, mut warnings []string) {
	d := a.node(id)
	kids := a.kids(id)
	if kids.len < 3 {
		warn(mut warnings, d.origin.line, 'bare (when) without a body left untouched')
		return
	}
	test := a.node(kids[1])
	body_text := trimmed_right(src, a.node(kids[2]).origin.start, d.origin.end - 1)
	out := '(if ${src[test.origin.start..test.origin.end]} (begin ${body_text}) nil)'
	edits << Edit{d.origin.start, d.origin.end, out}
}

// walk collects one pass of edits. Renames and whole-form expansions share
// the pass; an expansion returns without descending, so nested forms are
// handled by later fixpoint passes on re-parsed text.
fn walk(a &reader.Arena, id reader.NodeId, src string, mut edits []Edit, mut warnings []string) {
	d := a.node(id)
	if d.tag != .list && d.tag != .vector {
		return
	}
	kids := a.kids(id)
	if kids.len == 0 {
		return
	}
	h := a.node(kids[0])
	if h.tag == .sym {
		match h.value {
			'quote' {
				return
			}
			'quasiquote' {
				warn(mut warnings, d.origin.line, 'quasiquote left untouched (check macro templates by hand)')
				return
			}
			'define' {
				edits << Edit{h.origin.start, h.origin.end, 'def'}
			}
			'define/contract' {
				warn(mut warnings, d.origin.line, 'define/contract kept (def/contract lands separately)')
			}
			'lambda' {
				edits << Edit{h.origin.start, h.origin.end, 'fn'}
				if kids.len > 1 {
					p := a.node(kids[1])
					if p.tag == .list && src[p.origin.start] == 40 && src[p.origin.end - 1] == 41 {
						edits << Edit{p.origin.start, p.origin.start + 1, '['}
						edits << Edit{p.origin.end - 1, p.origin.end, ']'}
					} else {
						warn(mut warnings, d.origin.line, 'lambda with unusual params left untouched (migrate by hand)')
					}
				}
			}
			'λ' {
				edits << Edit{h.origin.start, h.origin.end, 'fn'}
			}
			'do' {
				edits << Edit{h.origin.start, h.origin.end, 'begin'}
			}
			'first' {
				edits << Edit{h.origin.start, h.origin.end, 'car'}
			}
			'rest' {
				edits << Edit{h.origin.start, h.origin.end, 'cdr'}
			}
			'keep' {
				edits << Edit{h.origin.start, h.origin.end, 'filter'}
			}
			'case' {
				expand_case_at(a, id, src, mut edits, mut warnings)
				return
			}
			'when' {
				expand_when(a, id, src, mut edits, mut warnings)
				return
			}
			else {}
		}
	}
	for k in kids {
		walk(a, k, src, mut edits, mut warnings)
	}
}

// migrate_source rewrites v1 blip to v2, iterating to a fixpoint so forms
// copied raw by an expansion are migrated on later passes.
pub fn migrate_source(src string) !MigrateResult {
	mut warnings := []string{}
	mut text := src
	mut iter := 0
	for iter < 20 {
		res := reader.read_all(text)
		if res.diags.len > 0 {
			d := res.diags[0]
			return error('${d.line}:${d.col}: ${d.msg}')
		}
		mut edits := []Edit{}
		for id in res.forms {
			walk(&res.arena, id, text, mut edits, mut warnings)
		}
		if edits.len == 0 {
			break
		}
		text = apply_edits(text, edits)
		iter++
	}
	if iter >= 20 {
		warnings << 'migration did not converge after 20 passes (migrate the remainder by hand)'
	}
	return MigrateResult{
		text:     text
		changed:  text != src
		warnings: warnings
	}
}

fn collect_files(dir string, mut out []string) {
	entries := os.ls(dir) or { return }
	for e in entries {
		if e.starts_with('.') {
			continue
		}
		full := os.join_path(dir, e)
		if os.is_dir(full) {
			collect_files(full, mut out)
			continue
		}
		if full.ends_with('.lip') || full.ends_with('.blip') {
			out << full
		}
	}
}

// migrate_path migrates one file or every .lip/.blip file under a
// directory, writing back in place unless check_only is set. A `.lip`
// file is renamed to `.blip` alongside the rewrite (v2 loads `.blip`
// only): in check mode the report marks the rename without touching
// the filesystem, otherwise the migrated text lands at the new path
// and the old file is removed. A pre-existing `.blip` beside the `.lip`
// is a conflict the tool will not resolve by overwriting -- it errors.
pub fn migrate_path(target string, check_only bool) ![]FileReport {
	mut files := []string{}
	if os.is_dir(target) {
		collect_files(target, mut files)
	} else {
		files << target
	}
	mut out := []FileReport{}
	for f in files {
		src := os.read_file(f) or { return error('blip: cannot read ${f}') }
		r := migrate_source(src) or { return error('blip: ${f}: ${err.msg()}') }
		new_path := if f.ends_with('.lip') { f[..f.len - 4] + '.blip' } else { f }
		renamed := new_path != f
		if renamed && !check_only && os.exists(new_path) {
			return error('blip: ${new_path} already exists; remove one spelling and run migrate again')
		}
		if !check_only {
			if r.changed || renamed {
				os.write_file(new_path, r.text) or { return error('blip: cannot write ${new_path}') }
			}
			if renamed {
				os.rm(f) or { return error('blip: cannot remove ${f}') }
			}
		}
		out << FileReport{
			path:     f
			changed:  r.changed || renamed
			renamed:  renamed
			warnings: r.warnings
		}
	}
	return out
}

// ensure_mod stamps the module manifest: (module NAME) plus (blip VERSION).
// An existing manifest keeps its module name; a missing one is created.
pub fn ensure_mod(dir string, version int) !string {
	mod := os.join_path(dir, 'blip.mod')
	mut name := os.file_name(dir)
	if name == '' || name == '.' {
		name = 'app'
	}
	if os.exists(mod) {
		src := os.read_file(mod) or { return error('blip: cannot read ${mod}') }
		res := reader.read_all(src)
		if res.diags.len > 0 {
			return error('blip: ${mod} does not parse; fix or remove it')
		}
		mut want := -1
		for id in res.forms {
			kids := res.arena.kids(id)
			if kids.len != 2 {
				continue
			}
			if res.arena.node(kids[0]).tag != .sym {
				continue
			}
			if res.arena.node(kids[0]).value == 'module' {
				if res.arena.node(kids[1]).tag == .sym {
					name = res.arena.node(kids[1]).value
				}
			}
			if res.arena.node(kids[0]).value == 'blip' {
				if res.arena.node(kids[1]).tag == .int {
					want = int(res.arena.node(kids[1]).i)
				}
			}
		}
		if want == version {
			return 'current'
		}
		status := if want == -1 { 'stamped' } else { 'updated' }
		os.write_file(mod, '; blip module manifest (written by `blip migrate`)\n(module ${name})\n(blip ${version})\n') or {
			return error('blip: cannot write ${mod}')
		}
		return status
	}
	os.write_file(mod, '; blip module manifest (written by `blip migrate`)\n(module ${name})\n(blip ${version})\n') or {
		return error('blip: cannot write ${mod}')
	}
	return 'created'
}
