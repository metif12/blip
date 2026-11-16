module main

import os
import blip.pkg

// The collaboration gate (roadmap Track G: G1 resolution, G2 verified
// installs, G5 workspaces).
//
// Everything networked goes through git, and git works against local
// paths -- so the "mirror" is a directory of local repos and the whole
// suite runs offline. BLIP_PKG_MIRROR points the package URL there, the
// same seam a private mirror would use.
//
// What this gate proves, in order:
//   * G1: root wants acme/db >=1.0.0, client wants =1.2.0, server wants
//     >=1.1.0 -- three requesters, one pin (1.2.0), and the installed
//     content is the 1.2.0 content, not 1.0.0.
//   * G5: two members plus a path dep install from one universe; a program
//     spanning a member, two remotes, and the path copy runs; a clean-room
//     copy reproduces the identical lock and runs too.
//   * G2: tampering an installed file fails `verify` and a reinstall
//     with a checksum error, loudly.
//   * The git-backed module helpers behave (tags, clone, checkout).

struct Suite {
mut:
	fails  int
	checks int
}

fn (mut s Suite) record(label string, ok bool, detail string) {
	s.checks++
	if ok {
		println('ok   ${label} => ${detail}')
	} else {
		s.fails++
		println('FAIL ${label} => ${detail}')
	}
}

fn snippet(text string) string {
	t := text.trim_space().replace('\n', ' / ')
	if t.len > 120 {
		return t[..120]
	}
	return t
}

fn crashed(res os.Result) bool {
	return res.exit_code < 0 || res.output.contains('V panic')
}

// git runs one git command in dir, quoted for spaces.
fn git(dir string, args string) os.Result {
	return os.execute('git -C "${dir}" ${args}')
}

// mk_repo builds a local package repo: one commit per tag, each tag with
// its own blip.blip content, so the suite can tell which tag got pinned
// by reading the installed file.
fn (mut s Suite) mk_repo(dir string, versions []string, contents []string) {
	os.mkdir_all(dir) or {
		s.record('mk_repo ${dir}', false, 'mkdir: ${err.msg()}')
		return
	}
	os.execute('git init --quiet "${dir}"')
	for i, tag in versions {
		os.write_file(os.join_path(dir, 'blip.blip'), contents[i]) or {
			s.record('mk_repo ${tag}', false, 'write: ${err.msg()}')
			return
		}
		os.execute('git -C "${dir}" add -A')
		r := os.execute('git -C "${dir}" -c user.name=t -c user.email=t@t commit --quiet -m "${tag}"')
		if r.exit_code != 0 {
			s.record('mk_repo ${tag}', false, 'commit: ${snippet(r.output)}')
			return
		}
		t := os.execute('git -C "${dir}" tag "${tag}"')
		if t.exit_code != 0 {
			s.record('mk_repo ${tag}', false, 'tag: ${snippet(t.output)}')
			return
		}
	}
	s.record('mk_repo ${dir}', true, '${versions.len} tags')
}

fn main() {
	mut s := Suite{}

	blip_bin := if os.exists('blip.exe') { os.real_path('blip.exe') } else { os.real_path('blip') }
	if !os.exists(blip_bin) {
		println('FAIL => no blip binary beside the suite; build it first')
		println('pkg_cli: 0 checks, 1 FAILURE')
		return
	}

	base := os.join_path(os.temp_dir(), 'blip_pkg_cli')
	os.rmdir_all(base) or {}
	mirror := os.join_path(base, 'mirror')
	work := os.join_path(base, 'work')
	os.mkdir_all(work) or {
		println('FAIL setup => cannot mkdir: ${err.msg()}')
		return
	}

	// The mirror: two remotes with real tags.
	s.mk_repo(os.join_path(mirror, 'acme/db'), ['v1.0.0', 'v1.2.0'], [
		'(def db-version "1.0.0")\n(def (db-get) db-version)\n',
		'(def db-version "1.2.0")\n(def (db-get) db-version)\n',
	])
	s.mk_repo(os.join_path(mirror, 'acme/log'), ['v0.9.0'], [
		'(def log-version "0.9.0")\n',
	])

	// The git-backed helpers, in process against the mirror.
	tags := pkg.list_remote_tags(os.join_path(mirror, 'acme/db')) or {
		s.record('list_remote_tags', false, err.msg())
		map[string]string{}
	}
	s.record('list_remote_tags', 'v1.0.0' in tags && 'v1.2.0' in tags, 'two tags')
	scratch := os.join_path(base, 'scratch')
	pkg.ensure_cloned(os.join_path(mirror, 'acme/db'), scratch) or {
		s.record('ensure_cloned', false, err.msg())
	}
	if 'v1.2.0' in tags {
		pkg.checkout_sha(scratch, tags['v1.2.0']) or {
			s.record('checkout_sha', false, err.msg())
		}
		s.record('head_sha follows checkout', pkg.head_sha(scratch) == tags['v1.2.0'], 'detached at pin')
		pkg.fetch_all(scratch) or { s.record('fetch_all', false, err.msg()) }
		s.record('fetch_all', true, 'tags refreshed')
	}

	// The workspace: root plus two members plus a path dep.
	os.mkdir_all(os.join_path(work, 'client')) or {}
	os.mkdir_all(os.join_path(work, 'server')) or {}
	os.mkdir_all(os.join_path(work, 'shared')) or {}
	os.write_file(os.join_path(work, 'blip.mod'),
		'(module shop)\n(blip 2)\n(deps (acme/db ">=1.0.0"))\n(workspace (members client server))') or {}
	os.write_file(os.join_path(work, 'client/blip.mod'),
		'(module client)\n(blip 2)\n(deps (acme/db "=1.2.0"))') or {}
	os.write_file(os.join_path(work, 'client/blip.blip'), '(def (client-x) 1)\n') or {}
	os.write_file(os.join_path(work, 'server/blip.mod'),
		'(module server)\n(blip 2)\n(deps (acme/db ">=1.1.0") (acme/log "0.9.0") (shop/shared "path:../shared"))') or {}
	os.write_file(os.join_path(work, 'server/blip.blip'),
		'(import "acme/db")\n(import "acme/log")\n(require "../shared/blip.blip")\n(def (server-main) (string-append (db-get) "+" log-version "+" (shared-hello)))\n') or {}
	os.write_file(os.join_path(work, 'shared/blip.blip'), '(def (shared-hello) "shared")\n') or {}
	os.write_file(os.join_path(work, 'prog.blip'),
		'(require "server/blip.blip")\n(print (server-main))\n') or {}

	old_mirror := os.getenv('BLIP_PKG_MIRROR')
	os.setenv('BLIP_PKG_MIRROR', mirror, true)
	prev := os.getwd()
	os.chdir(work) or {
		println('FAIL setup => cannot chdir: ${err.msg()}')
		return
	}

	// G1: three requesters, one pin.
	upd := os.execute('${blip_bin} pkg update')
	s.record('pkg update exits 0', upd.exit_code == 0, snippet(upd.output))
	locked := pkg.read_lock('.')
	mut db_pin := pkg.Pin{}
	if p := pkg.pin_of(locked, 'acme/db') {
		db_pin = p
	} else {
		s.record('G1 db pinned', false, 'acme/db missing from lock')
	}
	s.record('G1 three reqs one pin', db_pin.ref == 'v1.2.0', 'ref=${db_pin.ref}')
	s.record('G1 lock has log', pkg.pin_of(locked, 'acme/log') != none, 'log pinned')
	s.record('G1 lock has path dep', pkg.pin_of(locked, 'shop/shared') != none
		&& (pkg.pin_of(locked, 'shop/shared') or { pkg.Pin{} }).ref == 'path:shared', 'shared copied')
	db_src := os.read_file('blip_modules/acme/db/blip.blip') or { '' }
	s.record('G1 installed content is the pin', db_src.contains('"1.2.0"'), snippet(db_src))
	s.record('G1 path copy installed', os.exists('blip_modules/shop/shared/blip.blip'), 'shared copied')
	lock_once := os.read_file('blip.lock') or { '' }
	upd2 := os.execute('${blip_bin} pkg update')
	lock_twice := os.read_file('blip.lock') or { '' }
	s.record('G1 update deterministic', upd2.exit_code == 0 && lock_once == lock_twice
		&& lock_once != '', 'identical lock bytes')

	// G5: the spanning program runs; clean room reproduces.
	ver := os.execute('${blip_bin} pkg verify')
	s.record('pkg verify clean', ver.exit_code == 0, snippet(ver.output))
	run := os.execute('${blip_bin} run prog.blip')
	s.record('G5 spanning program runs', run.exit_code == 0
		&& run.output.contains('1.2.0+0.9.0+shared'), snippet(run.output))

	clean := os.join_path(base, 'clean')
	pkg.copy_package('.', clean) or { s.record('G5 clean-room copy', false, err.msg()) }
	os.rmdir_all(os.join_path(clean, 'blip_modules')) or {}
	os.chdir(clean) or {
		s.record('G5 clean-room', false, 'chdir clean: ${err.msg()}')
	}
	inst := os.execute('${blip_bin} pkg install')
	s.record('G5 clean-room install', inst.exit_code == 0, snippet(inst.output))
	s.record('G5 lock identical', (os.read_file('blip.lock') or { '' }) == lock_once
		&& lock_once != '', 'reproduced')
	run2 := os.execute('${blip_bin} run prog.blip')
	s.record('G5 clean-room runs', run2.exit_code == 0
		&& run2.output.contains('1.2.0+0.9.0+shared'), snippet(run2.output))

	// G2: tamper, then verify and reinstall fail loudly.
	os.chdir(work) or {}
	os.write_file('blip_modules/acme/db/blip.blip', db_src + '; tampered\n') or {}
	bad_ver := os.execute('${blip_bin} pkg verify')
	s.record('G2 verify fails on tamper', bad_ver.exit_code == 1
		&& bad_ver.output.contains('checksum mismatch'), snippet(bad_ver.output))
	bad_inst := os.execute('${blip_bin} pkg install acme/db')
	s.record('G2 reinstall fails on tamper', bad_inst.exit_code == 1
		&& bad_inst.output.contains('checksum'), snippet(bad_inst.output))

	// install_one/remove_one through the module, in a scratch project.
	r2 := os.join_path(base, 'r2')
	os.mkdir_all(r2) or {}
	p := pkg.install_one(r2, 'acme/log@v0.9.0') or {
		s.record('install_one', false, err.msg())
		pkg.Pin{}
	}
	s.record('install_one pins', p.ref == 'v0.9.0' && p.sha != '', '${p.ref} ${p.sha}')
	n := pkg.remove_one(r2, 'acme/log') or {
		s.record('remove_one', false, err.msg())
		''
	}
	s.record('remove_one drops the pin', n == 'acme/log'
		&& pkg.pin_of(pkg.read_lock(r2), 'acme/log') == none, 'gone')

	os.chdir(prev) or {}
	os.setenv('BLIP_PKG_MIRROR', old_mirror, true)
	os.rmdir_all(base) or {}

	if s.fails > 0 {
		println('${s.checks} checks, ${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('pkg_cli: all ${s.checks} checks passed')
}
