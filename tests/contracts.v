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
	s.run_ok('annotation runs', '(define (add (x int) (y int)) int (+ x y)) (add 1 2)', '3')
	s.run_ok('annotation lies at runtime', '(define (f (x int)) string x) (f 5)', '5')
	s.run_ok('contract with annotations',
		'(define/contract (h (x int)) (->/c even?) (/ x 2)) (h 8)', '4')

	// `blip check`: the clean file is silent.
	s.check_ok('check clean', '(define (add (x int) (y int)) int (+ x y)) (add 1 2)')
	s.check_ok('check unknown is silent', '(nosuchfn 1 2 "x") (map f xs)')
	s.check_ok('check unannotated is silent', '(define (f a b) (+ a b)) (f 1 2)')
	// ... and the mismatches name names, positions aside (the CLI prints those).
	s.check_fails('check arity', '(define (add (x int) (y int)) int (+ x y)) (add 1)',
		'expects 2 arguments, got 1')
	s.check_fails('check arg type', '(define (add (x int) (y int)) int (+ x y)) (add 1 "s")',
		'expects int for y, got string')
	s.check_fails('check return', '(define (bad (x int)) string x)',
		'promises string, body gives int')
	s.check_fails('check stray contract', '(->/c even?)', '->/c outside define/contract')
	// A pattern shaped like a mis-aritied call is data, not a call.
	s.check_ok('check match pattern silent',
		'(define (add2 (a int) (b int)) int (+ a b)) (match v [(add2 x) x])')
	// The prim table: arithmetic over numbers, comparisons to bool.
	s.check_ok('check prim result', '(define (f) int (+ 1 2))')
	s.check_fails('check prim arg', '(+ 1 "s")', 'needs numbers')
	s.check_fails('check prim return', '(define (g) string (+ 1 2))',
		'promises string, body gives int')
	// Let-bound literals carry their type into the body.
	s.check_ok('check let tracks', '(define (f) int (let ([x 5]) x))')
	s.check_fails('check let mismatch', '(define (g) string (let ([x 5]) x))',
		'promises string, body gives int')
	// Contracted functions contribute arity, not types.
	s.check_ok('check contract call', '(define/contract (halve x) (->/c even?) (/ x 2)) (halve 8)')
	s.check_fails('check contract arity',
		'(define/contract (halve x) (->/c even?) (/ x 2)) (halve 8 9)',
		'expects 1 arguments, got 2')

	if s.fails > 0 {
		eprintln('${s.fails} contract check(s) failed')
		exit(1)
	}
	println('contracts: all checks passed')
}
