// vlib/blip/toolchain/mod.v -- self-management (roadmap Track G4).
//
// blip installs and manages itself: version switching and virtualenv-style
// isolation. Versions live in `<home>/versions/<version>/` (home is
// $BLIP_HOME when set, else ~/.blip); `<home>/bin/blip` is a shim that
// resolves the version per directory and execs it; a `.blip-version` file
// pins a project, $BLIP_VERSION overrides everything, and a `<home>/default`
// file is the fallback. Installing starts against the current release
// layout (a binary tarball/zip plus the running blip's lib and programs),
// and grows with Track F as formats are added.
//
// Layout decision (roadmap open question, decided here): versions are
// directories named by version under one home; shims resolve by walking
// upward from the cwd for `.blip-version`, exactly like the manifest
// lookup a project expects in subdirectories. Nothing is on PATH except
// the shim dir, so two versions truly sit side by side.
module toolchain

import os

// pin_file names the per-project version pin, read upward from the cwd.
pub const pin_file = '.blip-version'

// home answers the blip home: $BLIP_HOME when set (portable, and what the
// fixtures point at a temp dir with), else ~/.blip.
// stability: internal
pub fn home() string {
	m := os.getenv('BLIP_HOME')
	if m != '' {
		return m
	}
	return os.join_path(os.home_dir(), '.blip')
}

// versions_dir holds one directory per installed version.
// stability: internal
pub fn versions_dir() string {
	return os.join_path(home(), 'versions')
}

// version_dir is where one version lives: its binary plus lib/ and
// programs/ beside it, the same shape resource_path expects.
// stability: internal
pub fn version_dir(version string) string {
	return os.join_path(versions_dir(), version)
}

// bin_dir holds the shims. One dir on PATH covers every version.
// stability: internal
pub fn bin_dir() string {
	return os.join_path(home(), 'bin')
}

// binary_name is the executable leaf on this platform.
// stability: internal
pub fn binary_name() string {
	$if windows {
		return 'blip.exe'
	} $else {
		return 'blip'
	}
}

// artifact_file is the release artifact for this platform, matching
// release.yml: a zip on Windows, a tarball elsewhere.
// stability: internal
pub fn artifact_file() string {
	$if windows {
		return 'blip-windows.zip'
	} $else {
		return 'blip-linux.tar.gz'
	}
}

// release_url maps a version to its artifact. $BLIP_RELEASE_BASE retargets
// the github release dir at a local directory (offline fixtures, private
// mirrors), mirroring what BLIP_PKG_MIRROR does for packages.
// stability: internal
pub fn release_url(version string) string {
	mut base := os.getenv('BLIP_RELEASE_BASE')
	if base == '' {
		base = 'https://github.com/metif12/blip/releases/download'
	}
	return base + '/v' + version + '/' + artifact_file()
}

// Pin is a resolved version: which one, and which file named it.
pub struct Pin {
pub:
	version string
	file    string
}

// find_pin walks upward from start for a `.blip-version` file, so a pin
// applies in subdirectories too -- the virtualenv behavior. The first
// (nearest) file wins; its content is the version, trimmed.
// stability: internal
pub fn find_pin(start string) ?Pin {
	mut d := os.real_path(start)
	for {
		cand := os.join_path(d, pin_file)
		if os.exists(cand) {
			v := os.read_file(cand) or { '' }
			t := v.trim_space()
			if t != '' {
				return Pin{
					version: t
					file:    cand
				}
			}
		}
		parent := os.dir(d)
		if parent == d {
			return none
		}
		d = parent
	}
}

// use_version pins dir at version. The version must already be installed:
// pinning thin air produces a project whose every command fails at the
// shim, far from the typo that caused it.
// stability: internal
pub fn use_version(dir string, version string) ! {
	dst := os.join_path(version_dir(version), binary_name())
	if !os.exists(dst) {
		return error('blip: version ${version} is not installed (see `blip toolchain list`)')
	}
	os.write_file(os.join_path(dir, pin_file), version)!
}

// read_default answers the fallback version, or none.
// stability: internal
pub fn read_default() ?string {
	p := os.join_path(home(), 'default')
	if !os.exists(p) {
		return none
	}
	t := os.read_file(p) or { return none }
	if t.trim_space() == '' {
		return none
	}
	return t.trim_space()
}

// write_default records the fallback version. It must be installed, for
// the same reason a pin must be.
// stability: internal
pub fn write_default(version string) ! {
	dst := os.join_path(version_dir(version), binary_name())
	if !os.exists(dst) {
		return error('blip: version ${version} is not installed (see `blip toolchain list`)')
	}
	os.mkdir_all(home())!
	os.write_file(os.join_path(home(), 'default'), version)!
}

// installed_versions lists installed versions, sorted.
// stability: internal
pub fn installed_versions() []string {
	mut out := []string{}
	for e in os.ls(versions_dir()) or { return out } {
		if os.is_dir(os.join_path(versions_dir(), e)) {
			out << e
		}
	}
	out.sort()
	return out
}

// remove_version deletes a version. The default refuses to go: removing
// the fallback out from under the shim breaks every unpinned directory
// at once, and that deserves an explicit re-default first.
// stability: internal
pub fn remove_version(version string) ! {
	if d := read_default() {
		if d == version {
			return error('blip: version ${version} is the default; default another first')
		}
	}
	dir := version_dir(version)
	if !os.is_dir(dir) {
		return error('blip: version ${version} is not installed')
	}
	os.rmdir_all(dir)!
}

// unpack extracts a release artifact with the system tar, which reads both
// tarballs and zips on every platform blip ships (bsdtar on Windows,
// libarchive tar elsewhere). Shelling out keeps blip free of an archive
// dependency for a job that runs once per install.
// stability: internal
pub fn unpack(artifact string, dest string) ! {
	os.mkdir_all(dest)!
	r := os.exec(['tar', 'xf', artifact, '-C', dest])
	if r.exit_code != 0 {
		return error('blip: cannot unpack ${artifact}: ${r.output.trim_space()}')
	}
}

// install_from_artifact assembles a version from an unpacked-or-local
// artifact tree: the platform binary moves to the top of the version dir
// under its canonical name, and the running blip's lib/ and programs/
// snapshot beside it (the current release layout ships the binary alone,
// so the data files come from the installer). Candidates cover the release
// names (`blip-linux`, `blip`) so both rename cleanly to `blip`.
// stability: internal
pub fn install_from_artifact(version string, artifact string, res_lib string, res_programs string) !string {
	tmp := os.join_path(os.temp_dir(), 'blip_toolchain_unpack')
	os.rmdir_all(tmp) or {}
	if os.is_dir(artifact) {
		os.mkdir_all(tmp)!
		copy_tree(artifact, tmp)!
	} else {
		unpack(artifact, tmp)!
	}
	mut bin := ''
	for cand in [binary_name(), 'blip-linux', 'blip', 'blip.exe'] {
		if os.exists(os.join_path(tmp, cand)) {
			bin = os.join_path(tmp, cand)
			break
		}
	}
	if bin == '' {
		return error('blip: no blip binary in ${artifact}')
	}
	dst := version_dir(version)
	if os.is_dir(dst) {
		os.rmdir_all(dst)!
	}
	os.mkdir_all(dst)!
	os.rename(bin, os.join_path(dst, binary_name()))!
	if res_lib != '' && os.is_dir(res_lib) {
		copy_tree(res_lib, os.join_path(dst, 'lib'))!
	}
	if res_programs != '' && os.is_dir(res_programs) {
		copy_tree(res_programs, os.join_path(dst, 'programs'))!
	}
	os.rmdir_all(tmp) or {}
	return dst
}

fn copy_tree(src string, dst string) ! {
	os.mkdir_all(dst)!
	for e in os.ls(src) or { return error('blip: cannot read ${src}: ${err.msg()}') } {
		s := os.join_path(src, e)
		d := os.join_path(dst, e)
		if os.is_dir(s) {
			copy_tree(s, d)!
			continue
		}
		os.write_file(d, os.read_file(s)!)!
	}
}

// shim_sh is the POSIX shim: resolve (env, then upward pin, then default)
// and exec the versioned binary with the same arguments.
// stability: internal
pub fn shim_sh(blip_home string, bin string) string {
	return r'#!/bin/sh
# Generated by `blip toolchain shim`. Do not edit: re-run the command.
BLIP_ROOT="' + blip_home + r'"
BIN="' + bin + r'"
ver="${BLIP_VERSION:-}"
d="$PWD"
while [ -z "$ver" ]; do
  if [ -f "$d/.blip-version" ]; then ver="$(cat "$d/.blip-version")"; break; fi
  nd="$(dirname "$d")"
  if [ "$nd" = "$d" ]; then break; fi
  d="$nd"
done
if [ -z "$ver" ] && [ -f "$BLIP_ROOT/default" ]; then ver="$(cat "$BLIP_ROOT/default")"; fi
if [ -z "$ver" ]; then echo "blip: no version selected (run `blip toolchain use <version>`)" >&2; exit 1; fi
exec "$BLIP_ROOT/versions/$ver/$BIN" "$@"
'
}

// shim_bat is the Windows shim: same resolution, batch spelling. The pin
// file holds the bare version (no trailing newline needed); `set /p`
// reads its first line.
// stability: internal
pub fn shim_bat(blip_home string, bin string) string {
	return '@echo off\r\nREM Generated by `blip toolchain shim`. Do not edit: re-run the command.\r\nset "BLIP_ROOT=' +
		blip_home + '"\r\nset "BIN=' + bin + '"\r\n' +
		'if defined BLIP_VERSION ( set "VER=%BLIP_VERSION%" & goto havever )\r\n' +
		'set "D=%CD%"\r\n' +
		':walk\r\n' +
		'if exist "%D%\\.blip-version" ( set /p VER=<"%D%\\.blip-version" & goto havever )\r\n' +
		'for %%I in ("%D%\\..") do set "ND=%%~fI"\r\n' +
		'if "%ND%"=="%D%" goto nodefault\r\n' +
		'set "D=%ND%"\r\n' +
		'goto walk\r\n' +
		':nodefault\r\n' +
		'if exist "%BLIP_ROOT%\\default" ( set /p VER=<"%BLIP_ROOT%\\default" & goto havever )\r\n' +
		'echo blip: no version selected (run `blip toolchain use ^<version^>`) >&2\r\n' +
		'exit /b 1\r\n' +
		':havever\r\n' +
		'"%BLIP_ROOT%\\versions\\%VER%\\%BIN%" %*\r\n'
}
