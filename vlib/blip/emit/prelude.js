// blip runtime. Compiled into `blip` via $embed_file and prepended to every
// module `blip emit-js` writes, so the emitted JavaScript is self-contained.
//
// This is an ASSET, not V source, on purpose. It used to live in a single-quoted
// V string, where every `\"` had to be escaped twice and a stray replacement
// could terminate the string silently. Keeping it as real JavaScript means the
// file can be read as what it is.

const blip = {
  add: (...a) => a.reduce((x, y) => x + y, 0),
  sub: (...a) => a.length === 1 ? -a[0] : a.reduce((x, y) => x - y),
  mul: (...a) => a.reduce((x, y) => x * y, 1),
  div: (a, b) => a / b,
  lt: (a, b) => a < b,
  gt: (a, b) => a > b,
  lte: (a, b) => a <= b,
  gte: (a, b) => a >= b,
  eq: (...a) => {
    for (let i = 1; i < a.length; i++) if (!blip_equal(a[i - 1], a[i])) return false;
    return true;
  },
  // `print` joins its arguments with SPACES onto ONE line. Printing each on its
  // own line looked equivalent until a program printed two, which is how
  // `(print "parsed:" r1 "=" r2)` became four lines here and one there.
  print: (...a) => {
    console.log(a.map(blip_show).join(" "));
    return null;
  },
  echo: (x) => { console.log(blip_show(x)); return x; },
  missing: (...a) => {
    throw new Error("blip: unimplemented primitive");
  },
  car: (x) => unvec(x)[0],
  cdr: (x) => unvec(x).slice(1),
  cons: (x, y) => [x].concat(unvec(y)),
  p_null_q: (x) => x === null || x === undefined
    || (Array.isArray(unvec(x)) && unvec(x).length === 0),
  not: (x) => !blip_truthy(x),
  p_equal_q: (a, b) => blip_equal(a, b),
  apply: (f, ...a) => f(...a),
  length: (x) => {
    const items = unvec(x);
    return Array.isArray(items) || typeof items === "string" ? items.length : null;
  },
  vector_ref: (v, i) => unvec(v)[i],
  vector_length: (v) => unvec(v).length,
  string_upcase: (s) => s.toUpperCase(),
  string_downcase: (s) => s.toLowerCase(),
  string_append: (...a) => a.join(""),
  string_length: (s) => (typeof s === "string" ? s.length : 0),
  // A rational is a tagged pair, not a JavaScript number. JavaScript has no
  // exact rational, and widening 1/3 to 0.3333333333333333 would make the
  // emitted program disagree with `blip run` on the value the numeric tower
  // exists to keep exact.
  rat: (n, d) => ({ blip_rat: [n, d] }),
  // A symbol is tagged so the printer can show it bare, the way `blip run`
  // does. Emitting one as a plain string printed `done` as `"done"`.
  sym: (name) => ({ blip_sym: name }),
  kw: (name) => ({ blip_kw: name }),
  // A vector is a tagged array, not a bare array. `[1 2 3]` and `(list 1 2 3)`
  // are different values in blip -- the printer writes one `[1 2 3]` and the
  // other `(1 2 3)` -- so the literal needs a marker the printer can see.
  // Without it every vector printed as a list, which is the mismatch that
  // stopped the two threading checks from passing.
  vec: (...items) => ({ blip_vec: items }),
  // `append` concatenates sequences into a LIST: `(append [1] [2 3])` is
  // `(1 2 3)`, not a vector. `unvec` flattens both tagged vectors and bare
  // arrays, so either container works as input.
  append: (...colls) => colls.flatMap((c) => unvec(c)),
  // The 02_data batch. `array-ref` and `array-length` delegate to the vector
  // versions (prim_array_ref calls prim_vector_ref; prim_array_length reads the
  // same `.data.len`), because an array IS a vector with a different tag.
  array_ref: (v, i) => unvec(v)[i],
  array_length: (v) => unvec(v).length,
  // `put` and `remove` return NEW tables (prim_put clones the map first), so
  // the input is never mutated. `put!` and `remove!` mutate in place.
  put: (t, k, v) => ({ blip_table: { ...(t.blip_table || {}), [keyof(k)]: v } }),
  remove: (t, k) => {
    const next = { ...(t.blip_table || {}) };
    delete next[keyof(k)];
    return { blip_table: next };
  },
  put_b: (t, k, v) => {
    if (t && t.blip_table) t.blip_table[keyof(k)] = v;
    else if (t && t.blip_buffer) t.blip_buffer[keyof(k)] = v;
    return t;
  },
  // `string-split` answers a LIST of strings (prim_string_split ends in
  // `blip.list_from`), `string-trim` trims both ends, and a missing needle is
  // -1 rather than an error (prim_string_index_of returns -1 on no match).
  string_split: (s, sep) => s.split(sep),
  string_trim: (s) => s.trim(),
  string_index_of: (hay, needle) => hay.indexOf(needle),
  // `vector-append` answers a new VECTOR (`blip.vector(out)`), so it rewraps;
  // `append` answers a list and does not. That asymmetry is the prims', not an
  // invention here.
  vector_append: (...colls) => ({ blip_vec: colls.flatMap((c) => unvec(c)) }),
  // `array-push!` mutates and returns the SAME array (prim_array_push returns
  // `args[0]`). `array-set!` mutates; out of range is an error in blip and
  // throws here.
  array_push_b: (v, x) => {
    const items = unvec(v);
    if (!Array.isArray(items)) throw new Error("array-push!: not an array");
    items.push(x);
    return v;
  },
  array_set_b: (v, i, x) => {
    const items = unvec(v);
    if (!Array.isArray(items) || i < 0 || i >= items.length) {
      throw new Error("array-set!: index " + i + " out of range");
    }
    items[i] = x;
    return null;
  },
  // `take` answers the first n items, preserving the container.
  take: (coll, n) => {
    const items = unvec(coll);
    if (!Array.isArray(items)) return coll;
    return rewrap(coll, items.slice(0, Math.max(0, n)));
  },
  // A list is a bare array: the printer writes `(1 2 3)`, which is the list
  // spelling, and vectors carry the tag that separates them.
  list: (...items) => items,
  // The collection literals. An array is a VECTOR -- blip prints `@(1 2 3)` as
  // `[1 2 3]`, which is the vector spelling -- so it carries the vector tag and
  // needs no separate representation. A table is a keyword-to-value object.
  // A buffer is a mutable table, which prints `@{...}`; the tag is all that
  // separates the two shapes.
  //
  // `table` is variadic and alternating: item 0 is a key, 1 its value, 2 a key,
  // and so on -- that is the shape `{:a 1 :b 2}` reads as.
  table: (...kv) => {
    const t = {};
    for (let i = 0; i + 1 < kv.length; i += 2) t[kv[i]] = kv[i + 1];
    return { blip_table: t };
  },
  buffer: (...kv) => {
    const t = {};
    for (let i = 0; i + 1 < kv.length; i += 2) t[kv[i]] = kv[i + 1];
    return { blip_buffer: t };
  },
  // `get` reads a key, and a MISSING key is nil rather than an error -- which is
  // what `(get {:a 1} :missing)` returns, and what the third argument overrides.
  get: (t, k, ...rest) => {
    const m = unvec(t);
    if (m && m.blip_table) {
      const key = m.blip_table[keyof(k)];
      if (key !== undefined && key !== null) return key;
      return rest.length > 0 ? rest[0] : null;
    }
    const items = seq_items(t);
    if (items) {
      const idx = (typeof k === "number") ? k : Number(k);
      if (!Number.isNaN(idx) && idx >= 0 && idx < items.length) return items[idx];
      return rest.length > 0 ? rest[0] : null;
    }
    return rest.length > 0 ? rest[0] : null;
  },
  // Keys print SORTED, which is what blip's printer does: `{:name "ada" :b 2}`
  // reads `{:b 2 :name "ada"}`. That is not incidental -- a table literal in
  // source order would make emitted output disagree with `blip run` for any
  // table whose keys are not already alphabetical, and most are not.
  table_keys: (t) => {
    const m = unvec(t);
    return m && m.blip_table ? Object.keys(m.blip_table).sort().map((k) => blip.kw(k)) : [];
  },
  // Higher-order forms. Each drives its callback through `tramp`, because a
  // user function emitted by this backend returns a thunk when its body ends in
  // a tail call -- and most of them do. Using the thunk directly would hand it
  // to `blip.mul` instead of the value, and the failure would appear wherever the
  // result was first used rather than at the call.
  //
  // `map` and `filter` preserve the container, which is the rule blip settled:
  // `(map f [1 2 3])` is `[1 4 9]`, a vector, not a list. Each unwraps a tagged
  // vector first and rewraps after, so the container survives the call.
  map: (f, coll) => {
    const items = unvec(coll);
    return Array.isArray(items) ? rewrap(coll, items.map((x) => tramp(f(x)))) : coll;
  },
  filter: (f, coll) => {
    const items = unvec(coll);
    return Array.isArray(items)
      ? rewrap(coll, items.filter((x) => blip_truthy(tramp(f(x)))))
      : coll;
  },
  vector_map: (f, coll) => {
    const items = unvec(coll);
    return Array.isArray(items)
      ? rewrap(coll, items.map((x) => tramp(f(x))))
      : coll;
  },
  fold: (f, init, coll) => {
    const items = unvec(coll);
    return Array.isArray(items)
      ? items.reduce((acc, x) => tramp(f(acc, x)), init)
      : init;
  },
  // `|>` is a pipe: (x |> f) is (f x). It is also the most common bare-symbol
  // step inside `->>`, so it has to be a real function and not only syntax.
  // Called with one argument it is the identity: a bare `|>` step becomes the
  // single-arg call `(pipe acc)`, and blip's own `|>` on one argument returns
  // the argument unchanged (machine/mod.v pipe_one: a non-call step becomes
  // `(step acc)`, so `(|> "hello")` is a call whose value is `"hello"`).
  pipe: (x, f) => (f === undefined ? x : tramp(f(x))),
  reverse: (coll) => {
    const items = unvec(coll);
    return Array.isArray(items) ? rewrap(coll, items.slice().reverse()) : coll;
  },
  // `sort` is ascending, and it copies rather than sorting in place: blip's
  // collections are values, and sorting the caller's array would make
  // `(->> [3 1 2] |> sort)` change what the caller holds.
  sort: (coll) => {
    const items = unvec(coll);
    return Array.isArray(items)
      ? rewrap(coll, items.slice().sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)))
      : coll;
  },
  sort_by: (f, coll) => {
    const items = unvec(coll);
    if (!Array.isArray(items)) return coll;
    const keys = items.map((x) => tramp(f(x)));
    const order = items.map((_, i) => i).sort((a, b) => {
      const ka = keys[a], kb = keys[b];
      return ka < kb ? -1 : ka > kb ? 1 : 0;
    });
    return rewrap(coll, order.map((i) => items[i]));
  },
  // The type predicates. Each answers the tag check its prim does
  // (prims/mod.v `tag_is`): `array?` is the array tag, `table?` the table tag,
  // and so on. Two limits are stated, not hidden. First, `integer?` and
  // `float?` cannot both be right in JavaScript, because `1.0` parses as `1`
  // and the distinction is lost before any function runs: integers test
  // `Number.isInteger`, floats test non-integers, and a blip float that happens
  // to be whole still reads as an integer here. Second, `number?` covers JS
  // numbers and rationals, which is what the numeric tower reduces to once the
  // exact tags are gone.
  array_q: (x) => !!(x && (x.blip_vec || x.blip_arr)),
  table_q: (x) => !!(x && (x.blip_table || x.blip_buffer)),
  float_q: (x) => typeof x === "number" && !Number.isInteger(x),
  integer_q: (x) => typeof x === "number" && Number.isInteger(x),
  keyword_q: (x) => !!(x && x.blip_kw !== undefined),
  list_q: (x) => Array.isArray(x),
  negative_q: (x) => typeof x === "number" && x < 0,
  number_q: (x) => typeof x === "number" || !!(x && x.blip_rat),
  positive_q: (x) => typeof x === "number" && x > 0,
  string_q: (x) => typeof x === "string",
  symbol_q: (x) => !!(x && x.blip_sym !== undefined),
  vector_q: (x) => !!(x && (x.blip_vec || x.blip_arr)),
  zero_q: (x) => x === 0,
  eq_q: (a, b) => blip_equal(a, b),
  // `has-key?` tests membership without reading: a present key holding nil
  // still counts (prim_has_key checks `has`, not `get`), which a `get`-based
  // test would get wrong.
  has_key_q: (t, k) => {
    const m = unvec(t);
    if (m && m.blip_table) return k in m.blip_table;
    if (m && m.blip_buffer) return k in m.blip_buffer;
    return false;
  },
  // `format` substitutes `~a` bare and `~s` shown (machine/mod.v format_args
  // via show_value: a string with `~a` prints without quotes, with `~s` it
  // prints as the printer writes it). Anything else passes through literally.
  format: (fmt, ...args) => {
    let n = 0;
    return String(fmt).replace(/~[as]/g, (m) => {
      if (n >= args.length) return m;
      const v = args[n++];
      if (m === "~s") return blip_show(v);
      return typeof v === "string" ? v : blip_show(v);
    });
  },
  // The numeric conversions. `string->number` answers nil on a string that is
  // neither an integer nor a float (prim_string_to_number returns
  // nil_value rather than an error), and a whole-valued float parses as an
  // integer here because JavaScript has one number type.
  string_number: (s) => {
    const t = String(s).trim();
    if (t === "") return null;
    const n = Number(t);
    return Number.isNaN(n) ? null : n;
  },
  // `number->string` reads through the printer, which is why a float that
  // happens to be whole prints with its decimal part in blip and without one
  // here: "42", not "42.0". The integer spelling is exact.
  number_string: (n) => typeof n === "string" ? n : String(n),
  // `even?` and `odd?` are primitives in blip (prims/mod.v). They are not the
  // `letrec` bindings in examples/01_basics.lip -- those shadow them locally,
  // and the top-level `(filter even? ...)` uses the primitive. An emitter with
  // no binding for them emits a call to a name nobody defined.
  // ---- Result -------------------------------------------------------------
  //
  // A Result is a plain list whose head is the symbol `ok` or `err`, so it prints
  // as `(ok 42)` and compares structurally. It is not a tagged value here, which
  // matches blip: machine/mod.v says a dedicated tag would make every result a
  // special case in the printer, in `=` and in the pattern matcher, for no gain.
  ok: (...vals) => [blip.sym("ok")].concat(vals),
  err: (...vals) => [blip.sym("err")].concat(vals),
  error: (...args) => blip.err(args.length === 0 ? "" : blip.format(String(args[0]), ...args.slice(1))),
  raise: (...args) => {
    let msg = "";
    let subject = null;
    if (args.length === 1 && Array.isArray(args[0]) && args[0].length >= 2
        && args[0][0] && args[0][0].blip_sym === "err") {
      subject = args[0];
      msg = args[0][1];
    } else {
      msg = args.length === 0 ? "" : blip.format(String(args[0]), ...args.slice(1));
      subject = blip.err(msg);
    }
    throw { blip_raise: { msg: msg, subject: subject } };
  },
  ok_q: (r) => is_result(r, "ok"),
  err_q: (r) => is_result(r, "err"),
  // `ok-value` and `err-value` answer the value INSIDE, and refuse a result of the
  // other kind by name -- the message says what it was, because "not a result"
  // sends the reader looking for a different mistake.
  ok_value: (r) => result_inner(r, "ok", "ok-value"),
  err_value: (r) => result_inner(r, "err", "err-value"),
  // `unwrap-or` evaluates its default on EVERY call, because every argument in a
  // Lisp is evaluated eagerly. That is the trap the lazy name exists to avoid.
  unwrap_or: (r, dflt) => {
    if (!is_result(r, "ok")) return tramp(dflt);
    const items = unvec(r);
    return items.length > 1 ? items[1] : null;
  },
  // One level only: ok(ok(1)) is ok(1), and a deeper nest is a bug in the caller
  // rather than something to normalise silently. The value is the INNER result,
  // not a rebuilt pair -- rebuilding kept the outer `ok` and handed the inner
  // value straight through, so one level was peeled and then put back.
  flatten_result: (r) => {
    if (is_result(r, "ok")) {
      const items = unvec(r);
      if (items.length > 1 && (is_result(items[1], "ok") || is_result(items[1], "err"))) {
        return items[1];
      }
    }
    return r;
  },
  // The FIRST error wins: returning the last would make the result depend on
  // evaluation order in a way nobody can see.
  all_results: (...rs) => {
    const vals = [];
    for (const r of rs) {
      if (!is_result(r, "ok")) return r;
      const items = unvec(r);
      if (items.length > 1) vals.push(items[1]);
    }
    return [blip.sym("ok"), blip.vec(...vals)];
  },
  // map-result, try-result and lazy-map-result are ONE function in blip:
  // result_combinator only special-cases lazy-unwrap, so all three map the inner
  // value and pass an (err _) straight through. The names differ because the
  // intention differs, and a lazy name on a function that is not lazy would be
  // the lie -- so they are emitted as the same function, not three similar ones
  // that drift.
  map_result: (r, f) => map_result_go(r, f),
  try_result: (r, f) => map_result_go(r, f),
  lazy_map_result: (r, f) => map_result_go(r, f),
  // lazy-unwrap is the one that differs: on an (err _) it RUNS the thunk, which is
  // the entire reason it takes a function.
  lazy_unwrap: (r, f) => {
    if (!is_result(r, "ok")) return tramp(f());
    const items = unvec(r);
    return items.length > 1 ? items[1] : null;
  },
  // `assert` is executable documentation, and the message is REQUIRED: an
  // assertion failure that only says "false" tells a reader nothing about which
  // of four hundred promises broke.
  assert: (test, message) => {
    if (!blip_truthy(tramp(test))) {
      throw new Error("assertion failed: " + blip_show(tramp(message)));
    }
    return null;
  },
  // `any?` and `every?` take the PREDICATE FIRST: `(any? even? [1 3 4])`. Measured,
  // because the other order is a type error that names the closure rather than
  // the argument positions.
  any_q: (f, xs) => {
    const items = unvec(xs);
    return Array.isArray(items) ? items.some((x) => blip_truthy(tramp(f(x)))) : false;
  },
  every_q: (f, xs) => {
    const items = unvec(xs);
    return Array.isArray(items) ? items.every((x) => blip_truthy(tramp(f(x)))) : true;
  },
  // ---- the sequence and scalar prims the examples reach for -----------------
  //
  // Aliases are routed to the SAME function rather than to a copy of it:
  // `first` is `car` in blip (`p['first'] = prim_car`), and two spellings of one
  // operation are how they drift.
  first: (x) => unvec(x)[0],
  rest: (x) => unvec(x).slice(1),
  last: (x) => {
    const items = unvec(x);
    return Array.isArray(items) && items.length > 0 ? items[items.length - 1] : null;
  },
  count: (x) => {
    const items = unvec(x);
    return Array.isArray(items) ? items.length : 0;
  },
  // list-ref is bounds-CHECKED, and the message names the length: an index error
  // without one sends the reader looking for a different mistake.
  list_ref: (x, i) => {
    const items = unvec(x);
    if (i < 0 || i >= items.length) {
      throw new Error("list-ref: index " + i + " out of range (length " + items.length + ")");
    }
    return items[i];
  },
  nil_q: (x) => is_empty_seq(x),
  not_eq: (a, b) => !blip_equal(a, b),
  zero: (x) => blip_equal(x, 0),
  // range is INCLUSIVE on both ends and answers a LIST.
  range: (a, b) => {
    const from = b === undefined ? 0 : a;
    const to = b === undefined ? a : b;
    const out = [];
    for (let i = from; i <= to; i++) out.push(i);
    return out;
  },
  remainder: (a, b) => {
    if (b === 0) throw new Error("remainder by zero");
    return a % b;
  },
  sqrt: (x) => {
    if (x < 0) throw new Error("sqrt of a negative number");
    return Math.sqrt(x);
  },
  // `str` and `string` are the same prim: the value as the PRINTER writes it,
  // quotes and all.
  str: (x) => blip_show(x),
  string: (x) => blip_show(x),
  symbol: (s) => blip.sym(s),
  keyword: (s) => (s && s.blip_kw !== undefined ? s : blip.kw(s)),
  vector: (...items) => blip.vec(...items),
  string_not_blank_q: (s) => String(s).trim() !== "",
  // frequencies answers a LIST of `(value count)` pairs in FIRST-SEEN order, not
  // sorted, and each pair carries the ORIGINAL value -- not one rebuilt from its
  // printed form, which is how the quote characters got INTO the data.
  frequencies: (xs) => {
    const items = unvec(xs);
    const order = [];
    const counts = new Map();
    const first = new Map();
    for (const v of Array.isArray(items) ? items : []) {
      const key = typeof v === "string" ? v : blip_show(v);
      if (!counts.has(key)) {
        order.push(key);
        counts.set(key, 0);
        first.set(key, v);
      }
      counts.set(key, counts.get(key) + 1);
    }
    return order.map((k) => [first.get(k), counts.get(k)]);
  },
  even_q: (n) => unvec(n) % 2 === 0,
  odd_q: (n) => unvec(n) % 2 !== 0,
};

// unvec unwraps a tagged vector to its items, and returns anything else
// unchanged. Every collection function goes through it, because a tagged vector
// is not an Array and `Array.isArray` is false for one -- which would make
// `sort`, `map` and `reverse` silently pass a vector through untouched.
function unvec(x) { return x && x.blip_vec ? x.blip_vec : x; }

// rewrap puts the items back into a tagged vector when the input was one, so
// `sort` of a vector is still a vector. Without this the thread step would
// change the container and the printed spelling would drift.
function rewrap(orig, items) {
  return orig && orig.blip_vec ? { blip_vec: items } : items;
}

// blip_show is the printer. It is separate from console.log because blip prints
// a string WITH its quotes, the way the blip printer does -- printing one without
// them would make emitted output disagree with `blip run`.
// keyof normalises a lookup key. A keyword datum and its bare name are the same
// key -- `blip get :a` and `blip get "a"` find the same entry -- so every table
// operation runs its key through this instead of trusting the caller's spelling.
function keyof(k) {
  return k && k.blip_kw !== undefined ? k.blip_kw : k;
}

// pat_match matches a COMPILED pattern -- a tree of tagged arrays built by the
// emitter -- against a subject, and returns either a bindings object or the
// string "no". A string and an object cannot be confused, so the caller can use
// it directly as a condition, and a bindings object is never a bare string.
//
// The rules are machine/match.v's, not an independent opinion:
//
//   ["lit", v]        equality against v
//   ["sym", name]     binds the whole subject; always matches
//   ["wc"]            `_`: matches, binds nothing
//   ["list", p, ...]  a sequence pattern, with the length rule below
//   ["cons", p, t]    car matches p, cdr matches t
//   ["table", k, p]   the key k must be present, and its value must match p
//   ["struct", n, k, p, ...]  the struct name, then field: pattern pairs
//   ["and", p, ...]   every pattern, bindings merged
//   ["or", p, ...]    the first that matches, and ITS bindings
//   ["pred", f, a...] f(subject, a...), matched by truthiness
//
// `["lit", null]` is what a nil PATTERN means, and it is not `["sym"]`: the
// reader records nil as the empty sequence (match.v `.nil` arm), so `nil`
// matches '() and matches nothing else.
function pat_match(pat, subj) {
  const head = pat[0];
  if (head === "lit") return blip_equal(pat[1], subj) ? {} : "no";
  if (head === "wc") return {};
  if (head === "sym") return { [pat[1]]: subj };
  if (head === "pred") return pat[1].apply(null, [subj].concat(pat.slice(2))) ? {} : "no";
  if (head === "and") {
    const out = {};
    for (let i = 1; i < pat.length; i++) {
      const r = pat_match(pat[i], subj);
      if (r === "no") return "no";
      Object.assign(out, r);
    }
    return out;
  }
  if (head === "or") {
    for (let i = 1; i < pat.length; i++) {
      const r = pat_match(pat[i], subj);
      if (r !== "no") return r;
    }
    return "no";
  }
  if (head === "cons") {
    if (!is_pair(subj)) return "no";
    const items = unvec(subj);
    const a = pat_match(pat[1], items[0]);
    if (a === "no") return "no";
    const b = pat_match(pat[2], items.slice(1));
    if (b === "no") return "no";
    return Object.assign(a, b);
  }
  if (head === "table") {
    const m = unvec(subj);
    const out = {};
    for (let i = 1; i + 1 < pat.length; i += 2) {
      const key = pat[i];
      const t = m && m.blip_table ? m.blip_table : m && m.blip_buffer ? m.blip_buffer
        : m && m.blip_struct !== undefined ? m : null;
      if (!t || !Object.prototype.hasOwnProperty.call(t, key)) return "no";
      const r = pat_match(pat[i + 1], t[key]);
      if (r === "no") return "no";
      Object.assign(out, r);
    }
    return out;
  }
  if (head === "struct") {
    if (!subj || subj.blip_struct === undefined) return "no";
    if (subj.blip_struct !== pat[1]) return "no";
    const out = {};
    for (let i = 2; i + 1 < pat.length; i += 2) {
      if (!Object.prototype.hasOwnProperty.call(subj, pat[i])) return "no";
      const r = pat_match(pat[i + 1], subj[pat[i]]);
      if (r === "no") return "no";
      Object.assign(out, r);
    }
    return out;
  }
  if (head === "fix") {
    // A BINDING pattern, which is not a match pattern. `machine/mod.v`
    // destructuring is deliberately positional with no tail capture, because in a
    // binding `(list h t)` binding only `h` and calling `t` the rest would be the
    // wrong reading. Measured: `(let ([(list a b) '(1 2 3)]) [a b])` is [1 2], so
    // extra elements are ignored rather than rejected; a short subject is
    // `list-ref`'s out-of-range error, which is what blip reports.
    const items = seq_items(subj);
    if (items === null) return "no";
    const out = {};
    for (let i = 0; i < pat.length - 1; i++) {
      const p = pat[i + 1];
      if (p[0] === "wc") continue;
      if (i >= items.length) {
        throw new Error("blip: list-ref: index " + i + " out of range (length "
          + items.length + ")");
      }
      const r = pat_match(p, items[i]);
      if (r === "no") return "no";
      Object.assign(out, r);
    }
    return out;
  }
  if (head === "btab") {
    // A table BINDING, which differs from a table MATCH in one place: a missing
    // key binds nil rather than failing, because the machine builds the binding
    // from `get` calls and `get` of an absent key is nil. Only `let assert`
    // demands the key, and it uses the matching node.
    const m = unvec(subj);
    const out = {};
    for (let i = 1; i + 1 < pat.length; i += 2) {
      const key = pat[i];
      const t = m && m.blip_table ? m.blip_table : m && m.blip_buffer ? m.blip_buffer
        : m && m.blip_struct !== undefined ? m : null;
      const r = pat_match(pat[i + 1], t && Object.prototype.hasOwnProperty.call(t, key)
        ? t[key] : null);
      if (r === "no") return "no";
      Object.assign(out, r);
    }
    return out;
  }
  // A sequence pattern. `["list"]` with no sub-patterns is the empty one.
  const items = seq_items(subj);
  if (items === null) return "no";
  const rest = pat.slice(1);
  if (rest.length === 0) return items.length === 0 ? {} : "no";
  const last = rest[rest.length - 1];
  const isWc = last[0] === "wc";
  const isCap = last[0] === "sym";
  // `["pos"]` is the headless form `(a b c)`, and it is NOT the `list` rule.
  // match_list_tail drops the FIRST element -- positional() is handed the whole
  // kids and then does `rest := kids[1..]` -- and it has NO length check at all:
  // it walks the patterns and fails when it runs out of items. Measured, and all
  // three of these fall out of that one rule:
  //
  //   (a b c)   on '(1 2 3)   rest is [b c], so c takes items[1..] -- (2 3)
  //   (_ _ x)   on '(1 2 3)   rest is [_ x], so x takes items[1..] -- (2 3)
  //   (x _)     on '(1 2 3)   rest is [_], which binds NOTHING, so `x` in the body
  //                          is unbound -- which is what blip reports
  if (pat[0] === "pos") {
    const out = {};
    for (let i = 0; i < rest.length; i++) {
      if (i === rest.length - 1 && isCap) {
        const r = pat_match(rest[i], items.length > i ? items.slice(i) : []);
        if (r === "no") return "no";
        Object.assign(out, r);
        continue;
      }
      if (i >= items.length) return "no";
      const r = pat_match(rest[i], items[i]);
      if (r === "no") return "no";
      Object.assign(out, r);
    }
    return out;
  }
  const tails = !isWc && isCap && rest.length !== items.length;
  if (isWc) {
    if (rest.length - 1 !== items.length) return "no";
  } else if (tails) {
    if (rest.length > items.length) return "no";
  } else if (rest.length !== items.length) {
    return "no";
  }
  const out = {};
  for (let i = 0; i < rest.length; i++) {
    // A wildcard is skipped before any bounds test: `(list a b c _)` has four
    // patterns for three elements and the fourth binds nothing.
    if (rest[i][0] === "wc") continue;
    if (tails && i === rest.length - 1) {
      const r = pat_match(rest[i], items.slice(i));
      if (r === "no") return "no";
      Object.assign(out, r);
      continue;
    }
    if (i >= items.length) return "no";
    const r = pat_match(rest[i], items[i]);
    if (r === "no") return "no";
    Object.assign(out, r);
  }
  return out;
}

// seq_items is `prims.seq`: the element list of anything blip can walk, and
// null for anything it cannot. A list, a vector and a string are sequences; a
// table and a number are not, which is why `(list x)` misses a bare number.
function seq_items(x) {
  if (typeof x === "string") return null;
  const v = unvec(x);
  return Array.isArray(v) ? v : null;
}

// is_pair reports whether a value is a CONS cell. A list and a vector both
// walk the same way here, because a quoted list is the pair chain blip prints
// as `(1 2 3)` and the elements are in that order either way.
function is_pair(x) {
  return Array.isArray(unvec(x)) && unvec(x).length >= 2;
}

// is_result reports whether a value is a `(ok ...)` or `(err ...)`: a sequence
// whose FIRST element is the bare symbol of that kind. blip checks the same
// thing in is_result_of, on the pair's car.
function is_result(v, kind) {
  const items = unvec(v);
  return Array.isArray(items) && items.length > 0
    && items[0] && items[0].blip_sym !== undefined && items[0].blip_sym === kind;
}

// result_inner is `ok-value` / `err-value`: the value at position 1, or a refusal
// naming the kind it actually was.
function result_inner(v, kind, name) {
  if (!is_result(v, kind)) {
    const items = unvec(v);
    const actual = Array.isArray(items) && items.length > 0
      && items[0] && items[0].blip_sym !== undefined ? items[0].blip_sym : "not-a-result";
    throw new Error(name + ": " + blip_show(v) + " is not a (" + kind
      + " ...), it is a " + actual);
  }
  const items = unvec(v);
  return items.length > 1 ? items[1] : null;
}

// map_result_go is the one function behind map-result, try-result and
// lazy-map-result. It cannot live in the blip object because those three
// properties reference it while the object literal is still being built.
function map_result_go(r, f) {
  if (!is_result(r, "ok")) return r;
  const items = unvec(r);
  const v = tramp(f(items.length > 1 ? items[1] : null));
  return is_result(v, "err") ? v : blip.ok(v);
}

// is_empty_seq answers blip's `nil?`: nil itself, or a sequence with nothing in
// it. It is what a nil PATTERN matches (machine/match.v `.nil` arm), so the two
// cannot drift apart.
function is_empty_seq(x) {
  if (x === null || x === undefined) return true;
  const v = unvec(x);
  return Array.isArray(v) && v.length === 0;
}

function blip_show(x) {
  // `null`/`undefined` is blip's `nil`, and the printer spells it `nil`. Returning
  // `null` here made `(match 7 [1 'one])` print `null` where blip prints `nil`.
  if (x === null || x === undefined) return "nil";
  // A rational prints as n/d, the way the blip printer prints one.
  if (x && x.blip_rat) return x.blip_rat[0] + "/" + x.blip_rat[1];
  // A symbol prints bare: `done`, not `"done"` and not `'"done"'`.
  if (x && x.blip_sym !== undefined) return x.blip_sym;
  // A keyword prints `:k`. Stored bare it would lose the colon, stored quoted
  // it would print `":k"`, so it is tagged like a symbol.
  if (x && x.blip_kw !== undefined) return ":" + x.blip_kw;
  // A vector prints `[...]`, the way the blip printer writes one.
  if (x && x.blip_vec) return "[" + x.blip_vec.map(blip_show).join(" ") + "]";
  // A table prints `{:k v}` and a buffer `@{:k v}`, both with SORTED keys, which
  // is the blip printer's own ordering: `{:name "ada" :b 1815}` reads
  // `{:b 1815 :name "ada"}`. Measured against `blip run`, not assumed.
  // A keyword prints `:k`, bare like a symbol. Storing it as a string would
  // quote it, so tables and buffers keep keys as plain names and mark them
  // here with `blip.kw`, whose printer is the `:` prefix.
  if (x && x.blip_buffer) {
    const keys = Object.keys(x.blip_buffer).sort();
    if (keys.length == 0) return "@{}";
    const kv = [];
    for (const k of keys) {
      kv.push(blip.kw(k));
      kv.push(x.blip_buffer[k]);
    }
    return "@{" + kv.map(blip_show).join(" ") + "}";
  }
  if (x && x.blip_table) {
    const keys = Object.keys(x.blip_table).sort();
    if (keys.length == 0) return "{}";
    const kv = [];
    for (const k of keys) {
      kv.push(blip.kw(k));
      kv.push(x.blip_table[k]);
    }
    return "{" + kv.map(blip_show).join(" ") + "}";
  }
  // A struct prints the way `blip run` prints one: (Name field field ...).
  if (x && x.blip_struct !== undefined) {
    const vals = Object.keys(x)
      .filter((k) => k !== "blip_struct")
      .map((k) => blip_show(x[k]));
    return "(" + x.blip_struct + " " + vals.join(" ") + ")";
  }
  if (typeof x === "string") return '"' + x
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t") + '"';
  if (Array.isArray(x)) return "(" + x.map(blip_show).join(" ") + ")";
  // A boolean prints `#t` or `#f`, the way the blip printer spells it.
  if (x === true) return "#t";
  if (x === false) return "#f";
  return String(x);
}

// blip_truthy: only #f is false, and everything else is true. JavaScript
// disagrees about null -- falsy there, true here -- so this is not `!x`.
function blip_truthy(x) {
  return !(x === false);
}

function blip_equal(a, b) {
  if (a === null || a === undefined) return b === null || b === undefined;
  // A keyword and a symbol are tagged OBJECTS, so `===` says two `:dog` values
  // are different. They are the same value: a table stores its keys as names and
  // its keyword values as tags, and a pattern compares a stored value against a
  // literal, so identity here breaks every keyword comparison there is.
  const ak = a.blip_kw !== undefined ? "kw" : (a.blip_sym !== undefined ? "sym" : null);
  const bk = b.blip_kw !== undefined ? "kw" : (b.blip_sym !== undefined ? "sym" : null);
  if (ak || bk) {
    if (!ak || ak !== bk) return false;
    return ak === "kw" ? a.blip_kw === b.blip_kw : a.blip_sym === b.blip_sym;
  }
  const ua = unvec(a);
  const ub = unvec(b);
  if (Array.isArray(ua) && Array.isArray(ub)) {
    if (ua.length !== ub.length) return false;
    for (let i = 0; i < ua.length; i++) if (!blip_equal(ua[i], ub[i])) return false;
    return true;
  }
  return a === b;
}

// A trampoline, which is the only way to give a backend tail calls on an engine
// that does not have them.
//
// JavaScript engines other than Safari do not implement tail call elimination,
// so `(loop 250000)`, which costs nothing on the blip machine, grows the JS
// stack and dies. A trampoline fixes it by making a tail call return a THUNK
// instead of calling: the caller returns it verbatim, so no frame is added, and
// `tramp` drives the loop.
//
// The rule the emitter follows: a call in TAIL position returns
// `thunk(() => ...)`, and a call in any other position is wrapped in `tramp`,
// because that caller's frame is still needed to receive the value. The
// difference between those two spellings is the whole mechanism.
function thunk(f) { return { __blip_thunk: f }; }

function tramp(first) {
  let step = first;
  let guard = 0;
  while (step && step.__blip_thunk) {
    step = step.__blip_thunk();
    if (++guard > 1e8) {
      throw new Error("blip: trampoline did not terminate");
    }
  }
  return step;
}
