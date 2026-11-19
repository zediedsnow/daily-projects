# Horn: a Prolog interpreter in Elixir

Horn is a Prolog system written from scratch in Elixir with no dependencies. It has a tokenizer, an operator-precedence parser with a runtime-editable `op/3` table, a resolution engine with full cut semantics, exceptions, DCGs, 134 builtins written in Elixir plus a Prolog-level library, a REPL, and a **differential fuzzer that checks it against SWI-Prolog**.

On **300,000 randomly generated programs and queries** (209,859 answers and 94,166 error terms compared), Horn gives the same output as SWI-Prolog 9.0.4 for **299,995** of them. The two that differ come from an inconsistency inside SWI itself (see [below](#what-the-fuzzer-found)).

```
$ ./horn --fuzz 100000 2026
fuzzing 100000 programs (300000 queries) in 1000 batches, seed 2026, 2 jobs
queries compared:      299997
answers compared:      209859
queries raising errors 94166  (error terms compared too)
mismatches:            2
time:                  98.2 s
```

## Why it's interesting

Most toy Prologs stop at "append works". The difficult parts are the semantics people rarely spell out:

* **Cut has to be exactly right.** It must be local inside `\+`, `call/1`, `findall/3`, `catch/3` and the condition of `->`. It must be transparent through `,` `;` and the *then* branch. Soft-cut `*->` must keep every solution of its condition while killing the else branch.
* **Exceptions have to unwind correctly.** That means choicepoints and bindings, catchers that stop being active once their goal exits, balls that are copied, and the exact ISO error term that each builtin raises.
* **Backtracking interacts with side effects.** `assert`/`retract` follow the *logical update view*: a running call doesn't see clauses added or removed while it runs.

The fuzzer is how this gets checked. It generates random but provably terminating programs that mix all of these features. It runs every query in both Horn and `swipl` and diffs the answer lists (or the thrown error terms) line by line.

## Build and run

Requires Elixir ≥ 1.14 (tested with Elixir 1.14 / OTP 24). The fuzzer also needs `swipl` on the PATH.

```bash
mix escript.build          # produces ./horn
./horn                     # interactive toplevel
./horn examples/zebra.pl   # programs with :- initialization(main, main).
./horn file.pl -g 'goal'   # consult, run one goal, exit
mix test                   # 23 ExUnit tests
./horn --fuzz 3000 8       # differential fuzzing against SWI-Prolog (N programs, seed)
```

## Sample output

Toplevel:

```
$ ./horn
Horn Prolog (Elixir 1.14.0) - type halt. to quit
?- append(X, Y, [1,2]).
X = [],
Y = [1,2] ;
X = [1],
Y = [2] ;
X = [1,2],
Y = [] .

?- X is 2 ** 64.
X = 18446744073709551616.

?- foo(1).
ERROR: Unknown procedure: foo/1
```

`examples/zebra.pl` solves Einstein's riddle with pure unification, using `format/2` column stops:

```
color     nation      pet       drink         smokes
yellow    norwegian   fox       water         kools
blue      ukrainian   horse     tea           chesterfield
red       english     snails    milk          oldgold
ivory     spanish     dog       orange_juice  lucky_strike
green     japanese    zebra     coffee        parliament

The japanese owns the zebra; the norwegian drinks water.
(22,962 inferences, 28 ms)
```

`examples/calc.pl` is a calculator: a DCG tokenizer and parser, an evaluator built from `yall` lambdas and bignums, and errors reported through `catch/3`:

```
> 2 ^ 3 ^ 2
  512
> -2 ^ 2
  -4
> y = x * 4 - -1
  y = 15.0
> fact(25)
  15511210043330985984000000
> 10 / 0
  error: evaluation_error(zero_divisor)
> nope(1)
  error: unknown_function(nope/1)
```

`examples/meta.pl` is a meta-interpreter that uses `clause/2` and prints proof trees:

```
Why is tom an ancestor of joe?
ancestor(tom,joe)
  parent(tom,bob)  (fact)
  ancestor(bob,joe)
    parent(bob,ann)  (fact)
    ancestor(ann,joe)
      parent(ann,joe)  (fact)
```

The output of `queens.pl`, `zebra.pl`, `calc.pl` and `meta.pl` is byte-for-byte identical to running the same files with `swipl` (inference counts excluded).

## How it works

| file | what's in it |
|---|---|
| `lexer.ex` | Tokens remember whether whitespace came before them, which is how `foo(a)` differs from `foo (a)` and `-1` from `- 1`. Handles `0'c`, `0x..`, quoted escapes and comments. |
| `parser.ex` | Operator-precedence parser (xfx/xfy/yfx/fy/fx/xf/yf) over a dynamic op table, prefix-operator-as-atom disambiguation, `{}`/lists/`|`. |
| `term.ex` | Term representation, unification (with optional occurs check), standard order of terms, copying. |
| `engine.ex` | The machine (described below), clause store, first-argument indexing, consulting and directives. |
| `builtins.ex` | 134 builtins, ISO error terms, `format/2` with `~t~|` column alignment, `bagof`/`setof` with `^`. |
| `prelude.ex` | Library predicates written in Prolog: lists, apply, `foldl`, `predsort`, the DCG translator, yall lambdas. |
| `writer.ex` | `write`/`writeq`/`print`/`write_canonical` with operator-aware spacing and quoting, SWI float format. |
| `fuzz.ex` | Program generator plus the differential driver. |

**Terms** are plain Elixir data. Atoms are binaries, `{:v, id}` are variables and `{:c, name, args}` are compounds. Integers are native bignums. **Bindings** live in an immutable map. Because Erlang maps are persistent, a choicepoint just keeps a pointer to the map it started with, so backtracking needs no trail and no undo.

**The engine** is an iterative machine that runs on two stacks:

```
goals:        [{:call, Goal, CutBarrier} | ...]      continuation (what's left to prove)
choicepoints: [{:alt, Goals, Subst}, {:clauses, ...}, {:gen, NextFun}, {:catch, ...}]
```

Every `{:call, G, B}` frame records the depth of the choicepoint stack that a `!` inside `G` cuts back to. A clause body gets the depth from just before its own alternatives were pushed. `call/1` and `\+` get the current depth, which makes them opaque. `,` and `;` pass on the barrier they received, which makes them transparent. If-then-else pushes the else branch and runs `{:call, Cond, d+1}, {:cut_to, d}, {:call, Then, B}`. Nondeterministic builtins (`between/3`, `retract/1`, `sub_atom/5`, ...) are lazy generators that run each step only when the engine backtracks into them. All the dispatch functions are mutually tail-recursive, so deterministic recursion runs in constant Elixir stack (`count(1000000)` is fine).

**Exceptions** walk the choicepoint stack down to the nearest `catch/3` frame that is still active. A frame is active only while its goal is running. That state is tracked as a set of catch IDs that each choicepoint snapshots, so backtracking *into* a catch goal reactivates it.

## What the fuzzer found

The generator builds programs where predicate `p_k` may only call `p_j` with `j < k`. Library recursion only ever receives proper lists, and the occurs check is on in both systems. Together these guarantee that every query terminates. A per-query `call_with_inference_limit/3` catches the remaining assert-driven blowups, and such queries are skipped. Answers are printed by a small Prolog printer that both systems run, so formatting can't cause false mismatches.

Starting from hundreds of mismatches per 10k queries, the fuzzer found real bugs in Horn and several undocumented behaviours of SWI-Prolog:

* **SWI picks the `catch/3` frame *before* undoing bindings.** In `catch(p([a|X]), ball(X), true)`, where `p` binds `X` and then throws `ball(g)`, SWI does **not** catch: at throw time `X` is still bound, so `ball(X)` doesn't match. ISO says it should. Horn now does the same pre-check, including for throws that escape nested `findall/3` engines.
* **`[]` is not an atom** in SWI-Prolog 7+. `atom([])` fails, `[] \== '[]'`, and `[]` sorts before every atom.
* **Arithmetic arguments are evaluated right to left**, and an unknown function is reported only after its arguments have been evaluated. So `X is f(a) + Y` raises `instantiation_error`, not `type_error(evaluable, f/1)`.
* **`=..` checks the list element by element.** `c =.. [X|-1]` raises `type_error(list, -1)`, but `f(a) =.. [f,a,b|c]` simply fails.
* **Error precedence** in `functor/3`, `length/2`, `compare/3` and `arg/3`: for example, `functor(T, f(x), -1)` raises `type_error(atomic, f(x))` before it looks at the arity.
* Bugs in Horn itself included `retract/1` generators that re-ran their side effects when the engine backtracked, error balls that weren't copied (so a catcher could bind variables inside the culprit), and dozens of missing or misordered ISO error checks.

The two remaining mismatches out of 300,000 are an SWI inconsistency. `X is [c]` evaluates to 99, but the same one-element list fails with `type_error([], [c])` when its tail was bound through a variable in certain clause contexts (for example after `length(A, 1)` on `[0|Y]`). In other contexts, such as after `append/3`, SWI accepts it. Horn always evaluates it.

Comparing the order of two *distinct unbound variables* depends on the implementation. For that reason the generator only lets ground terms reach `@<`, `compare/3` and `sort/2`.

## Performance and limits

`examples/bench.pl` (naive reverse) runs at about **550k LIPS** on this sandbox, against about 50M for SWI's WAM. That's acceptable for an interpreter that copies clause terms and keeps bindings in a persistent map. Ground subterms of clauses are shared instead of copied, and first-argument indexing avoids leaving choicepoints behind.

Not implemented: modules, strings as a separate type (`"..."` reads as code lists), attributed variables/CLP, streams beyond stdout, tabling, and garbage collection of bindings during very long deterministic runs. Writing cyclic terms (possible when the occurs check is off) loops.
