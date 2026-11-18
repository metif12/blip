module main

/* The M3 gate: proper tail calls.
 *
 * These are the properties the whole design rests on. Applying a closure must
 * NOT push a continuation frame, so a tail call -- including MUTUAL recursion --
 * is a loop iteration rather than a stack mutation. Steel needs a separate
 * TCOJMP opcode for this and still ships SELFTAILCALLNOARITY.
 *
 * Every depth here is large enough that a machine without real TCO would either
 * overflow or grow its continuation stack visibly.
 */

import blip
import blip.machine
import blip.printer
import blip.reader

fn check(label string, src string, expected string) {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		println('FAIL ${label}: ${res.diags.len} read errors')
		return
	}
	mut m := machine.new_machine(&res.arena)
	got := m.run(res.forms) or {
		println('FAIL ${label}: ${err.msg()}')
		return
	}
	text := printer.write(got)
	if text == expected {
		println('ok   ${label} => ${text}  (steps=${m.steps}, kont=${m.kstack.len})')
	} else {
		println('FAIL ${label}: expected ${expected}, got ${text}')
	}
}

fn main() {
	// 1. self tail call, 250,000 deep -- see the note below on the depth
	check('self tail call 250k', '
		(def (cd n acc)
		  (if (= n 0) acc (cd (- n 1) (+ acc 1))))
		(cd 250000 0)', '250000')

	// The depth here is 250,000 rather than 1,000,000, and the reason is not
	// doubt about the tail calls. Every call allocates an environment frame that
	// is never reclaimed, so a million iterations leave roughly three million
	// small objects for V's Boehm collector to trace at exit -- long enough that
	// the runner looked like it had hung after printing every result. 250,000
	// still makes the claim unambiguously: `kont=0` at the end is the property,
	// and a machine without real TCO reports 250,000 there.

	// 2. MUTUAL tail recursion. This is what separates a real trampoline from
	//    the cheaper hack of only special-casing self-calls.
	check('mutual tail call 2e4', '
		(def (ping n) (if (= n 0) (quote pong) (pong (- n 1))))
		(def (pong n) (if (= n 0) (quote ping) (ping (- n 1))))
		(ping 20000)', 'pong')

	// 3. tail position in a derived form (cond desugars to nested ifs)
	check('tail in cond 1e5', '
		(def (cd n acc)
		  (cond [(= n 0) acc]
		        [else (cd (- n 1) (+ acc 1))]))
		(cd 100000 0)', '100000')

	// 4. tail position in a let body
	check('tail in let', '
		(def (cd n acc)
		  (if (= n 0) acc (let ([m (- n 1)]) (cd m (+ acc 1)))))
		(cd 50000 0)', '50000')

	// 5. non-tail recursion still works
	check('non-tail fib', '
		(def (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
		(fib 20)', '6765')

	// 6. derived forms give the right answers
	{
		// `when` is gone in v2 (roadmap A2): the machine refuses with a
		// migration message, and this pins the message, not just failure.
		res_when := reader.read_all('(when #t 1)')
		mut m_when := machine.new_machine(&res_when.arena)
		if _ := m_when.run(res_when.forms) {
			println('FAIL when-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') {
				println('ok   when-removed => removed in v2')
			} else {
				println('FAIL when-removed: wrong error: ${err.msg()}')
			}
		}
	}
	check('unless', '(unless #f 2)', '2')
	check('cond-arrow', '(cond [(= 1 2) => (fn [] 0)] [else 7])', '7')
	{
		// `case` is gone in v2 (roadmap A2): the machine refuses with a
		// migration message, and this pins the message, not just failure.
		res_case := reader.read_all('(case 5 [(1 2) 10])')
		mut m_case := machine.new_machine(&res_case.arena)
		if _ := m_case.run(res_case.forms) {
			println('FAIL case-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') {
				println('ok   case-removed => removed in v2')
			} else {
				println('FAIL case-removed: wrong error: ${err.msg()}')
			}
		}
	}
	{
		// `lambda` and `λ` are gone in v2 (roadmap A2): one form, `fn`.
		res_lam := reader.read_all('(lambda (x) x)')
		mut m_lam := machine.new_machine(&res_lam.arena)
		if _ := m_lam.run(res_lam.forms) {
			println('FAIL lambda-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') {
				println('ok   lambda-removed => removed in v2')
			} else {
				println('FAIL lambda-removed: wrong error: ${err.msg()}')
			}
		}
	}
	{
		// `λ` is the same removal under its other spelling.
		res_uni := reader.read_all('(λ [x] x)')
		mut m_uni := machine.new_machine(&res_uni.arena)
		if _ := m_uni.run(res_uni.forms) {
			println('FAIL uni-lambda-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') {
				println('ok   uni-lambda-removed => removed in v2')
			} else {
				println('FAIL uni-lambda-removed: wrong error: ${err.msg()}')
			}
		}
	}
	{
		// `first`/`rest` are gone in v2 (roadmap A2): `car`/`cdr` are the
		// one spellings. They fail as prims, not special forms, but the
		// message still names the removal and the canonical name.
		res_first := reader.read_all('(first (quote (1 2)))')
		mut m_first := machine.new_machine(&res_first.arena)
		if _ := m_first.run(res_first.forms) {
			println('FAIL first-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') && err.msg().contains('car') {
				println('ok   first-removed => removed in v2')
			} else {
				println('FAIL first-removed: wrong error: ${err.msg()}')
			}
		}
	}
	{
		res_rest := reader.read_all('(rest (quote (1 2)))')
		mut m_rest := machine.new_machine(&res_rest.arena)
		if _ := m_rest.run(res_rest.forms) {
			println('FAIL rest-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') && err.msg().contains('cdr') {
				println('ok   rest-removed => removed in v2')
			} else {
				println('FAIL rest-removed: wrong error: ${err.msg()}')
			}
		}
	}
	{
		// `do` is gone in v2 (roadmap A2): `begin` is the one sequencing form.
		res_do := reader.read_all('(do 1 2)')
		mut m_do := machine.new_machine(&res_do.arena)
		if _ := m_do.run(res_do.forms) {
			println('FAIL do-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') {
				println('ok   do-removed => removed in v2')
			} else {
				println('FAIL do-removed: wrong error: ${err.msg()}')
			}
		}
	}
	{
		// `define` is gone in v2 (roadmap A2): one form, `def`.
		// `blip migrate` rewrites it; the machine refuses with a message.
		res_def := reader.read_all('(define x 1)')
		mut m_def := machine.new_machine(&res_def.arena)
		if _ := m_def.run(res_def.forms) {
			println('FAIL define-removed: expected a removal error, ran clean')
		} else {
			if err.msg().contains('removed in v2') {
				println('ok   define-removed => removed in v2')
			} else {
				println('FAIL define-removed: wrong error: ${err.msg()}')
			}
		}
	}
	check('loop', '(loop i 0 (< i 5) (print i)) 7', '7')
	check('dotimes', '(dotimes i 3 (print i)) 8', '8')
	check('and-short', '(and 1 #f 3)', '#f')
	check('and-value', '(and 1 2 3)', '3')
	check('or-value', '(or #f #f 7)', '7')
	// The three known failures this file used to name -- `let*`, rest
	// parameters, and callable keywords -- are fixed, and tests/binding_forms.v
	// covers them properly. A note describing a fixed bug is worse than no note,
	// so they are simply gone. The keyword call is kept here because it is one
	// line and it sits next to the other application tests.
	check('keyword-call', '(:a {:a 1})', '1')
	check('letstar', '(let* ([a 1] [b (+ a 1)]) b)', '2')
	check('rest-param', '(def (f a . r) r) (f 1 2 3)', '(2 3)')
	check('letrec', '(letrec ([e (fn [n] (if (= n 0) #t (o (- n 1))))] [o (fn [n] (if (= n 0) #f (e (- n 1))))]) (e 10))', '#t')

	// 2000, not 20000. The recursive call sits inside `or`, so one pending
	// continuation per level is live for the whole descent and the environment
	// frames are never reclaimed. The live heap therefore grows with the input,
	// and since every Boehm collection re-marks that heap, the wall clock is
	// quadratic: measured at 438 ms / 7.5 s / 28.8 s for 1k / 5k / 10k, with
	// 20k past two minutes. The stack still ends at kont=0 and the answer is
	// still right at 10k, so the property holds; it is the runtime cost that
	// does not. Reclaiming frames is a real piece of work and is listed in
	// docs/010-roadmap.md rather than hidden by picking a flattering number.
	check('tail-in-or', '
		(def (find n)
		  (or (and (= n 3) n) (if (> n 0) (find (- n 1)) 0)))
		(find 2000)', '3')

	// 7. deep non-tail recursion must fail loudly, never silently corrupt
	//
	// max_kont is lowered first, and on purpose. The property under test is "the
	// continuation limit is enforced", not "the limit is four million": proving
	// the real limit means actually building that many frames, and every frame
	// allocation makes the collector re-mark a heap the earlier tests already
	// grew. At the default the runner printed every result and then sat there,
	// which is indistinguishable from a hang.
	res := reader.read_all('(def (f n) (+ 1 (f n)))(f 10000000)')
	mut m := machine.new_machine(&res.arena)
	m.max_kont = 2_000
	m.run(res.forms) or {
		println('ok   deep non-tail rejected: ${err.msg()}')
		return
	}
	println('FAIL deep non-tail recursion was NOT rejected')
}
