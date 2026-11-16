module main

import os
import rand

// tools/fuzz.vsh -- a mutation fuzzer for the reader and the machine.
//
// It is NOT a CI gate: it is non-deterministic by design, and a red run
// means "investigate", not "revert". Its job is to find the next panic
// before a user does. Every input is run in its OWN process, because the
// whole point of the panic net (drive's defer/recover) is that a wrong
// form must not take the interpreter down -- and a fuzzer that dies at the
// first panic can never tell you which one did it.
//
// Usage: v run tools/fuzz.vsh [iterations]   (default 200)

const crash_codes = [i32(0xC0000005), i32(0xC00000FD), i32(0xC0000409), i32(0xC0000374), i32(3)]

fn crashed(res os.Result) bool {
	return res.exit_code < 0 || i32(res.exit_code) in crash_codes
		|| res.output.contains('V panic') || res.output.contains('gcc: internal')
}

fn mutate(src string) string {
	mut b := src.bytes()
	if b.len == 0 {
		return src
	}
	r := rand.intn(3) or { 0 }
	if r == 0 {
		idx := rand.intn(b.len) or { 0 }
		b.delete(idx)
	} else if r == 1 {
		idx := rand.intn(b.len) or { 0 }
		b.insert(idx, b[idx])
	} else {
		mut out := b.clone()
		mut done := false
		for _ in 0 .. 5 {
			idx := rand.intn(out.len) or { 0 }
			if out[idx] == u8(40) {
				out[idx] = u8(41)
				done = true
				break
			}
			if out[idx] == u8(41) {
				out[idx] = u8(40)
				done = true
				break
			}
			if out[idx] == u8(91) {
				out[idx] = u8(93)
				done = true
				break
			}
			if out[idx] == u8(93) {
				out[idx] = u8(91)
				done = true
				break
			}
		}
		if done {
			b = out.clone()
		}
	}
	return b.bytestr()
}

fn main() {
	mut iters := 200
	args := os.args[1..]
	if args.len > 0 {
		iters = args[0].int()
	}
	blip_bin := if os.exists('blip.exe') { 'blip.exe' } else { 'blip' }
	if !os.exists(blip_bin) {
		println('no blip binary beside the fuzzer; build it first')
		return
	}
	mut corpus := []string{}
	for f in os.ls('examples') or { [] } {
		if f.ends_with('.lip') {
			corpus << os.read_file(os.join_path('examples', f)) or { '' }
		}
	}
	for f in os.ls('programs') or { [] } {
		if f.ends_with('.lip') {
			corpus << os.read_file(os.join_path('programs', f)) or { '' }
		}
	}
	if corpus.len == 0 {
		println('no seed corpus found')
		return
	}
	os.mkdir_all('tmp/fuzz') or {}
	mut crashes := 0
	mut i := 0
	for i < iters {
		base := corpus[rand.intn(corpus.len) or { 0 }]
		input := mutate(base)
		path := os.join_path('tmp', 'fuzz', 'case.lip')
		os.write_file(path, input) or { i++; continue }
		res := os.execute('${blip_bin} run "${path}"')
		if crashed(res) {
			crashes++
			println('CRASH #${i}: exit ${res.exit_code}')
			println('--- input ---')
			println(input)
			println('--- output ---')
			println(res.output)
			os.write_file(os.join_path('tmp', 'fuzz', 'crash_${i}.lip'), input) or {}
		}
		if i % 50 == 0 {
			println('progress: ${i}/${iters}, crashes so far: ${crashes}')
		}
		i++
	}
	println('fuzz: ${iters} iterations, ${crashes} crash(es)')
	if crashes > 0 {
		println('reproducers saved under tmp/fuzz/crash_*.lip')
	}
}
