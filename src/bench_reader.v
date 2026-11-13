module main

// Reader benchmark: lexing + reading throughput per input shape.
//
// Usage: v -cc gcc -path 'vlib|@vlib' -o bench_reader src/bench_reader.v
//        ./bench_reader [iters]
// Reports best-of-3 MB/s and forms/s for: identifiers, integers, strings,
// comments, mixed (real corpus), quoted forms. The corpus files are read
// from disk, so run from the repo root.
//
// Numbers are for comparing reader revisions against each other on one
// machine, not across machines: same binary flags, same inputs, best of 3.
import os
import time
import blip.reader

fn repeat(s string, n int) string {
	mut out := []u8{cap: s.len * n}
	for _ in 0 .. n {
		out << s.bytes()
	}
	return out.bytestr()
}

fn bench_one(label string, src string, iters int) {
	forms0 := reader.read_all(src).forms.len
	_ = reader.read_all(src) // warmup (page in, steady GC)
	mut best := i64(9223372036854775807)
	for _ in 0 .. 3 {
		start := time.now().unix_nano()
		mut n := 0
		for _ in 0 .. iters {
			r := reader.read_all(src)
			n += r.forms.len
		}
		if n == 0 {
			println('unreachable')
		}
		el := time.now().unix_nano() - start
		if el < best {
			best = el
		}
	}
	secs := f64(best) / 1e9
	mbs := f64(src.len * iters) / (1024.0 * 1024.0) / secs
	fps := f64(forms0 * iters) / secs
	println('${label}: ${src.len} bytes x${iters} in ${secs:.3f}s best-of-3 => ${mbs:.2f} MB/s, ${fps:.0f} forms/s (${forms0} forms)')
}

fn main() {
	iters := if os.args.len > 1 { os.args[1].int() } else { 5 }
	if iters <= 0 {
		eprintln('bench_reader: iters must be positive')
		exit(1)
	}

	ident := '(' + repeat('foo-bar123 ', 200000) + ')'
	bench_one('identifier', ident, iters)

	nums := '(' + repeat('1234567890 ', 200000) + ')'
	bench_one('integers  ', nums, iters)

	strs := '(' + repeat('"hello world, this is a string" ', 100000) + ')'
	bench_one('string    ', strs, iters)

	comments := repeat('; a comment line to skip over\n', 100000) + '(ok 1)\n'
	bench_one('comment   ', comments, iters)

	longstr := '(' + repeat('"' + 'x'.repeat(10000) + '" ', 100) + ')'
	bench_one('longstr   ', longstr, iters)

	quoted := repeat('\'(a b (c d) 1 2.5 "s" :k)', 50000)
	bench_one('quoted    ', quoted, iters)

	mut corpus := ''
	for f in ['lib/std.lip', 'examples/01_basics.lip', 'examples/02_data.lip',
		'examples/03_match.lip', 'examples/04_errors.lip', 'examples/05_pipelines.lip',
		'examples/06_modules.lip', 'examples/07_config.lip', 'programs/brainfuck.lip',
		'programs/json.lip'] {
		corpus += os.read_file(f) or {
			eprintln('bench_reader: cannot read ${f}')
			exit(1)
		}
		corpus += '\n'
	}
	bench_one('mixed     ', repeat(corpus, 20), iters)
}
