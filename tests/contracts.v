module main

// The M10 gate: runtime contracts, erased annotations, and `blip check`.
//
// `define/contract` checks its arguments (and optionally its result) on every
// call, desugared to `assert`, so a violation is an ordinary machine error.
// Annotations `(x int)` and a return position erase: running never sees them,
// and `blip check` (machine.check_source here, the CLI in main.v) reports the
// mismatches without evaluating anything.
import blip.host
import blip.machine
import blip.manifest
import blip.printer

struct Suite {
mut:
	fails int
}

fn (mut s Suite) fail(label string, msg string) {
	s.fails++
	println('FAIL ${label}: ${msg}')
}

fn (mut s Suite) ok(label string, detail string) {
	println('ok   ${label} => ${detail}')
}

fn (mut s Suite) run_ok(label string, src string, want string) {
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	got := m.run_str(src) or {
		s.fail(label, 'errored: ${err.msg()}')
		return
	}
	text := printer.write(got)
	if text != want {
		s.fail(label, 'expected ${want}, got ${text}')
		return
	}
	s.ok(label, want)
}

fn (mut s Suite) run_fails(label string, src string, want_err string) {
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	m.run_str(src) or {
		if err.msg().contains(want_err) {
			s.ok(label, 'refused: ${want_err}')
			return
		}
		s.fail(label, 'wrong error: ${err.msg()}')
		return
	}
	s.fail(label, 'succeeded, wanted an error containing ${want_err}')
}

fn (mut s Suite) check_ok(label string, src string) {
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	forms := m.arena.read_source(src, 'check')
	if forms.diags.len > 0 {
		s.fail(label, 'reader: ${forms.diags[0].msg}')
		return
	}
	diags := m.check_source(forms.forms)
	if diags.len > 0 {
		s.fail(label, 'unexpected: ${diags[0].msg}')
		return
	}
	s.ok(label, 'clean')
}

fn (mut s Suite) check_fails(label string, src string, want_msg string) {
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	forms := m.arena.read_source(src, 'check')
	if forms.diags.len > 0 {
		s.fail(label, 'reader: ${forms.diags[0].msg}')
		return
	}
	diags := m.check_source(forms.forms)
	for d in diags {
		if d.msg.contains(want_msg) {
			s.ok(label, 'reported: ${want_msg}')
			return
		}
	}
	s.fail(label, 'no diagnostic containing ${want_msg} (${diags.len} found)')
}

// check_warns demands a WARNING containing want_msg: the exhaustiveness
// rule warns by default, so `check_fails` (which would also match an
// error) cannot tell the modes apart. Severity is the assertion.
fn (mut s Suite) check_warns(label string, src string, want_msg string) {
	diags := machine.check_text(src, false)
	for d in diags {
		if d.msg.contains(want_msg) && d.severity == 'warning' {
			s.ok(label, 'warned: ${want_msg}')
			return
		}
	}
	s.fail(label, 'no warning containing ${want_msg} (${diags.len} found)')
}

// check_strict_fails runs the checker in `#:strict` mode (`blip check
// --strict`): the exhaustiveness warning becomes an error.
fn (mut s Suite) check_strict_fails(label string, src string, want_msg string) {
	diags := machine.check_text(src, true)
	for d in diags {
		if d.msg.contains(want_msg) && d.severity == 'error' {
			s.ok(label, 'strict reported: ${want_msg}')
			return
		}
	}
	s.fail(label, 'no strict error containing ${want_msg} (${diags.len} found)')
}

// check_manifest runs `check` on src with a manifest applied first, and
// demands a diagnostic containing want_msg -- or, when want_msg is empty,
// demands silence. The manifest is what E2b adds: without it the checker
// never names a capability, with `fs` off it names the blip.mod line.
fn (mut s Suite) check_manifest(label string, manifest_src string, src string, want_msg string) {
	h := host.new_capture()
	mut m := machine.new_standalone(h)
	mf := manifest.parse(manifest_src) or {
		s.fail(label, 'manifest: ${err.msg()}')
		return
	}
	m.apply_manifest(mf) or {
		s.fail(label, 'apply: ${err.msg()}')
		return
	}
	forms := m.arena.read_source(src, 'check')
	if forms.diags.len > 0 {
		s.fail(label, 'reader: ${forms.diags[0].msg}')
		return
	}
	diags := m.check_source(forms.forms)
	if want_msg == '' {
		if diags.len == 0 {
			s.ok(label, 'clean')
		} else {
			s.fail(label, 'unexpected: ${diags[0].msg}')
		}
		return
	}
	for d in diags {
		if d.msg.contains(want_msg) {
			s.ok(label, 'reported: ${want_msg}')
			return
		}
	}
	s.fail(label, 'no diagnostic containing ${want_msg} (${diags.len} found)')
}

fn main() {
	mut s := Suite{}

	// Runtime contracts: the design-doc example and its violation.
	s.run_ok('contract domain passes',
		'(define/contract (halve x) (->/c even?) (/ x 2)) (halve 8)', '4')
	s.run_fails('contract domain refuses',
		'(define/contract (halve x) (->/c even?) (/ x 2)) (halve 7)', 'contract')
	// Domain plus range, and the zero-argument range-only shape.
	s.run_ok('contract domain and range',
		'(define/contract (div2 a b) (->/c number? number? number?) (/ a b)) (div2 7 2)', '3.5')
	s.run_ok('contract result only', '(define/contract (one) (->/c integer?) 1) (one)', '1')
	s.run_fails('contract result refuses', '(define/contract (bad x) (->/c even? odd?) x) (bad 2)',
		'result')
	// Shape errors are define-time errors, not silent miscompilations.
	s.run_fails('contract count checked', '(define/contract (bad x y) (->/c even?) x)',
		'->/c has 1 contracts')
	s.run_fails('contract needs clause', '(define/contract (f x) (even? x) x)', '->/c')
	s.run_fails('contract needs simple params', '(define/contract (f a . r) (->/c even?) a)',
		'simple')
	s.run_fails('contract rejects labels', '(define/contract (f #:x [x 1]) (->/c even?) x)',
		'simple')
	// A domain-checked call is still a tail call: 5000 deep, no growth.
	s.run_ok('contract keeps tail calls',
		'(define/contract (countdown n) (->/c integer?) (if (= n 0) 0 (countdown (- n 1)))) (countdown 5000)',
		'0')
	// Annotations erase: the machine never sees them.
	s.run_ok('annotation runs', '(def (add (x int) (y int)) int (+ x y)) (add 1 2)', '3')
	s.run_ok('annotation lies at runtime', '(def (f (x int)) string x) (f 5)', '5')
	s.run_ok('contract with annotations',
		'(define/contract (h (x int)) (->/c even?) (/ x 2)) (h 8)', '4')

	// `blip check`: the clean file is silent.
	s.check_ok('check clean', '(def (add (x int) (y int)) int (+ x y)) (add 1 2)')
	s.check_ok('check unknown is silent', '(nosuchfn 1 2 "x") (map f xs)')
	s.check_ok('check unannotated is silent', '(def (f a b) (+ a b)) (f 1 2)')
	// `def` carries the annotated signatures (same erased types as before);
	// only `define/contract` keeps its `define`-prefixed spelling.
	s.check_ok('check def clean', '(def (add (x int) (y int)) int (+ x y)) (add 1 2)')
	s.check_fails('check def arg type', '(def (add (x int) (y int)) int (+ x y)) (add 1 "s")',
		'expects int for y, got string')
	// ... and the mismatches name names, positions aside (the CLI prints those).
	s.check_fails('check arity', '(def (add (x int) (y int)) int (+ x y)) (add 1)',
		'expects 2 arguments, got 1')
	s.check_fails('check arg type', '(def (add (x int) (y int)) int (+ x y)) (add 1 "s")',
		'expects int for y, got string')
	s.check_fails('check return', '(def (bad (x int)) string x)',
		'promises string, body gives int')
	s.check_fails('check stray contract', '(->/c even?)', '->/c outside define/contract')
	// A pattern shaped like a mis-aritied call is data, not a call.
	// Clauses are vectors; the else keeps the no-catch-all warning away
	// from what this pin is actually about.
	s.check_ok('check match pattern silent',
		'(def (add2 (a int) (b int)) int (+ a b)) (match v [(add2 x) x] [else 0])')
	// B3: match* arity. Two subjects, one pattern: the clause can never
	// match, so this is an error in both modes.
	s.check_fails('check match* arity', '(match* (list 1 2) [(x) x] [else 0])',
		'match* clause has 1 pattern(s) for 2 subject(s)')
	s.check_ok('check match* arity ok', '(match* (list 1 2) [(x y) (+ x y)] [else 0])')
	// B3/B6: light exhaustiveness. No else and no catch-all warns by
	// default; an else, a bare-symbol catch-all, or a match* all-symbols
	// row is exhaustive and silent; --strict errors.
	s.check_warns('check match warns when not exhaustive', "(match 5 [5 'five])",
		'not exhaustive')
	s.check_ok('check match else is exhaustive', "(match 5 [5 'five] [else 'other])")
	s.check_ok('check match catch-all is exhaustive', '(match 5 [5 0] [x x])')
	s.check_ok('check match* all-symbols row is exhaustive',
		'(match* (list 1 2) [(a b) a] [x x])')
	s.check_strict_fails('check strict match errors', "(match 5 [5 'five])",
		'not exhaustive')
	s.check_strict_fails('check strict match* errors',
		"(match* (list 1 2) [(1 2) 'hit])", 'not exhaustive')
	// The prim table: arithmetic over numbers, comparisons to bool.
	s.check_ok('check prim result', '(def (f) int (+ 1 2))')
	s.check_fails('check prim arg', '(+ 1 "s")', 'needs numbers')
	s.check_fails('check prim return', '(def (g) string (+ 1 2))',
		'promises string, body gives int')
	// Let-bound literals carry their type into the body.
	s.check_ok('check let tracks', '(def (f) int (let ([x 5]) x))')
	s.check_fails('check let mismatch', '(def (g) string (let ([x 5]) x))',
		'promises string, body gives int')
	// Contracted functions contribute arity, not types.
	s.check_ok('check contract call', '(define/contract (halve x) (->/c even?) (/ x 2)) (halve 8)')
	s.check_fails('check define removed', '(define x 1)', 'removed in v2')
	// A2 removals report through `check` too, each naming the canonical form.
	s.check_fails('check do removed', '(do 1 2)', 'removed in v2')
	s.check_fails('check lambda removed', '(lambda (x) x)', 'removed in v2')
	s.check_fails('check when removed', '(when #t 1)', 'removed in v2')
	s.check_fails('check case removed', '(case 5 [(1 2) 10])', 'removed in v2')
	s.check_fails('check first removed', '(first (quote (1 2)))', 'removed in v2')
	s.check_fails('check rest removed', '(rest (quote (1 2)))', 'removed in v2')
	s.check_fails('check contract arity',
		'(define/contract (halve x) (->/c even?) (/ x 2)) (halve 8 9)',
		'expects 1 arguments, got 2')
	// E2b: the manifest gates `check`. With `fs` off, a `read-file` use is
	// reported naming the blip.mod line that switched it off; with `fs`
	// on -- or no mention at all -- the same use is silence, because the
	// checker judges only what the manifest disables.
	s.check_manifest('check fs off names manifest', '(module m)\n(blip 2)\n(features (fs #f))',
		'(read-file "x")', 'blip.mod:3')
	s.check_manifest('check fs off names the feature', '(module m)\n(blip 2)\n(features (fs #f))',
		'(write-file "x" "y")', "feature 'fs' is off")
	s.check_manifest('check env off names manifest', '(module m)\n(blip 2)\n(features (env #f))',
		'(env "HOME")', 'blip.mod:3')
	s.check_manifest('check fs on stays silent', '(module m)\n(blip 2)\n(features (fs #t))',
		'(read-file "x")', '')
	s.check_manifest('check absent stays silent', '(module m)\n(blip 2)', '(read-file "x")', '')

	if s.fails > 0 {
		eprintln('${s.fails} contract check(s) failed')
		exit(1)
	}
	println('contracts: all checks passed')
}
