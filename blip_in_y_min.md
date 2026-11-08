# blip in Y minutes

blip is a small Lisp dialect with a Racket-shaped surface, real tail calls, and
errors as values. This file is a one-pass tour: read top to bottom, then open
`examples/` for the runnable versions.

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
#\a         ; character
#t  #f      ; booleans (only #f is false)
"string"    ; string
'symbol     ; symbol
'(1 2 3)    ; quoted list
[1 2 3]     ; vector
{:a 1 :b 2} ; table (immutable hash map)
@(1 2 3)    ; mutable array
@{:a 1}     ; mutable buffer
```

Only `#f` is false: `0`, `""`, and `()` are all truthy.

## Definitions and functions

```lisp
(define x 10)
(define (add a b) (+ a b))

; lambda
(define square (lambda (x) (* x x)))

; fn is the short form
(map (fn [x] (* x x)) [1 2 3])   ;=> [1 4 9]

; immediately applied
((fn [a b] (+ a b)) 1 2)         ;=> 3

; rest parameters
(define (sum first . rest) (fold + first rest))
```

## Let family

```lisp
(let ([a 1] [b 2]) (+ a b))                 ; parallel
(let* ([a 1] [b (+ a 1)]) b)                ; sequential
(letrec ([even? (lambda (n) (if (= n 0) #t (odd? (- n 1))))]
         [odd?  (lambda (n) (if (= n 0) #f (even? (- n 1))))])
  (even? 100))                               ; recursive binding

; one-binding shorthand
(let x (+ 1 2) (* x 2))                     ;=> 6
```

## Control flow

```lisp
(if (< n 2) n (* n (fact (- n 1))))

(when #t (print "when"))
(unless #f (print "unless"))

(cond [(= x 1) 'one]
      [(= x 2) 'two]
      [else 'other])

(case x
  [(1 2 3) 'low]
  [(4 5 6) 'mid]
  [else 'high])

(and 1 2 3)        ;=> 3   (returns the deciding value)
(or #f #f 7)       ;=> 7

(loop i 0 (< i 5) (print i))          ; named let
(dotimes i 3 (print i))               ; 0..n-1
(begin (print 1) (print 2) 'done)
```

## Collections

```lisp
; lists
(car '(1 2 3))            ;=> 1
(cdr '(1 2 3))            ;=> (2 3)
(cons 0 '(1))             ;=> (0 1)
(length '(1 2 3))         ;=> 3

; vectors
(vector-ref [10 20 30] 1) ;=> 20

; tables
(get {:a 1} :a)           ;=> 1
(get {:a 1} :missing)     ;=> nil
(put {:a 1} :b 2)         ;=> {:a 1 :b 2}
(:a {:a 1})               ; tables are callable: lookup

; mutable arrays
(def arr @(1 2 3))
(array-set! arr 0 99)
(array-ref arr 0)         ;=> 99

; strings
(string-append "foo" "bar")   ;=> "foobar"
(format "~a and ~a" 1 "two")  ;=> "1 and two"

; threading
(->> [1 2 3]
     (filter odd?)
     (map (fn [x] (* x x)))
     (fold + 0))            ;=> 9

(-> {:a 2 :b 3} (get :a) (+ 10))   ;=> 12
```

## Pattern matching

```lisp
(match 5
  [1 'one]
  [5 'five]
  [_ 'other])                      ;=> five

(match '(1 2 3)
  [(list a b c) (+ a b c)])        ;=> 6

(match '(1 2 3)
  [(cons head tail) head])         ;=> 1

(match {:kind :dog :name "rex"}
  [{:kind :dog :name n} n])        ;=> "rex"

; multi-subject, atomic
(match* (list (safe-div 10 2) (safe-div 1 0))
  [(5 _)   'worked]
  [(_ bad) bad])                   ;=> divide-by-zero

; guards
(match '(5)
  [(list x) #:when (odd? x) 'odd])

; let assert: partial pattern, loud failure
(let assert [(list a b) '(1 2)] (+ a b))   ;=> 3
```

## Errors as values

```lisp
(ok 42)                    ;=> (ok 42)
(err 'not-found)           ;=> (err not-found)

(unwrap-or (ok 1) 0)       ;=> 1
(map-result (ok 2) (fn [x] (* x 10)))   ;=> (ok 20)
(flatten-result (ok (ok 1)))            ;=> (ok 1)
(all-results (ok 1) (ok 2))             ;=> (ok [1 2])

; use: flat chains, skips body on error
(use (parse-in "key: value")
  (print "parsed:" r1 "=" r2))

; raise is for bugs, not control flow
(raise (error "index ~a out of range" 99))

(try (raise (error "boom"))
  #:catch [(err e) (print "caught:" (err-message e))]
  #:finally [(print "cleanup")])
```

## Structs

```lisp
(struct Point (x y))
(Point 1 2)                  ;=> (Point 1 2)
(define p (Point 1 2))
(p.x)                        ;=> 1
(point? (Point 1 2))         ;=> #t

; immutable update returns a new value
(define q p.y := 99)         ; q is (Point 1 99)

; mutable
(struct Counter (n) #:mutable)
(def c (Counter 0))
(set-counter-n! c 5)
(c.n)                        ;=> 5

; opaque: constructor hidden, smart constructor only way in
(struct PositiveInt (n) #:opaque)
```

## Labelled arguments

```lisp
(define (connect #:host [h "localhost"] #:port [p 8080] #:timeout [t 30])
  (format "~a:~a/~as" h p t))

(connect)                              ;=> "localhost:8080/30s"
(connect #:port 9000)                  ;=> "localhost:9000/30s"
(connect #:timeout 5 #:host "example.com")
```

## Macros

```lisp
(defmacro unless-zero (value body)
  (list 'if (list '= value 0) '(do) body))

(macex1 (unless-zero 0 (print "never")))
;=> (if (= 0 0) (do) (print "never"))

; quasiquote
(defmacro my-when (test . body)
  `(if ,test (do ,@body) (do)))

; gensym avoids capture
(defmacro define-constantly (name value)
  (let [tmp (gensym 'tmp)]
    `(let ([,tmp ,value]) (def ,name ,tmp))))
```

## Modules

```lisp
; exporting module
(provide (struct-out Point) distance greeting DEFAULT-GREETING)

; importing
(require (only-in "lib/geometry.vl" Point distance))
(require (prefix-in geo: "lib/geometry.vl"))
(require "lib/text.vl")
```

Resolution is file-relative: `"./x.vl"` means next to this file.

## Running

```sh
blip run file.lip          # evaluate
blip test file.lip         # check ;=> expectations
blip build file.lip        # compile to JavaScript
blip fmt file.lip          # format
blip repl                  # bare `blip`
```

## Where to go next

- `examples/01_basics.lip` ... `examples/06_modules.lip` -- the six spec programs.
- `programs/` -- real programs (brainfuck, json, markdown, ...).
- `docs/000-blip-design.md` -- the design document.
- `lib/std.lip` -- the standard library, written in blip.
