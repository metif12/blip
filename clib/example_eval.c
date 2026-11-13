// example_eval.c -- blip C API usage and CI smoke test.
//
// Build (linux):   v -shared -cc gcc -o libblip.so clib/blip.v
//                  gcc clib/example_eval.c -o clib_smoke -L. -lblip -Wl,-rpath,'$ORIGIN'
// Build (windows): v -shared -cc msvc -o blip.dll clib/blip.v
//                  lib /def:clib/blip.def /out:blip.lib /machine:x64
//                  cl /nologo clib/example_eval.c blip.lib /Feclib_smoke.exe
// Run from the repo root: the blip_load step reads clib/smoke_prog.lip.
//
// Every check prints its label and the library's answer; any failure aborts
// non-zero, so CI only has to check the exit code and the final marker line.

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "blip.h"

static void check_eval(BlipInterp *ip, const char *src, const char *want) {
	char *out = 0;
	int rc = blip_eval(ip, src, &out);
	printf("eval %-55s => [%s]\n", src, out);
	assert(rc == BLIP_OK);
	assert(strcmp(out, want) == 0);
	blip_free_str(out);
}

int main(void) {
	printf("blip version: %s\n", blip_version());

	BlipInterp *ip = blip_new();
	assert(ip != 0);

	// Values accumulate across evals, like separate `blip run` files in one
	// machine: definitions persist.
	check_eval(ip, "(+ 1 2)", "3");
	check_eval(ip, "(define (double x) (* 2 x))", "double");
	check_eval(ip, "(double 21)", "42");

	// blip_call evaluates each argument as blip source, then calls by name.
	{
		char *out = 0;
		const char *argv[] = {"21"};
		int rc = blip_call(ip, "double", argv, 1, &out);
		printf("call double(\"21\") => [%s]\n", out);
		assert(rc == BLIP_OK);
		assert(strcmp(out, "42") == 0);
		blip_free_str(out);
	}

	// print goes to a per-interpreter buffer, not to process stdout.
	{
		char *out = 0;
		int rc = blip_eval(ip, "(print \"hi\")", &out);
		assert(rc == BLIP_OK);
		blip_free_str(out);
		rc = blip_output(ip, &out);
		printf("print buffer (%d line%s) => [%s]\n", rc, rc == 1 ? "" : "s", out);
		assert(rc == 1);
		assert(strcmp(out, "\"hi\"") == 0);
		blip_free_str(out);
		assert(blip_output(ip, &out) == 0); // drained: second read is empty
		assert(strcmp(out, "") == 0);
		blip_free_str(out);
	}

	// Files load through the host into the running machine.
	{
		char *out = 0;
		int rc = blip_load(ip, "clib/smoke_prog.lip", &out);
		printf("load => [%s]\n", out);
		assert(rc == BLIP_OK);
		blip_free_str(out);
		check_eval(ip, "(smoke-add 20 22)", "42");
	}

	// Errors are values at the C boundary too: return code plus message.
	{
		char *out = 0;
		int rc = blip_eval(ip, "no-such-name-xyz", &out);
		printf("bad eval => rc=%d [%s]\n", rc, out);
		assert(rc == BLIP_ERROR);
		assert(strstr(out, "unbound identifier") != 0);
		blip_free_str(out);
	}

	// Sandbox: keep arithmetic, drop everything else.
	{
		const char *keep[] = {"+", "-", "*", "print"};
		int removed = blip_restrict(ip, keep, 4);
		printf("restrict removed %d prims\n", removed);
		assert(removed > 0);
		char *out = 0;
		int rc = blip_eval(ip, "(read-file \"x\")", &out);
		printf("sandboxed eval => rc=%d [%s]\n", rc, out);
		assert(rc == BLIP_ERROR);
		blip_free_str(out);
		check_eval(ip, "(+ 40 2)", "42"); // arithmetic still works
	}

	// Limits bound untrusted code without killing the host.
	{
		BlipInterp *ip2 = blip_new();
		blip_set_limits(ip2, 200, 200);
		char *out = 0;
		int rc = blip_eval(ip2, "(loop i 0 #t i)", &out);
		printf("limited eval => rc=%d [%s]\n", rc, out);
		assert(rc == BLIP_ERROR);
		blip_free_str(out);
		blip_free_interp(ip2);
	}

	blip_free_interp(ip);
	printf("clib smoke: all checks passed\n");
	return 0;
}
