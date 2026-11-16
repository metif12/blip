module main

import os
import blip.pkg
import blip.toolchain

// The project-lifecycle gate (roadmap Track G: G6 new/init, G3 tool
// installs). Everything runs in temp dirs, and the git-backed package
// source is a local mirror repo -- the same offline seam as pkg_cli.v.

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

fn (mut s Suite) mk_repo(dir string, tag string, files map[string]string) {
	os.mkdir_all(dir) or {
		s.record('mk_repo ${dir}', false, 'mkdir: ${err.msg()}')
		return
	}
	os.execute('git init --quiet "${dir}"')
	for path, content in files {
		os.write_file(os.join_path(dir, path), content) or {
			s.record('mk_repo ${tag}', false, 'write: ${err.msg()}')
			return
		}
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
	s.record('mk_repo ${dir}', true, tag)
}

fn main() {
	mut s := Suite{}

	blip_bin := if os.exists('blip.exe') { os.real_path('blip.exe') } else { os.real_path('blip') }
	if !os.exists(blip_bin) {
		println('FAIL => no blip binary beside the suite; build it first')
		println('project: 0 checks, 1 FAILURE')
		return
	}
	blip_home := os.dir(blip_bin)

	base := os.join_path(os.temp_dir(), 'blip_project')
	os.rmdir_all(base) or {}
	os.mkdir_all(base) or {
		println('FAIL setup => cannot mkdir: ${err.msg()}')
		return
	}
	prev := os.getwd()
	os.chdir(base) or {
		println('FAIL setup => cannot chdir: ${err.msg()}')
		return
	}

	// ---- G6: new scaffolds a project that runs and tests clean --------
	r := os.execute('${blip_bin} new hello')
	s.record('new scaffolds', r.exit_code == 0 && r.output.contains('created'), snippet(r.output))
	s.record('new writes blip.mod', os.read_file('hello/blip.mod') or { '' }.contains('(module hello)'),
		'module hello')
	os.chdir('hello') or {
		println('FAIL setup => cannot chdir hello')
		return
	}
	run := os.execute('${blip_bin} run main.blip')
	s.record('new project runs', run.exit_code == 0 && run.output.contains('hello, world'),
		snippet(run.output))
	tst := os.execute('${blip_bin} test main.blip')
	s.record('new project tests', tst.exit_code == 0 && tst.output.contains('expectations passed'),
		snippet(tst.output))
	os.chdir(base) or {}
	dup := os.execute('${blip_bin} new hello')
	s.record('new refuses existing', dup.exit_code != 0, snippet(dup.output))

	// ---- G6: init tops up an existing directory without clobbering -----
	os.mkdir_all('started') or {}
	os.write_file('started/stray.txt', 'mine\n') or {}
	os.chdir('started') or {}
	init := os.execute('${blip_bin} init myapp')
	s.record('init scaffolds', init.exit_code == 0, snippet(init.output))
	s.record('init keeps user files', os.exists('stray.txt'), 'stray kept')
	s.record('init names the module', os.read_file('blip.mod') or { '' }.contains('(module myapp)'),
		'module myapp')
	run2 := os.execute('${blip_bin} run main.blip')
	tst2 := os.execute('${blip_bin} test main.blip')
	s.record('init project runs', run2.exit_code == 0, snippet(run2.output))
	s.record('init project tests', tst2.exit_code == 0 && tst2.output.contains('expectations passed'),
		snippet(tst2.output))
	again := os.execute('${blip_bin} init')
	s.record('init is idempotent', again.exit_code == 0 && again.output.contains('already a blip project'),
		snippet(again.output))
	os.chdir(base) or {}
	os.mkdir_all('noname') or {}
	os.chdir('noname') or {}
	os.execute('${blip_bin} init')
	s.record('init defaults to dir name',
		os.read_file('blip.mod') or { '' }.contains('(module noname)'), 'module noname')
	os.chdir(base) or {}

	// ---- G3: install links a package tool onto PATH --------------------
	mirror := os.join_path(base, 'mirror')
	s.mk_repo(os.join_path(mirror, 'acme/greet'), 'v1.0.0', {
		'blip.mod':  '(module acme/greet)\n(blip 2)\n(tools (greet "tool.blip"))\n',
		'tool.blip': '(print "greetings from greet")\n',
	})
	s.mk_repo(os.join_path(mirror, 'acme/fortune'), 'v1.0.0', {
		'tool.blip': '(print "a fortune")\n',
	})
	os.mkdir_all('tools') or {}
	os.chdir('tools') or {}
	old_mirror := os.getenv('BLIP_PKG_MIRROR')
	os.setenv('BLIP_PKG_MIRROR', mirror, true)
	inst := os.execute('${blip_bin} install acme/greet')
	s.record('install links tools', inst.exit_code == 0 && inst.output.contains('installed greet'),
		snippet(inst.output))
	// The default convention: no stanza, root tool.blip, repo-named tool.
	inst2 := os.execute('${blip_bin} install acme/fortune')
	s.record('install defaults to tool.blip', inst2.exit_code == 0
		&& inst2.output.contains('installed fortune'), snippet(inst2.output))
	bindir := os.real_path(os.join_path('.blip', 'bin'))
	s.record('install writes both wrappers',
		os.exists(os.join_path(bindir, 'greet')) && os.exists(os.join_path(bindir, 'greet.bat')),
		'POSIX + batch')
	// From PATH: the tool resolves through the wrapper, not the suite.
	os.setenv('PATH', bindir + os.path_delimiter + blip_home + os.path_delimiter + os.getenv('PATH'),
		true)
	$if windows {
		got := os.execute('greet.bat')
		s.record('tool runs from PATH', got.exit_code == 0 && got.output.contains('greetings from greet'),
			snippet(got.output))
	} $else {
		got := os.execute('greet')
		s.record('tool runs from PATH', got.exit_code == 0 && got.output.contains('greetings from greet'),
			snippet(got.output))
	}
	// In-process: install_tool names both wrappers for the facade.
	w2 := os.join_path(base, 'tools2')
	os.mkdir_all(w2) or {}
	tools := pkg.install_tool(w2, 'acme/greet@v1.0.0') or {
		s.record('install_tool module', false, err.msg())
		[]pkg.InstalledTool{}
	}
	s.record('install_tool module', tools.len == 1 && os.exists(tools[0].sh)
		&& os.exists(tools[0].bat), if tools.len == 1 { tools[0].name } else { 'no tools' })

	// ---- G4: two toolchains side by side, per-project pins ---------------
	// A second version is a second binary: rebuild with the fixture flag
	// so `version` genuinely differs, then ship both as release artifacts
	// in a local release base (no network, same seam as BLIP_PKG_MIRROR).
	// NOTE: the build runs unquoted through cmd, so every path here must
	// be space-free (temp dirs are); spaces fail loudly below, not weirdly.
	repo := prev
	if repo.contains(' ') || base.contains(' ') {
		s.record('G4 paths spaceless', false, 'spaces would break cmd quoting')
		return
	}
	src2 := os.join_path(base, 'src2')
	os.mkdir_all(src2) or {}
	bin_name := toolchain.binary_name()
	os.chdir(repo) or {}
	fx := os.execute('v -d fixture_version_2 -cc gcc -path vlib^|@vlib -o ${src2}/${bin_name} main.v')
	os.chdir(base) or {}
	s.record('G4 fixture binary builds', fx.exit_code == 0, snippet(fx.output))
	art := toolchain.artifact_file()
	rb := os.join_path(base, 'releases')
	os.mkdir_all(os.join_path(rb, 'v0.1.0')) or {}
	os.mkdir_all(os.join_path(rb, 'v0.2.0-fixture')) or {}
	os.execute('tar -a -cf "${rb}/v0.1.0/${art}" -C "${blip_home}" "${bin_name}"')
	os.execute('tar -a -cf "${rb}/v0.2.0-fixture/${art}" -C "${src2}" "${bin_name}"')
	thome := os.join_path(base, 'thome')
	old_blip_home := os.getenv('BLIP_HOME')
	os.setenv('BLIP_HOME', thome, true)
	old_rel_base := os.getenv('BLIP_RELEASE_BASE')
	os.setenv('BLIP_RELEASE_BASE', rb, true)
	i1 := os.execute('${blip_bin} toolchain install 0.1.0')
	s.record('G4 install 0.1.0', i1.exit_code == 0 && os.exists(os.join_path(thome,
		'versions/0.1.0/${bin_name}')), snippet(i1.output))
	i2 := os.execute('${blip_bin} toolchain install 0.2.0-fixture')
	s.record('G4 install 0.2.0-fixture', i2.exit_code == 0, snippet(i2.output))
	s.record('G4 lib snapshots beside the binary',
		os.exists(os.join_path(thome, 'versions/0.2.0-fixture/lib/std.blip')), 'std.blip')
	os.chdir(base) or {}
	os.mkdir_all('projA/sub') or {}
	os.mkdir_all('projB') or {}
	os.chdir('projA') or {}
	os.execute('${blip_bin} toolchain use 0.2.0-fixture')
	os.chdir(os.join_path(base, 'projB')) or {}
	os.execute('${blip_bin} toolchain use 0.1.0')
	def := os.execute('${blip_bin} toolchain default 0.1.0')
	s.record('G4 default sets', def.exit_code == 0, snippet(def.output))
	lst := os.execute('${blip_bin} toolchain list')
	s.record('G4 list shows both', lst.output.contains('0.1.0') && lst.output.contains('0.2.0-fixture'),
		snippet(lst.output))
	shim := os.execute('${blip_bin} toolchain shim')
	s.record('G4 shim installs', shim.exit_code == 0, snippet(shim.output))
	os.setenv('PATH', os.join_path(thome, 'bin') + os.path_delimiter + os.getenv('PATH'), true)
	os.chdir(os.join_path(base, 'projA')) or {}
	va := os.execute('blip version')
	s.record('G4 pin selects A', va.exit_code == 0 && va.output.contains('0.2.0-fixture'),
		snippet(va.output))
	os.chdir('sub') or {}
	vsub := os.execute('blip version')
	s.record('G4 pin applies in subdirs', vsub.exit_code == 0
		&& vsub.output.contains('0.2.0-fixture'), snippet(vsub.output))
	os.chdir(os.join_path(base, 'projB')) or {}
	vb := os.execute('blip version')
	s.record('G4 pin selects B', vb.exit_code == 0 && vb.output.contains('blip 0.1.0'),
		snippet(vb.output))
	os.setenv('BLIP_VERSION', '0.1.0', true)
	os.chdir(os.join_path(base, 'projA')) or {}
	ve := os.execute('blip version')
	s.record('G4 env wins over pin', ve.exit_code == 0 && ve.output.contains('blip 0.1.0'),
		snippet(ve.output))
	os.setenv('BLIP_VERSION', '', true)
	os.chdir(os.join_path(base, 'projB')) or {}
	rm := os.execute('${blip_bin} toolchain remove 0.2.0-fixture')
	s.record('G4 remove drops a version', rm.exit_code == 0
		&& !os.is_dir(os.join_path(thome, 'versions/0.2.0-fixture')), snippet(rm.output))
	os.setenv('BLIP_HOME', old_blip_home, true)
	os.setenv('BLIP_RELEASE_BASE', old_rel_base, true)
	os.chdir(prev) or {}
	os.setenv('BLIP_PKG_MIRROR', old_mirror, true)
	os.rmdir_all(base) or {}

	if s.fails > 0 {
		println('${s.checks} checks, ${s.fails} FAILURE(S)')
		exit(1)
		return
	}
	println('project: all ${s.checks} checks passed')
}
