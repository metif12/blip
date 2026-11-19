# The tour

blip is a Lisp: programs are S-expressions, evaluation is substitution plus a small set of special forms, and the standard library is ordinary blip. This page walks the whole language in order. Every snippet runs — paste it into the [playground](playground.html) or a `.blip` file and try it.

## Programs

A file is a sequence of forms, evaluated top to bottom. A semicolon starts a line comment, `#| ... |#` is a nestable block comment, and `#;` skips exactly one form.

```
; a line comment

#| a block comment
   #| nested |#
   still inside |#

#;(this form is skipped)
```

## Literals

Numbers are exact where it matters: integers, floats, and rationals like `1/3`. Characters start with `#\`, strings double-quote, and a quoted symbol evaluates to itself.

```
42                ; integer
3.14              ; float
1/3               ; exact rational
#\a               ; character
#t                ; true (and #true)
#f                ; false (and #false)
"a string"        ; string
'symbol           ; a symbol
'(1 2 3)          ; a quoted list
```

Only `#f` is false. Everything else — `0`, `""`, the empty list — counts as true.

The tower is minimal and explicit: `+`/`-`/`*` over integers and rationals stay exact (`(+ 1/3 1/6)` is `1/2`), a float anywhere contaminates to float, and `(/ 3 2)` is `1.5` while `(/ 4 2)` is `2` — integer division with an exact answer stays whole. Equality is representation-strict: `2` is not `2/1` and `1/2` is not `0.5`.

## Definitions and functions

`def` is the whole ceremony. There is no `defn`, no `function` keyword.

```
(def x 10)
(def (add a b) (+ a b))
(def (greet name) (format "Hello, ~a." name))
```

`fn` makes an anonymous function; `map`, `filter`, and `fold` take them the way you expect.

```
(map (fn [x] (* x x)) [1 2 3])      ;=> [1 4 9]
(filter even? [1 2 3 4])            ;=> [2 4]
(fold + 0 [1 2 3])                  ;=> 6
```

Arithmetic and comparison are variadic, and `=` compares by value, not identity.

```
(+ 1 2 3)         ;=> 6
(= 1 1 1)         ;=> #t
(= '(1 2) '(1 2)) ;=> #t
```

Tail calls reuse the frame, so recursion is a loop. A million deep returns.

```
(def (count-down n acc)
  (if (= n 0)
      acc
      (count-down (- n 1) (+ acc 1))))

(count-down 1000000 0)  ;=> 1000000
```

Mutual recursion qualifies too: `ping` calling `pong` calling `ping` never grows the stack.

## Bindings

`let` binds in parallel, `let*` sequentially, `letrec` for recursion. Binding groups use square brackets; everywhere else, brackets are vector literals.

```
(let ([a 1] [b 2]) (+ a b))            ; parallel
(let* ([a 1] [b (+ a 1)]) b)          ; sequential
```

Bindings destructure, in `let` and in parameter position:

```
(let ([(list h t) '(1 2)]) (+ h t))     ;=> 3
(let ([{:kind k} {:kind :dog}]) k)      ;=> :dog
```

## Control flow

`if` plus `when`/`unless` for one branch, `cond` for many, `case` for value dispatch. `and`/`or` return the deciding value, not a boolean.

```
(if #t (begin (println "when")))
(unless #f (println "unless"))

(cond [(= 1 2) 'no]
      [(= 1 1) 'yes]
      [else 'unreachable])               ;=> yes

;; `case` is gone in v2: literal-`match` dispatches on values the same way,
;; with destructuring where `case` had only data.
(match 5
  [1 'low]
  [2 'low]
  [3 'low]
  [4 'mid']
  [5 'mid']
  [6 'mid']
  [_ 'high])                            ;=> mid

(and 1 2 3)       ;=> 3
(or #f #f 7)      ;=> 7
```

`loop` is named-let recursion, `dotimes` counts from zero, `begin` sequences side effects.

```
(loop i 0 (< i 5) (println i))
(dotimes i 3 (println i))
(begin (println 1) (println 2) 'done)
```

## Data

Lists are immutable cons cells; vectors are immutable and indexable; tables are immutable maps keyed by keyword; arrays and buffers are the mutable ones, marked with `@`.

```
(car '(1 2 3))              ;=> 1
(cdr '(1 2 3))              ;=> (2 3)
(cons 0 '(1))               ;=> (0 1)

(vector-ref [10 20 30] 1)   ;=> 20

(get {:a 1} :missing)       ;=> nil, absent is nil, not an error
(get {:a 1} :missing "d")   ;=> "d", with a default
(put {:a 1} :b 2)           ;=> {:a 1 :b 2}

(def arr @(1 2 3))
(array-set! arr 0 99)
(array-ref arr 0)           ;=> 99
```

A table or struct in function position looks its argument up, so `(:a {:a 1})` is `(get {:a 1} :a)`. Strings have a full toolkit: `string-append`, `string-split`, `string-trim`, `string-upcase`, `format`, and more.

## Pipelines and labelled arguments

Three threading forms cover three habits. `->>` puts the value last, `->` puts it first, `|>` adapts and doubles as a debugger with `echo` taps.

```
(->> [1 2 3]
     (filter odd?)
     (map (fn [x] (* x x)))
     (fold + 0))                 ;=> 35

(->> [1 2 3 4 5]
     |> echo                    ; prints here, passes through
     (filter odd?)
     (fold + 0))                 ;=> 10
```

Labelled arguments are positional underneath — pure sugar, and one of the most effective fixes for argument-order readability, since it survives reordering where an assoc-based convention does not.

```
(def (connect #:host [h "localhost"] #:port [p 8080]) (format "~a:~a" h p))
(connect)                       ;=> "localhost:8080"
(connect #:port 9000)           ;=> "localhost:9000"
```

## `match` and `match*`

`match` destructures one value. List patterns are positional with a tail rule: `(list a b c)` wants exactly three, `(list 1 rest)` binds the remainder to `rest`, `(list a b c _)` pins the length. Comparison patterns apply the subject first, so `(>= 10)` reads as "at least 10". Guards test with bindings in scope.

```
(match '(1 2 3)
  [(list a b c) (+ a b c)])             ;=> 6

(match 42
  [(>= 100) 'huge]
  [(>= 10)  'big']
  [_ 'small])                           ;=> big
```

`match*` destructures several values at once, atomically. A clause holds one pattern per subject inside its own list -- every pattern must match for the clause to try -- and answers with its body.

```
(match* (list 1 2)
  [(a b) (+ a b)])                  ;=> 3

(match* (list 1 3)
  [(a 2) 'two])                     ;=> nil, the second pattern misses
```

Literals in pattern position are the self-evaluating ones: numbers, strings, keywords. A quoted symbol is a list, so it never matches a bare value; a bare symbol always binds.

`let assert` is the deliberately partial cousin: a pattern you are certain about, with a loud failure naming the pattern when you are wrong.

## Printing

`print` writes its arguments joined with spaces and VERBATIM -- no trailing
newline; strings print with their quotes. `println` is the old `print` (same
joining, then the line ends). `display` is bare (strings without quotes) plus
no newline, the Scheme spelling.

```
(println "a" 1)      ; "a" 1, then the line ends
(print "a" 1)        ; "a" 1, no newline after it
(display "a" 1)      ; a 1, no newline after it
```

## Errors are values, `use` keeps them flat

`(ok v)` and `(err 'why)` are ordinary values with a small combinator set (`map-result`, `unwrap-or`, `flatten-result`, `all-results`, and lazy variants that never run the thunk unless needed). `use` binds a call's results and runs the body at the same indentation; if any step is an error, the body is skipped and the error is the value.

```
(use (parse-in "key: value")
  (println "parsed:" r1 "=" r2)
  (println "all good"))
```

`raise` is the other mechanism, for invariant violations — bugs, not outcomes. `try` catches with `#:catch` and always runs `#:finally`.

```
(try (raise (error "index ~a out of range" 99))
  #:catch [(err e) (println "caught:" (err-message e))]
  #:finally [(println "cleanup runs either way")])
```

The rule of thumb: if the caller should handle it, return a Result; if it is impossible, raise.

## Structs and opaque types

Structs bundle fields with a constructor, predicate, and accessors. Plain structs are immutable — updating returns a new value — with `#:mutable` for the rare in-place case.

```
(struct Point (x y))
(def p (Point 1 2))
(p.x)                        ;=> 1
(def q p.y := 99)         ; q is (Point 1 99), p unchanged
```

`#:opaque` hides the constructor: the type name is public, the only way in is a smart constructor that returns a Result, so the invariant cannot be broken.

```
(struct PositiveInt (n) #:opaque)

(def (positive-int n)
  (if (> n 0)
      (ok (PositiveInt n))
      (err 'not-positive)))
```

Encapsulation by export metadata — no classes, no interfaces, no inheritance.

## Macros, available but optional

Everything above uses no macros at all. When a case genuinely needs one, `defmacro` runs at compile time and returns code, quasiquote builds it, `macex1` shows one expansion step, and `gensym` fixes capture.

```
(defmacro unless-zero (value body)
  (list 'if (list '= value 0) '(begin) body))

(macex1 (unless-zero 0 (println "never")))
;=> (if (= 0 0) (begin) (println "never"))
```

## Fibers

A fiber is a suspended computation: `spawn` takes a thunk and answers an id, `resume` drives the fiber to its next `yield` (or to the end), `fiber-status` names its state (`ready`, `suspended`, `paused`, `done`, `failed`), and `fiber-done?` asks if it finished. `resume` takes an optional step budget: a fiber that outruns it pauses and continues on the next resume, so no fiber runs away. Fibers pair with `use` and `Result` — a fiber that yields errors is just data to match on — and they run on the machine only: node output cannot suspend, so the emitter refuses them.

```
(def f (spawn (fn [] (yield 1) (yield 2) 'done)))
(resume f)        ;=> 1
(fiber-status f)  ;=> :suspended
(resume f)        ;=> 2
(resume f)        ;=> done
(fiber-done? f)   ;=> #t
```

One boundary: `yield` inside a `map` callback (or macro expansion) is refused rather than silently corrupted — the callback lives in a host-side loop the saved state cannot resume. Yield in straight-line code and plain function calls suspends fine.

A project that never wants concurrency switches it off in `blip.mod`: `(features (fibers #f))` makes the whole family unbound.

## Modules

`provide` exports names, `require` loads a file, `only-in` imports selected names, `prefix-in` qualifies a whole module. Resolution is file-relative — `./x.blip` means next to this file — and each module loads once.

```
(require (only-in "lib/geometry.blip" Point distance))
(require (prefix-in geo: "lib/geometry.blip"))
```

The loaded set is data, not hidden state: `(module-paths)` answers the list of loaded files in load order, so a program can inspect what it stands on.

## Contracts and `check`

`define/contract` checks arguments (and optionally the result) on every call, desugared to `assert`, so a violation is an ordinary error. Annotations `(x int)` erase at run time — the machine never sees them — and `blip check` reports the mismatches statically: wrong arity, literal argument of the wrong type, a body contradicting its declared return, a `match*` clause with the wrong number of patterns. A `match` without an `else` warns; `--strict` turns the warning into an error.

```
(define/contract (halve x) (->/c even?) (/ x 2))
(halve 8)   ;=> 4
(halve 7)   ;=> contract violation

(def (add (x int) (y int)) int (+ x y))
```

Unknown names are never errors: unannotated functions, the prelude, and macros unify with everything. A clean `check` is not a proof, but a reported mismatch names a real bug — without evaluating anything, so checking hostile code is safe.

## Appendix: from Racket/Scheme?

v2 keeps one spelling per idea. Removed primitives come back with one
line in your own file — the core does not carry these aliases:

```
(def keep filter)
(def first car)
(def rest cdr)
```

Removed special forms (`define`, `lambda`, `do`, `when`, `case`) cannot
be aliased back: special forms win over macros, so a `defmacro` with the
old name never runs. Write the canonical spelling (`def`, `fn`, `begin`,
`if`, `match`), or let `blip migrate` rewrite the file for you:
`blip migrate <file|dir>`.

---

That is the whole language. The [CLI reference](cli.html) covers the tooling, [embedding](embedding.html) covers driving blip from V and C, and [status](status.html) shows what is done and what is next.
