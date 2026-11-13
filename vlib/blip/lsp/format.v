module lsp

$if !wasm32 {
	import os
}

import blip.reader
import blip.prims
import blip.printer
import strings

fn format_text(text string) ?string {
	if text.len == 0 {
		return none
	}
	res := reader.read_all(text)
	if res.diags.len > 0 {
		return none
	}
	mut sb := strings.new_builder(res.forms.len * 64)
	for i, id in res.forms {
		if i > 0 {
			sb.write_string('\n\n')
		}
		sb.write_string(printer.pp_form(res.arena, id, 0))
	}
	sb.write_string('\n')
	return sb.str()
}
