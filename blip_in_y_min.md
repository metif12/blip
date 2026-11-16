# blip in Y minutes

blip is a small Lisp dialect with a Racket-shaped surface, real tail calls, and
errors as values. Read this top to bottom, then open `examples/` for the
runnable versions. If you have never written a Lisp before, the first section
is for you; if you have, skim it and start at [Definitions](#definitions-and-functions).

One spelling per idea is advertised; the others keep working forever. The
full table lives in `docs/canonical-forms.md` -- this tour uses the canonical
column (`fn`, `def`, `car`/`cdr`, `.blip` files) and names the alternative
where a migrant would reach for it.

## Lisp in sixty seconds

Everything is a parenthesised list, and the first item says what to do:

```lisp
(+ 1 2)            ;=> 3     (operator first -- this is prefix notation)
(* (+ 1 2) 3)      ;=> 9     (nesting is just lists inside lists)
```

Evaluation is one rule: evaluate each item, then apply the first to the rest.
A number evaluates to itself. A bare name looks its value up, and an unknown
name is an error rather than a guess:

```lisp
42                 ;=> 42    (a number is already its value)
```

Quoting turns code into data -- the same list, unevaluated:

```lisp
'(1 2 3)           ; a list of three integers, not a call to `1`
(quote (1 2 3))    ; the same thing, written out
''a                ; a quote of the symbol a
```

That is the whole trick behind macros, pattern matching, and programs that
write programs: code and data share one notation, and the quote switches
between them.

## Comments

```lisp
; line comment

#| block comment, and #| they nest |# |#
#;(this whole form is skipped)        ; datum comment
```

## Literals

```lisp
42          ; exact integer
3.14        ; float
1/3         ; exact rational
#\a         ; character          #\newline
#t  #f      ; booleans (only #f is false)
"a string"  ; string
'symbol     ; symbol
nil         ; nothing            ;=> nil
'()         ; the empty list     ;=> ()
'(1 2 3)    ; quoted list
[1 2 3]     ; vector
{:a 1 :b 2} ; table (immutable hash map)
@(1 2 3)    ; mutable array
@{:a 1}     ; mutable buffer
```

Only `#f` is false: `0`, `""`, `nil`, and `()` are all truthy. `nil` means
"absent" (a lookup that missed); `()` means "empty" (a list with nothing in
it). They print differently because they mean different things.

## Definitions and functions

```lisp
(def x 10)
(def (add a b) (+ a b))

; fn is the one form in v2: (lambda (x) ...) and (λ [x] ...) were removed,
; so write every closure this way: (fn [x] ...) takes the same vector params.
(map (fn [x] (* x x)) [1 2 3])   ;=> [1 4 9]
(def square (fn [x] (* x x)))
(def cube (fn [x] (* x x x)))

; immediately applied
((fn [a b] (+ a b)) 1 2)         ;=> 3

; rest parameters collect the tail
(def (sum a . more) (fold + a more))
(sum 1 2 3)                      ;=> 6
```

A function is a value like any other: it can be named, passed to `map`, or
returned. A function returned with its variables still bound is a closure --
the technique behind callbacks, counters, and private state:

```lisp
(def (adder n)
  (fn [x] (+ x n)))

(def add10 (adder 10))
(add10 5)                        ;=> 15
```

`adder` is gone by the time `add10` runs, but the `10` lives on inside the
closure. That outliving is lexical scope, and it is the default: a name means
whatever it meant where the function was written, not where it is called.

Recursion is the loop. A function that calls itself with a smaller problem
needs no `for` statement, and a call in tail position -- the very last thing
the function does -- reuses the frame instead of growing the stack, so a
million-deep countdown is a loop, not a crash:

```lisp
(def (fact n)
  (if (<= n 1)
      1
      (* n (fact (- n 1)))))

(fact 5)                         ;=> 120
```

## Let family

```lisp
(let ([a 1] [b 2]) (+ a b))                 ; parallel: neither sees the other
(let* ([a 1] [b (+ a 1)]) b)                ; sequential: later sees earlier
(letrec ([even? (fn (n) (if (= n 0) #t (odd? (- n 1))))]
         [odd?  (fn (n) (if (= n 0) #f (even? (- n 1))))])
  (even? 100))                               ; recursive: each sees the other

; one-binding shorthand: `(let NAME VALUE body...)` binds one name with no
; brackets. Deliberately prominent because no other Lisp spells it this way:
; the second position is a VALUE here, but a BINDING GROUP in `(let ([a 1]) ...)`.
(let x (+ 1 2) (* x 2))                     ;=> 6
```

## Control flow

```lisp
; `if` is an expression: it answers, not just branches
(if (< n 2) n (* n (fact (- n 1))))

(if #t (begin (print "when")))
(unless #f (print "unless"))

(cond [(= x 1) 'one]
      [(= x 2) 'two]
      [else 'other])

;; `case` is gone in v2: literal-`match` dispatches on values the same way.
(match x
  [1 'low]
  [2 'low]
  [3 'low]
  [4 'mid]
  [5 'mid]
  [6 'mid]
  [_ 'high])

(and 1 2 3)        ;=> 3   (returns the deciding value, not a boolean)
(or #f #f 7)       ;=> 7

(loop i 0 (< i 5) (print i))          ; named let: `loop` IS a named `let`
(dotimes i 3 (print i))               ; 0..n-1: counting loops read better
(begin (print 1) (print 2) 'done)     ; sequencing: run all, answer the last
```

## Collections

Six literals cover almost everything, and the brackets tell you the type --
no predicate needed to know what you are holding:

```lisp
; lists: the universal sequence, built from cons cells
(car '(1 2 3))            ;=> 1
(cdr '(1 2 3))            ;=> (2 3)
(cons 0 '(1))             ;=> (0 1)
(length '(1 2 3))         ;=> 3
; (first/rest are the same operations under other names)

; vectors: dense, indexable, immutable
(vector-ref [10 20 30] 1) ;=> 20
(vector-append [1] [2])   ;=> [1 2]

; tables: immutable hash maps, keyed by keyword
(get {:a 1} :a)           ;=> 1
(get {:a 1} :missing)     ;=> nil      (absent is nil, not an error)
(put {:a 1} :b 2)         ;=> {:a 1 :b 2}
(:a {:a 1})               ; tables are callable: a lookup in function place

; mutable arrays: the @ prefix says so, with no type annotation to read
(def arr @(1 2 3))
(array-set! arr 0 99)     ; mutates in place, answers nothing
(array-ref arr 0)         ;=> 99
(array-push! arr 4)       ; grows the end

; strings
(string-append "foo" "bar")   ;=> "foobar"
(format "~a and ~a" 1 "two")   ;=> "1 and two"

; threading: pipelines that read top to bottom
(->> [1 2 3]
     (filter odd?)         ; keep the odds: [1 3]
     (map (fn [x] (* x x))) ; square them: [1 9]
     (fold + 0))           ; add them up: 10

(-> {:a 2 :b 3} (get :a) (+ 10))   ;=> 12

; the rule: `->` puts the value FIRST, `->>` puts it LAST. A bare symbol
; is not a call, so it has nowhere to put a value -- write the call.
; The two forms are not interchangeable.
```

## Pattern matching

`match` destructures one value. `match*` destructures several at once,
atomically -- a clause is tried only if every pattern matches, and each
subject is evaluated exactly once:

```lisp
(match 5
  [1 'one]
  [5 'five]
  [_ 'other])                      ;=> five

(match '(1 2 3)
  [(list a b c) (+ a b c)])        ;=> 6

(match '(1 2 3)
  [(cons head tail) head])         ;=> 1   (cons destructuring)

(match {:kind :dog :name "rex"}
  [{:kind :dog :name n} n])        ;=> "rex"

; multi-subject, atomic: two values, one clause list, no nesting.
; Each clause wraps its patterns in their own list; the body follows it:
(match* (list 1 2)
  [(a b) (+ a b)])   ;=> 3

; guards test the bindings in scope
(match '(5)
  [(list x) #:when (odd? x) 'odd])

; let assert: a deliberately partial pattern, with a loud failure
(let assert [(list a b) '(1 2)] (+ a b))   ;=> 3
```

Patterns also destructure in bindings and parameters -- `(let ([(list h t)
'(1 2)]) ...)` and `(def (dist (struct Point x: px y: py)) ...)` work the
way the `match` lines above suggest they should.

## Errors as values

A function that can fail in a way the caller should handle returns a value
that says so -- `(ok v)` or `(err 'why)` -- instead of throwing:

```lisp
(ok 42)                    ;=> (ok 42)
(err 'not-found)           ;=> (err not-found)

(unwrap-or (ok 1) 0)       ;=> 1   (a default for the bad case)
(map-result (ok 2) (fn [x] (* x 10)))   ;=> (ok 20)
(flatten-result (ok (ok 1)))            ;=> (ok 1)   (peel one level)
(all-results (ok 1) (ok 2))             ;=> (ok [1 2])

; use: flat chains, skips body on error -- no staircase of nested checks
(use (parse-in "key: value")
  (print "parsed:" r1 "=" r2))
```

`raise` is the other mechanism, for the cases that are bugs rather than
outcomes: invariant violations, impossible states. `try` catches with
`#:catch` and always runs `#:finally`:

```lisp
(try (raise (error "index ~a out of range" 99))
  #:catch [(err e) (print "caught:" (err-message e))]
  #:finally [(print "cleanup")])
```

The rule of thumb: if the caller should handle it, return a `Result`. If it
is impossible, `raise`. Half a design serves neither.

## Structs

```lisp
(struct Point (x y))
(Point 1 2)                  ;=> (Point 1 2)
(def p (Point 1 2))
(p.x)                        ;=> 1        (field access)
(point? (Point 1 2))         ;=> #t      (a predicate per struct)

; immutable update returns a new value, leaving the original alone
(def q p.y := 99)            ; q is (Point 1 99), p is still (Point 1 2)

; #:mutable for the rare in-place case
(struct Counter (n) #:mutable)
(def c (Counter 0))
(set-counter-n! c 5)          ; the mutator is set-STRUCTNAME-FIELD!
(c.n)                        ;=> 5

; opaque: the type name is public, the constructor is not. Only a smart
; constructor can make one, so the invariant holds with no class system,
; no interfaces, and no inheritance:
(struct PositiveInt (n) #:opaque)
```

## Labelled arguments

```lisp
(def (connect #:host [h "localhost"] #:port [p 8080] #:timeout [t 30])
  (format "~a:~a/~as" h p t))

(connect)                              ;=> "localhost:8080/30s"
(connect #:port 9000)                  ;=> "localhost:9000/30s"
(connect #:timeout 5 #:host "example.com")   ; order does not matter
```

Arguments stay positional underneath, so this is pure sugar -- but it is one of
the most effective fixes for Lisp's argument-order readability problem, since
it survives reordering where an `assoc`-based convention does not.

## Macros

Everything above used no macros at all. That is the point: macros are for
the cases that genuinely need them -- new syntax, not new functions.

```lisp
; define a macro: defmacro runs at compile time and returns code
(defmacro unless-zero (value body)
  (list 'if (list '= value 0) '(begin) body))

; macex1 expands one step -- the debugging window a macro language needs
(print (macex1 (unless-zero 0 (print "never"))))
;=> (if (= 0 0) (begin) (print "never"))

; quasiquote builds code without nested list constructors
(defmacro my-when (test . body)
  `(if ,test (begin ,@body) (begin)))

; gensym for generated names -- the fix for accidental capture, which is
; the sharp edge of an unhygienic macro system
(defmacro define-constantly (name value)
  (let [tmp (gensym 'tmp)]
    `(let ([,tmp ,value])
       (def ,name ,tmp))))
```

## Modules

```lisp
; exporting module
(provide (struct-out Point) distance greeting DEFAULT-GREETING)

; importing: only what is needed, qualified when names might collide
(require (only-in "lib/geometry.blip" Point distance))
(require (prefix-in geo: "lib/geometry.blip"))
(require "lib/text.blip")
```

Resolution is file-relative: `"./x.blip"` means next to this file, never in
the working directory. Each module loads once, no matter how many files
require it.

## Printing

`print` joins its arguments with spaces and ends the line; strings print
with their quotes and `display` shows them bare:

```lisp
(print "a" 1)        ; "a" 1, then the line ends
(display "a" 1)      ; a 1, then the line ends
```

(A verbatim `print` plus `println` is proposed for the next version; see
the roadmap.)

## Running

```sh
blip run file.blip         # evaluate (v2 loads `.blip` only)
blip test file.blip        # check ;=> expectations (top-level forms only)
blip build file.blip       # compile to JavaScript
blip fmt file.blip         # format
blip repl                  # bare `blip`
```

## Where to go next

- `examples/` -- the seven spec programs that define the syntax; all parse.
- `programs/` -- real programs (brainfuck, json, markdown, ...).
- `docs/canonical-forms.md` -- the one-spelling-per-idea table.
- `docs/000-blip-design.md` -- the design document: motivation, trade-offs.
- `lib/std.blip` -- the standard library, written in blip itself.
