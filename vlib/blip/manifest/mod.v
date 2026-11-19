// vlib/blip/manifest/mod.v -- the blip.mod module manifest (roadmap
// Tracks E and G).
//
// blip.mod is blip data, parsed with the ordinary reader:
//
//   (module myapp)
//   (blip 2)
//   (features (fibers #f))
//   (deps (owner/repo "1.2.3"))
//   (workspace (members a b))
//
// parse validates shape strictly: unknown stanzas, duplicates, and wrong
// shapes are errors, because a manifest must be exact -- a typo that
// silently passes is a program built against the wrong contract. Feature
// names are NOT validated here (capabilities arrive with E2); version
// strings are NOT validated here (resolution arrives with G1). What v1
// promises is shape: the file parses to exactly this struct or it fails.
module manifest

import blip.reader

// manifest_version is the only (blip N) this tool reads. A newer manifest
// is an error naming the supported version, not a guess.
pub const manifest_version = 2

pub struct Dep {
pub:
	name string
	req  string
}

// Tool maps a runnable name to its file inside the package. `blip install`
// (Track G3) links each one onto PATH as a wrapper around `blip run`.
pub struct Tool {
pub:
	name string
	file string
}

pub struct Manifest {
pub mut:
	name          string
	blip_version  int
	features      map[string]bool
	feature_lines map[string]int
	deps          []Dep
	tools         []Tool
	workspace     []string
}

// feature_line names the blip.mod source line where a feature switch
// was written, or 0 when the manifest never mentions it. `blip check`
// (E2b) reports the manifest line rather than the use site, so a
// disabled capability points at the switch that disabled it.

// feature answers whether a capability is on. Absent means on: the
// manifest only ever switches things OFF, so an old manifest without a
// features stanza keeps working when new switches arrive.
// stability: stable
pub fn (m Manifest) feature(name string) bool {
	if name in m.features {
		return m.features[name]
	}
	return true
}

// stability: stable
pub fn (m Manifest) feature_line(name string) int {
	if name in m.feature_lines {
		return m.feature_lines[name]
	}
	return 0
}

// parse reads a blip.mod source string into a Manifest, or returns the
// first shape violation. Reader diagnostics come back as blip.mod
// positions, the same way `blip check` reports file positions.
// stability: stable
pub fn parse(src string) !Manifest {
	res := reader.read_all(src)
	if res.diags.len > 0 {
		d := res.diags[0]
		return error('blip.mod:${d.line}:${d.col}: ${d.msg}')
	}
	mut m := Manifest{
		features:      map[string]bool{}
		feature_lines: map[string]int{}
	}
	mut seen := map[string]bool{}
	for id in res.forms {
		d := res.arena.node(id)
		if d.tag != .list {
			return error('blip.mod:${d.line}:${d.col}: a manifest form is a list')
		}
		kids := res.arena.kids(id)
		if kids.len == 0 || res.arena.node(kids[0]).tag != .sym {
			return error('blip.mod:${d.line}:${d.col}: a manifest form starts with a stanza name')
		}
		head := res.arena.node(kids[0]).value
		if head != 'module' && head != 'blip' && head != 'features' && head != 'deps'
			&& head != 'tools' && head != 'workspace' {
			return error("blip.mod:${d.line}:${d.col}: unknown stanza '${head}' (module, blip, features, deps, tools, workspace)")
		}
		if head in seen {
			return error("blip.mod:${d.line}:${d.col}: duplicate '${head}' stanza")
		}
		seen[head] = true
		match head {
			'module' {
				m.name = parse_module(&res.arena, id, kids)!
			}
			'blip' {
				m.blip_version = parse_version(&res.arena, id, kids)!
			}
			'features' {
				m.features, m.feature_lines = parse_features(&res.arena, id, kids)!
			}
			'deps' {
				m.deps = parse_deps(&res.arena, id, kids)!
			}
			'tools' {
				m.tools = parse_tools(&res.arena, id, kids)!
			}
			'workspace' {
				m.workspace = parse_workspace(&res.arena, id, kids)!
			}
			else {
				return error('blip.mod: unreachable stanza')
			}
		}
	}
	if 'module' !in seen {
		return error('blip.mod needs (module NAME)')
	}
	if 'blip' !in seen {
		return error('blip.mod needs (blip 2)')
	}
	return m
}

// at renders a position for an error inside a stanza body.
fn at(a &reader.Arena, id reader.NodeId) string {
	d := a.node(id)
	return 'blip.mod:${d.line}:${d.col}'
}

fn parse_module(a &reader.Arena, id reader.NodeId, kids []reader.NodeId) !string {
	if kids.len != 2 || a.node(kids[1]).tag != .sym {
		return error("${at(a, id)}: (module NAME) takes one name")
	}
	return a.node(kids[1]).value
}

fn parse_version(a &reader.Arena, id reader.NodeId, kids []reader.NodeId) !int {
	if kids.len != 2 || a.node(kids[1]).tag != .int {
		return error("${at(a, id)}: (blip N) takes one integer version")
	}
	n := int(a.node(kids[1]).i)
	if n != manifest_version {
		return error('${at(a, id)}: unsupported manifest version ${n} (this blip reads ${manifest_version})')
	}
	return n
}

fn parse_features(a &reader.Arena, id reader.NodeId, kids []reader.NodeId) !(map[string]bool, map[string]int) {
	mut out := map[string]bool{}
	mut lines := map[string]int{}
	for k in kids[1..] {
		entry := a.kids(k)
		if a.node(k).tag != .list || entry.len != 2 || a.node(entry[0]).tag != .sym
			|| a.node(entry[1]).tag != .bool {
			return error("${at(a, k)}: a feature is (name #t/#f)")
		}
		name := a.node(entry[0]).value
		if name in out {
			return error("${at(a, k)}: duplicate feature '${name}'")
		}
		out[name] = a.node(entry[1]).i != 0
		lines[name] = a.node(k).line
	}
	return out, lines
}

fn parse_deps(a &reader.Arena, id reader.NodeId, kids []reader.NodeId) ![]Dep {
	mut out := []Dep{}
	for k in kids[1..] {
		entry := a.kids(k)
		if a.node(k).tag != .list || entry.len != 2 || a.node(entry[0]).tag != .sym
			|| a.node(entry[1]).tag != .str {
			return error("${at(a, k)}: a dep is (owner/repo \"version\")")
		}
		out << Dep{
			name: a.node(entry[0]).value
			req:  a.node(entry[1]).value
		}
	}
	return out
}

// parse_tools reads `(tools (name "file.blip") ...)`: each entry maps the
// runnable's installed name to its file inside the package. A duplicate
// tool name is an error, like a duplicate feature.
fn parse_tools(a &reader.Arena, id reader.NodeId, kids []reader.NodeId) ![]Tool {
	mut out := []Tool{}
	for k in kids[1..] {
		entry := a.kids(k)
		if a.node(k).tag != .list || entry.len != 2 || a.node(entry[0]).tag != .sym
			|| a.node(entry[1]).tag != .str {
			return error("${at(a, k)}: a tool is (name \"file.blip\")")
		}
		name := a.node(entry[0]).value
		for t in out {
			if t.name == name {
				return error("${at(a, k)}: duplicate tool '${name}'")
			}
		}
		out << Tool{
			name: name
			file: a.node(entry[1]).value
		}
	}
	return out
}

fn parse_workspace(a &reader.Arena, id reader.NodeId, kids []reader.NodeId) ![]string {
	if kids.len != 2 || a.node(kids[1]).tag != .list {
		return error("${at(a, id)}: (workspace (members a b ...)) takes one members list")
	}
	entry := a.kids(kids[1])
	if entry.len == 0 || a.node(entry[0]).tag != .sym || a.node(entry[0]).value != 'members' {
		return error("${at(a, kids[1])}: workspace holds (members a b ...)")
	}
	mut out := []string{}
	for m in entry[1..] {
		if a.node(m).tag != .sym {
			return error("${at(a, m)}: a workspace member is a name")
		}
		out << a.node(m).value
	}
	return out
}
