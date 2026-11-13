# Moss: a tiny ML with Hindley–Milner inference, written in Haskell

Moss is a small, strict functional language in the ML family. You never write a type annotation. The compiler infers the **most general type** of every definition, checks your **algebraic data types** and **pattern matches**, warns you about **non-exhaustive or unreachable match arms** (with a concrete counterexample), and then runs the program.

It is about 1,800 lines of Haskell with no dependencies beyond the libraries that ship with GHC. The parser, type checker, match checker, evaluator and fuzzer are all hand-written.

```
moss> let twice f x = f (f x)
twice : (a -> a) -> a -> a = <fun>
moss> data Tree a = Leaf | Node (Tree a) a (Tree a)
Leaf : Tree a
Node : Tree a -> a -> Tree a -> Tree a
moss> let rec insert x t = match t with | Leaf -> Node Leaf x Leaf | Node l y r -> if x < y then Node (insert x l) y r else Node l y (insert x r)
insert : a -> Tree a -> Tree a = <fun>
moss> [5, 2, 8, 1, 9, 3] |> foldl (fun t x -> insert x t) Leaf |> to_list
- : List Int = [1, 2, 3, 5, 8, 9]
moss> let head xs = match xs with | x :: _ -> x
1:15: warning: this match is not exhaustive; for example, this value is not matched:
    []
head : List a -> a = <fun>
moss> fun f -> f f
<repl>:1:10: type error: this expression has type a but is applied as a function of type a -> b
    (infinite type: a = a -> b)
1 | fun f -> f f
             ^
```

## Why it's interesting

- **Hindley–Milner type inference** (Algorithm W) with let-polymorphism, mutually recursive `let rec … and …`, pattern bindings, and user-defined parameterised data types, including nested ones such as `data Rose a = Rose a (List (Rose a))`. The S, K and Church-numeral combinators all get their textbook types (`tests/types.moss`).
- **Error messages that point at the problem.** Errors show the source line and a caret. They explain which side expected what, with type variables named consistently across both types, and they show the inner conflict when it differs from the outer one, for example `(cannot match Int with String)` or `(infinite type: a = a -> b)`.
- **Maranget's usefulness algorithm** ("Warnings for pattern matching", JFP 2007) decides exhaustiveness and redundancy over nested constructors, tuples, booleans and integer or string literals. For a missing case it builds a **witness**, the exact value you forgot, such as `([], _ :: _)` or `Triangle _ _ _`.
- **The prelude is written in Moss itself** (`src/Prelude.moss`): `List`, `Option`, `Result`, `map`, `foldr`, merge sort and more. It is parsed, inferred and match-checked at startup like any user program and is embedded into the binary with Template Haskell.
- **Empirical proof of type safety.** `moss --fuzz N` generates random untyped programs, type-checks them, runs the ones that are accepted and checks three theorems on every run:
  1. *Progress*: a well-typed program never gets stuck (no applying an integer, no `if` on a string).
  2. *Preservation*: the final value really has the inferred type, checked structurally even for user data types.
  3. *Exhaustiveness*: if the checker reported no missing case, no match ever fails at run time.

  To check that the fuzzer can catch bugs, I planted some in the checker. Making unification ignore type-constructor names gave 117 violations in 20,000 programs. Making the boolean signature incomplete was caught too.

## Build and run

Requires GHC (tested with 9.4; `apt install ghc` is enough).

```bash
./build.sh                       # produces ./moss
./moss examples/tour.moss        # run a program
./moss --types examples/rbtree.moss   # print inferred types of all top-level names
./moss                           # REPL (:t EXPR shows a type, :q quits)
./moss --fuzz 200000             # soundness fuzzer
tests/run.sh                     # golden tests + fuzzer
```

## The language

```ocaml
data Shape = Circle Int | Rect Int Int          -- algebraic data types
let area s = match s with                        -- pattern matching
  | Circle r -> 3 * r * r
  | Rect w h -> w * h
let rec is_even n = if n == 0 then true else is_odd (n - 1)
and is_odd n = if n == 0 then false else is_even (n - 1)
let swap (a, b) = (b, a)                         -- patterns in parameters
let total = [1, 2, 3] |> map (fun x -> x * x) |> foldl (+) 0
let _ = print ("30! = " ^ show (fact 30))        -- arbitrary-precision Int
```

Literals are `Int` (bignum), `String`, `Bool` and `()`. You also get tuples, lists (`[1, 2]`, `x :: xs`, `xs @ ys`), `|>`, operator sections like `(+)`, short-circuit `&&` and `||`, and `e1; e2` sequencing. Polymorphic structural `==`, `<` and `compare` work like OCaml's: comparing functions is a runtime error. A single polymorphic `show` covers printing. Strings have `^`, `str_len`, `chars` and `implode`.

## Examples

| File | What it shows |
|---|---|
| `examples/tour.moss` | Polymorphism, closures, bignums, mutual recursion, Option/Result, strings |
| `examples/rbtree.moss` | Okasaki red-black trees: the four-rotation `balance` as one nested match. Inserts 2,000 scrambled keys and checks both RB invariants and the sorted order |
| `examples/queens.moss` | N-queens by backtracking: 92 solutions for n = 8 |
| `examples/deriv.moss` | Symbolic differentiation and simplification, checked against a 5-point finite-difference stencil |
| `examples/stackvm.moss` | A compiler from a let-language to stack bytecode plus the VM to run it, differentially tested against an interpreter on 300 random programs |
| `examples/errors/*.moss` | Type errors and match warnings |

Sample output:

```
$ ./moss examples/rbtree.moss
inserted keys        : 2000 (1979 distinct)
tree size            : 1979
height               : 15  (a plain BST on sorted input would be 1979)
in-order == sorted   : true
no red-red violations: true
black height         : Some 10
member checks        : (true, false)
4095 ascending keys  : height 12, black height Some 13

$ ./moss examples/errors/warnings.moss
examples/errors/warnings.moss:4:14: warning: this match is not exhaustive; for example, this value is not matched:
    Triangle _ _ _
examples/errors/warnings.moss:9:19: warning: match arm 2 is unreachable (earlier arms cover it)
examples/errors/warnings.moss:20:21: warning: this match is not exhaustive; for example, this value is not matched:
    ([], _ :: _)
12
examples/errors/warnings.moss:4:14: runtime error: match failure
4 | let area s = match s with
                 ^

$ ./moss examples/errors/list_of_mixed.moss
examples/errors/list_of_mixed.moss:2:49: type error: this argument has type List (Int, String) but the function expects List (a, Int)
    (cannot match Int with String)
2 | let total = foldl (fun acc (n, s) -> acc + s) 0 pairs
                                                    ^

$ ./moss --fuzz 200000
random programs generated : 200000
rejected by type checker  : 175910 (88.0%)
well-typed, then run      : 24090
  produced a value of the inferred type : 23938
  raised a runtime error (div by 0, error, compare <fun>) : 74
  match failure (checker had warned) : 77
  out of fuel (diverging) : 1
  SOUNDNESS VIOLATIONS : 0
```

## How it works

| Module | Role |
|---|---|
| `Lexer.hs` | Positioned tokens; `--` comments; string escapes |
| `Parser.hs` | Recursive descent with precedence climbing (8 operator levels with OCaml-like associativity). Desugars `fun (a, b) -> …`, list literals, `::`, `&&`/`||` (into `if`) and `|>` |
| `Infer.hs` | Algorithm W. A state monad holds a fresh-variable supply and a substitution, zonked with path compression. Unification has an occurs check. Generalisation quantifies the variables that are free in the type but not in the environment. Each pattern-bound variable is generalised separately, and `let rec` groups are inferred monomorphically and then generalised together. Data declarations become constructor schemes `∀ā. τ₁ → … → T ā` |
| `Exhaust.hs` | Patterns are reduced to heads (constructor, tuple, literal) over a matrix. `useful P q` specialises by each head of a complete signature, or falls back to the default matrix. The same recursion that returns `True` also rebuilds a witness, choosing a missing constructor, or for infinite types like `Int` a literal that isn't listed |
| `Eval.hs` | Strict environment-passing interpreter. Recursive closures are tied with Haskell laziness (`env' = insert f (Closure env' …) env`). It uses `Integer` arithmetic, OCaml-style structural comparison, and a fuel counter so the fuzzer can cut off divergent programs |
| `Fuzz.hs` | SplitMix64 RNG and a random program generator over lambdas, `let`, `let rec`, `if`, tuples, constructors, primitives and `match`. Arms are drawn from a common pattern "family" so that well-typed matches are common. A structural `conforms :: Type -> Value -> Bool` checks preservation |
| `Main.hs` | Runner, `--types`, REPL and compiler-style diagnostics |

Design notes:

- **Whole-program check before running.** A file is fully type-checked first and runs only if every declaration is well typed, as a compiler would require.
- **No value restriction is needed.** The language has no mutable references, so generalising every `let` is sound. The fuzzer agrees.
- **Unit patterns count as wildcards** in the match checker because `()` has exactly one value. Booleans have the two-constructor signature `{false, true}`. Integers and strings have infinite signatures, so a match on them is exhaustive only with a catch-all arm.
