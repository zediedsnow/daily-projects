# gosat — a CDCL SAT solver from scratch in Go

`gosat` decides whether a Boolean formula in conjunctive normal form can be made true —
the canonical NP-complete problem — using the same core algorithm as industrial solvers
like MiniSat and Glucose: **conflict-driven clause learning**. It reads standard DIMACS
files, speaks the SAT-competition output format, and ships with encoders that turn
Sudoku, N-queens, graph coloring, the pigeonhole principle and random 3-SAT into CNF.

Zero dependencies, ~1,000 lines of Go in the solver + encoders, standard library only.

## Why it's interesting

A naive backtracking search on a 25×25 Sudoku (15,625 variables, 752,500 clauses) or 100
queens (1.6 million clauses) would never finish. CDCL does it in a fraction of a second because
every time it hits a dead end it *learns a new clause* explaining why, then jumps back
past every decision that was irrelevant to the failure. The same engine powers hardware
verification, package managers' dependency resolvers, and program analysers.

It also shows the limits: the pigeonhole principle ("n+1 pigeons don't fit in n holes") is
obvious to a human but provably needs exponentially long resolution proofs (Haken, 1985) —
and you can watch the conflict count multiply by ~5× per extra hole in the benchmark below.

## Build & run

Requires Go 1.21+.

```sh
go build -o gosat .
go test ./...                     # 4,000 random formulas cross-checked against brute force, model enumeration, known puzzle counts

./gosat sudoku                    # Arto Inkala's "world's hardest sudoku" + uniqueness proof
./gosat sudoku "$(printf '.%.0s' {1..256})" 4   # fill a blank 16x16 grid
./gosat queens 8 --count          # enumerate all 92 solutions incrementally
./gosat queens 100                # one placement of 100 queens
./gosat color 5                   # Mycielski graph M5: prove 4 colors impossible, find a 5-coloring
./gosat php 8                     # 9 pigeons, 8 holes → UNSAT
./gosat random 200 4.26 2         # random 3-SAT at the phase transition
./gosat solve examples/tiny.cnf   # any DIMACS file (or stdin); exit code 10 = SAT, 20 = UNSAT
./gosat gen queens 12 > q12.cnf   # export any encoding as DIMACS for other solvers
./gosat bench                     # the suite below
```

## Sample output

```
$ ./gosat sudoku
puzzle (729 vars, 12009 clauses):
 8 . . | . . . | . . .
 . . 3 | 6 . . | . . .
 . 7 . | . 9 . | 2 . .
-------+-------+-------
 . 5 . | . . 7 | . . .
 . . . | . 4 5 | 7 . .
 . . . | 1 . . | . 3 .
-------+-------+-------
 . . 1 | . . . | . 6 8
 . . 8 | 5 . . | . 1 .
 . 9 . | . . . | 4 . .

solution:
 8 1 2 | 7 5 3 | 6 4 9
 9 4 3 | 6 8 2 | 1 7 5
 6 7 5 | 4 9 1 | 2 8 3
-------+-------+-------
 1 5 4 | 2 3 7 | 8 9 6
 3 6 9 | 8 4 5 | 7 2 1
 2 8 7 | 1 6 9 | 5 3 4
-------+-------+-------
 5 2 1 | 9 7 4 | 3 6 8
 4 3 8 | 5 2 6 | 9 1 7
 7 9 6 | 3 1 8 | 4 5 2

unique solution: true
4.962ms  conflicts=57 decisions=79 props=4754 restarts=0 learnt=53 deleted=0 avg-learnt-len=6.3 minimized-lits=82
```

```
$ ./gosat queens 8 --count
 . . . . Q . . .
 . Q . . . . . .
 . . . Q . . . .
 . . . . . . Q .
 . . Q . . . . .
 . . . . . . . Q
 . . . . . Q . .
 Q . . . . . . .
8-queens has 92 solutions (found by incremental solving with blocking clauses)
5.726ms  conflicts=889 decisions=2027 props=20337 restarts=0 learnt=883 deleted=0 avg-learnt-len=12.2 minimized-lits=4933
```

```
$ ./gosat solve examples/tiny.cnf
c gosat: 3 variables, 3 clauses
c 12µs  conflicts=0 decisions=2 props=3 restarts=0 learnt=0 deleted=0 avg-learnt-len=0.0 minimized-lits=0
s SATISFIABLE
v -1 -2 -3 0
```

### Benchmark (`./gosat bench`, single core)

```
instance                                vars  clauses  result          conflicts        time
--------------------------------------------------------------------------------------------
sudoku 9x9 (Inkala, hardest)             729    12009  SATISFIABLE            18     2.314ms
sudoku 16x16 (blank grid)               4096   123904  SATISFIABLE             0    30.713ms
sudoku 25x25 (blank grid)              15625   752500  SATISFIABLE           257   224.892ms
8-queens                                  64      736  SATISFIABLE            16       226µs
50-queens                               2500   203400  SATISFIABLE           104    91.625ms
100-queens                             10000  1646800  SATISFIABLE           419   495.724ms
random 3-SAT n=100 m=426 seed=1          100      426  SATISFIABLE           224     1.634ms
random 3-SAT n=100 m=426 seed=2          100      426  UNSATISFIABLE         407     2.695ms
random 3-SAT n=100 m=426 seed=3          100      426  UNSATISFIABLE         260     1.818ms
random 3-SAT n=200 m=852 seed=1          200      852  UNSATISFIABLE       25512   338.845ms
random 3-SAT n=200 m=852 seed=2          200      852  SATISFIABLE         42440    663.05ms
random 3-SAT n=200 m=852 seed=3          200      852  SATISFIABLE          9367   101.024ms
Mycielski M_5 4-coloring                  92      446  UNSATISFIABLE         427     1.747ms
pigeonhole 7→6                            42      133  UNSATISFIABLE         788     3.943ms
pigeonhole 8→7                            56      204  UNSATISFIABLE        5013     54.38ms
pigeonhole 9→8                            72      297  UNSATISFIABLE       21972   344.339ms
pigeonhole 10→9                           90      415  UNSATISFIABLE      130140   6.021298s
--------------------------------------------------------------------------------------------
total 8.38s — every SAT model was independently re-checked against the clauses
```

## How it works

**Representation.** Variable *v* becomes literals `2v` (positive) and `2v+1` (negated), so
negation is `l ^ 1` and literals index arrays directly.

**Unit propagation — two watched literals** (`sat/solver.go: propagate`). Each clause watches
two of its literals; a clause can only become unit or conflicting when a watched literal turns
false, so assigning a variable only touches the clauses watching its negation. Nothing has
to be undone on backtrack. Each watcher also caches a *blocker* literal: if that is already
true the clause is skipped without being dereferenced.

**Conflict analysis — first UIP** (`analyze`). On conflict the solver walks the implication
trail backwards, resolving the conflicting clause with the reasons of current-level literals
until exactly one current-level literal remains (the *first unique implication point*). The
result is a new clause that is implied by the formula and *asserting*: after backtracking it
immediately forces a new value.

**Clause minimisation** (`litRedundant`). Literals whose negation is already implied by other
literals of the learnt clause are removed by a recursive search over reason clauses, pruned with
a 32-bit "abstract level" signature. On the 8-queens enumeration this deletes ~5,000 literals.

**Non-chronological backjumping.** The solver jumps straight to the second-highest decision level
in the learnt clause, discarding every intermediate decision that played no part in the conflict.

**VSIDS + phase saving** (`sat/heap.go`). Every variable in a conflict gets its activity bumped by an
increment that grows by 1/0.95 each conflict, so recent conflicts dominate; the next decision is the
most active unassigned variable from a binary max-heap. When a variable is unassigned its last
polarity is remembered and reused, which keeps partial solutions intact across restarts.

**Luby restarts.** The search restarts after 100 × (1,1,2,1,1,2,4,1,…) conflicts, keeping all learnt
clauses and activities — this escapes heavy-tailed bad branches.

**Learnt clause database reduction.** Each learnt clause records its LBD ("glue": number of distinct
decision levels among its literals, from Glucose). When the database grows too large, the worse
half — high LBD, low activity — is deleted, except clauses with LBD ≤ 2 and clauses currently serving as
a reason. Watchers of deleted clauses are dropped lazily during propagation.

**Incremental solving.** Clauses can be added between `Solve()` calls; that's how `queens --count`
enumerates all solutions and how `sudoku` proves uniqueness (block the found solution, solve again,
get UNSAT).

**Trust but verify.** Every SAT answer is re-checked against the original clause list by an
independent checker before it is printed, and the test suite compares the solver against exhaustive
search on 4,000 random formulas and checks model counts against brute force and OEIS A000170.

## Layout

```
sat/solver.go     CDCL core: propagation, analysis, minimisation, restarts, DB reduction
sat/heap.go       indexed binary heap for VSIDS
sat/dimacs.go     CNF type, DIMACS reader/writer, model checker, cardinality helpers
encode/encode.go  Sudoku (any box size), N-queens, pigeonhole, random k-SAT, Mycielski coloring
main.go           CLI
examples/         small DIMACS files
```
