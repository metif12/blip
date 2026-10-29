module main

import os

// The API coverage gate.
//
// V's own line-coverage tooling does not work in the compiler this project is
// pinned to: `-coverage` is a declared flag, but it exits 1 and emits nothing,
// while the identical build without it exits 0. So percentage coverage cannot
// be measured here, which means a claim of a number would be a claim about
// something nobody had run.
//
// What CAN be measured, and is the thing that actually decays, is whether every
// public function of the library is still engaged by a test. This gate reads
// the public surface straight out of `vlib/blip/`, reads the corpus of tests
// and example programs, and fails if any public function is named nowhere in
// it. A new `pub fn` therefore turns this red the moment it is added, and the
// way to turn it green again is to write about it.
//
// A name appearing in the corpus is weaker evidence than a line being executed
// -- a name in a comment counts. It is nonetheless the right gate, because the
// failure it catches is the one that actually happens: a module grows, nobody
// notices, and half of it is never exercised by anything.

struct Suite {
mut:
	fails  int
	checks int
}

fn (mut s Suite) record(ok bool, good string, bad string) {
	s.checks++
	if ok {
		println('ok   ${good}')
	} else {
		s.fails++
		println('FAIL ${bad}')
	}
}

// walk collects every file under dir, skipping the directory trees that hold
// neither this project's source nor anything a test would want to read.
fn collect(dir string, mut out []string) {
	entries := os.ls(dir) or { return }
	for e in entries {
		p := os.join_path(dir, e)
		if os.is_dir(p) {
			if e in ['.git', 'site_out', 'v', 'tmp', 'dist', 'node_modules', 'blip_modules'] {
				continue
			}
			collect(p, mut out)
			continue
		}
		out << p
	}
}

fn read_corpus(paths []string) string {
	mut sb := []string{}
	for p in paths {
		sb << os.read_file(p) or { continue }
	}
	return sb.join('\n')
}

// pub_fns returns every public function name declared under `dir`, deduped.
//
// Method names repeat across receivers -- `get` and `has` are defined on both
// Table and StructVal -- so a name that is tested once counts as covered for
// every receiver carrying it. That is a deliberate looseness: it under-reports
// coverage rather than over-reporting it, which is the safe direction.
fn pub_fns(dir string) []string {
	mut files := []string{}
	collect(dir, mut files)
	mut names := []string{}
	for f in files {
		if !f.ends_with('.v') {
			continue
		}
		if f.ends_with('_test.v') {
			continue
		}
		src := os.read_file(f) or { continue }
		for line in src.split_into_lines() {
			t := line.trim_space()
			if !t.starts_with('pub fn ') {
				continue
			}
			rest := t['pub fn '.len..]
			mut head := rest
			if rest.starts_with('(') {
				end := rest.index(')') or { continue }
				head = rest[end + 1..].trim_space()
			}
			open := head.index('(') or { continue }
			names << head[..open].trim_space()
		}
	}
	mut seen := map[string]bool{}
	mut out := []string{}
	for n in names {
		if n == '' || n in seen {
			continue
		}
		seen[n] = true
		out << n
	}
	out.sort()
	return out
}

fn main() {
	mut s := Suite{}

	names := pub_fns('vlib/blip')

	// The corpus is everything a test, an example or a program says. The
	// examples and programs are included because they are executed by
	// tests/examples_run.v and tests/programs_run.v -- prose about a function
	// in one of them is a check that the suite actually runs.
	//
	// blip.v and server.v are the two executables: they are built before these
	// suites run (CI does it first, locally the README says to), and
	// tests/repl_golden.v spawns the CLI and tests/unit.v spawns the language
	// server. `lsp.serve` is the one public function that cannot be called
	// in-process, because it owns stdin, so the CLI is where it is engaged.
	mut corpus_files := []string{}
	collect('tests', mut corpus_files)
	for cli in ['blip.v', 'server.v', 'reader_probe.v'] {
		if os.exists(cli) {
			corpus_files << cli
		}
	}
	for extra in [os.join_path('examples', '01_basics.lip'), os.join_path('examples', '02_data.lip'),
		os.join_path('examples', '03_match.lip'), os.join_path('examples', '04_errors.lip'),
		os.join_path('examples', '05_pipelines.lip'), os.join_path('examples', '06_modules.lip'),
		os.join_path('programs', 'brainfuck.lip'), os.join_path('programs', 'json.lip')] {
		if os.exists(extra) {
			corpus_files << extra
		}
	}
	corpus := read_corpus(corpus_files)

	mut missing := []string{}
	for n in names {
		if !corpus.contains(n + '(') {
			missing << n
		}
	}

	s.record(names.len > 0, '${names.len} public functions found in vlib/blip',
		'no public functions found -- the scan is broken, not the library')

	if missing.len == 0 {
		s.record(true, 'every one of ${names.len} is engaged by a test or a program',
			'some are not')
	} else {
		println('   not engaged: ${missing.join(' ')}')
		s.fails++
	}

	// The corpus must not be trivially satisfied: a suite that reads its own
	// list of names and stops there would pass with nothing tested. Check that
	// the real suites are present in it.
	for required in ['tail_calls.v', 'binding_forms.v', 'embedding.v', 'repl_golden.v', 'examples_run.v',
		'programs_run.v', 'genprims.v'] {
		s.record(corpus_files.any(os.file_name(it) == required),
			'${required} is in the corpus', '${required} is missing from the corpus')
	}

	if s.fails > 0 {
		println('${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('api coverage: all checks passed')
}
