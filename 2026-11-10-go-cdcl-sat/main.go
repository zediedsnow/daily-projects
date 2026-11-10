// gosat: a CDCL SAT solver with puzzle front-ends.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"gosat/encode"
	"gosat/sat"
)

const usage = `gosat — a CDCL SAT solver written from scratch in Go

usage:
  gosat solve [file.cnf]          solve a DIMACS CNF (stdin if no file); SAT-competition output
  gosat sudoku [puzzle] [box]     solve a sudoku (81 chars, '.' = blank; box=4 for 16x16)
  gosat queens N [--count]        place N queens; --count enumerates every solution
  gosat color K                   k-color the Mycielski graph M_K with K-1 and K colors
  gosat php N                     pigeonhole: N+1 pigeons, N holes (UNSAT, exponential)
  gosat random N [ratio] [seed]   random 3-SAT with N vars at clause/var ratio (default 4.26)
  gosat gen <kind> args... > f    write any of the above as DIMACS instead of solving
  gosat bench                     run the built-in benchmark suite
`

// The "World's hardest sudoku" by Arto Inkala (2012).
const inkala = "8..........36......7..9.2...5...7.......457.....1...3...1....68..85...1..9....4.."

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "solve":
		os.Exit(cmdSolve(args))
	case "sudoku":
		cmdSudoku(args)
	case "queens":
		cmdQueens(args)
	case "color":
		cmdColor(args)
	case "php":
		n := atoi(args, 0, 8)
		report(fmt.Sprintf("pigeonhole %d→%d", n+1, n), encode.Pigeonhole(n))
	case "random":
		n := atoi(args, 0, 200)
		ratio := 4.26
		if len(args) > 1 {
			ratio, _ = strconv.ParseFloat(args[1], 64)
		}
		seed := int64(atoi(args, 2, 1))
		report(fmt.Sprintf("random 3-SAT n=%d ratio=%.2f seed=%d", n, ratio, seed),
			encode.RandomKSAT(n, int(float64(n)*ratio+0.5), 3, seed))
	case "gen":
		cmdGen(args)
	case "bench":
		cmdBench()
	default:
		fmt.Print(usage)
		os.Exit(2)
	}
}

func atoi(args []string, i, def int) int {
	if i < len(args) {
		if n, err := strconv.Atoi(args[i]); err == nil {
			return n
		}
	}
	return def
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

func run(f *sat.CNF) (*sat.Solver, sat.Status, time.Duration) {
	t := time.Now()
	s := f.Solver()
	st := s.Solve()
	el := time.Since(t)
	if st == sat.Sat {
		if err := f.Check(s.Model()); err != nil {
			fail(fmt.Errorf("internal error, model check failed: %v", err))
		}
	}
	return s, st, el
}

func stats(s *sat.Solver, d time.Duration) string {
	st := s.Stats
	avg := 0.0
	if st.Conflicts > 0 {
		avg = float64(st.LearntLits) / float64(st.Conflicts)
	}
	return fmt.Sprintf("%v  conflicts=%d decisions=%d props=%d restarts=%d learnt=%d deleted=%d avg-learnt-len=%.1f minimized-lits=%d",
		d.Round(time.Microsecond), st.Conflicts, st.Decisions, st.Propagations, st.Restarts, st.Learnt, st.Deleted, avg, st.MinimizedLits)
}

func report(name string, f *sat.CNF) {
	fmt.Printf("%s: %d vars, %d clauses\n", name, f.NumVars, len(f.Clauses))
	s, st, d := run(f)
	fmt.Printf("  %s (model verified: %v)\n  %s\n", st, st == sat.Sat, stats(s, d))
}

func cmdSolve(args []string) int {
	in := os.Stdin
	if len(args) > 0 {
		var err error
		if in, err = os.Open(args[0]); err != nil {
			fail(err)
		}
		defer in.Close()
	}
	f, err := sat.ParseDimacs(in)
	if err != nil {
		fail(err)
	}
	fmt.Printf("c gosat: %d variables, %d clauses\n", f.NumVars, len(f.Clauses))
	s, st, d := run(f)
	fmt.Printf("c %s\n", stats(s, d))
	fmt.Printf("s %s\n", st)
	if st == sat.Sat {
		var b strings.Builder
		b.WriteString("v")
		for v, val := range s.Model() {
			l := v + 1
			if !val {
				l = -l
			}
			b.WriteString(" " + strconv.Itoa(l))
			if b.Len() > 72 {
				fmt.Println(b.String())
				b.Reset()
				b.WriteString("v")
			}
		}
		fmt.Println(b.String() + " 0")
		return 10
	}
	if st == sat.Unsat {
		return 20
	}
	return 0
}

func cmdSudoku(args []string) {
	p, box := inkala, 3
	if len(args) > 0 {
		p = args[0]
	}
	box = atoi(args, 1, 3)
	sd, err := encode.NewSudoku(p, box)
	if err != nil {
		fail(err)
	}
	fmt.Printf("puzzle (%d vars, %d clauses):\n%s\n", sd.CNF.NumVars, len(sd.CNF.Clauses), sd.Format(sd.Givens(p)))
	s, st, d := run(sd.CNF)
	if st != sat.Sat {
		fmt.Println("no solution:", st)
		return
	}
	fmt.Printf("solution:\n%s\n", sd.Format(sd.Decode(s.Model())))
	// uniqueness: forbid this solution and ask again
	var block []sat.Lit
	for v, val := range s.Model() {
		if val {
			block = append(block, sat.MkLit(v, true))
		}
	}
	s.AddClause(block...)
	unique := s.Solve() == sat.Unsat
	fmt.Printf("unique solution: %v\n%s\n", unique, stats(s, d))
}

func cmdQueens(args []string) {
	n := atoi(args, 0, 8)
	count := len(args) > 1 && args[1] == "--count"
	f := encode.Queens(n)
	if !count {
		s, st, d := run(f)
		fmt.Printf("%d-queens: %d vars, %d clauses → %s\n", n, f.NumVars, len(f.Clauses), st)
		if st == sat.Sat {
			fmt.Print(encode.FormatQueens(n, s.Model()))
		}
		fmt.Println(stats(s, d))
		return
	}
	t := time.Now()
	s := f.Solver()
	sols := 0
	for s.Solve() == sat.Sat {
		sols++
		if sols == 1 {
			fmt.Print(encode.FormatQueens(n, s.Model()))
		}
		var block []sat.Lit // the queens of this placement cannot all appear again
		for v, val := range s.Model() {
			if val {
				block = append(block, sat.MkLit(v, true))
			}
		}
		s.AddClause(block...)
	}
	fmt.Printf("%d-queens has %d solutions (found by incremental solving with blocking clauses)\n%s\n",
		n, sols, stats(s, time.Since(t)))
}

func cmdColor(args []string) {
	k := atoi(args, 0, 5)
	n, edges := encode.Mycielski(k)
	fmt.Printf("Mycielski graph M_%d: %d vertices, %d edges, triangle-free, chromatic number %d\n", k, n, len(edges), k)
	for _, c := range []int{k - 1, k} {
		f := encode.Coloring(n, c, edges)
		s, st, d := run(f)
		fmt.Printf("  %d colors: %s\n    %s\n", c, st, stats(s, d))
	}
}

func cmdGen(args []string) {
	if len(args) == 0 {
		fail(fmt.Errorf("gen needs a kind: sudoku|queens|php|random|color"))
	}
	var f *sat.CNF
	rest := args[1:]
	switch args[0] {
	case "sudoku":
		p := inkala
		if len(rest) > 0 {
			p = rest[0]
		}
		sd, err := encode.NewSudoku(p, atoi(rest, 1, 3))
		if err != nil {
			fail(err)
		}
		f = sd.CNF
	case "queens":
		f = encode.Queens(atoi(rest, 0, 8))
	case "php":
		f = encode.Pigeonhole(atoi(rest, 0, 8))
	case "random":
		n := atoi(rest, 0, 200)
		f = encode.RandomKSAT(n, n*426/100, 3, int64(atoi(rest, 1, 1)))
	case "color":
		k := atoi(rest, 0, 5)
		n, e := encode.Mycielski(k)
		f = encode.Coloring(n, atoi(rest, 1, k-1), e)
	default:
		fail(fmt.Errorf("unknown kind %q", args[0]))
	}
	f.WriteDimacs(os.Stdout)
}

func cmdBench() {
	type job struct {
		name string
		f    *sat.CNF
	}
	var jobs []job
	sd, _ := encode.NewSudoku(inkala, 3)
	jobs = append(jobs, job{"sudoku 9x9 (Inkala, hardest)", sd.CNF})
	empty16 := strings.Repeat(".", 256)
	sd16, _ := encode.NewSudoku(empty16, 4)
	jobs = append(jobs, job{"sudoku 16x16 (blank grid)", sd16.CNF})
	sd25, _ := encode.NewSudoku(strings.Repeat(".", 625), 5)
	jobs = append(jobs, job{"sudoku 25x25 (blank grid)", sd25.CNF})
	for _, n := range []int{8, 50, 100} {
		jobs = append(jobs, job{fmt.Sprintf("%d-queens", n), encode.Queens(n)})
	}
	for _, n := range []int{100, 200} {
		for seed := int64(1); seed <= 3; seed++ {
			jobs = append(jobs, job{fmt.Sprintf("random 3-SAT n=%d m=%d seed=%d", n, n*426/100, seed),
				encode.RandomKSAT(n, n*426/100, 3, seed)})
		}
	}
	for _, k := range []int{5} {
		n, e := encode.Mycielski(k)
		jobs = append(jobs, job{fmt.Sprintf("Mycielski M_%d %d-coloring", k, k-1), encode.Coloring(n, k-1, e)})
	}
	for _, n := range []int{6, 7, 8, 9} {
		jobs = append(jobs, job{fmt.Sprintf("pigeonhole %d→%d", n+1, n), encode.Pigeonhole(n)})
	}
	fmt.Printf("%-36s %7s %8s  %-14s %10s %11s\n", "instance", "vars", "clauses", "result", "conflicts", "time")
	fmt.Println(strings.Repeat("-", 92))
	total := time.Duration(0)
	for _, j := range jobs {
		s, st, d := run(j.f)
		total += d
		fmt.Printf("%-36s %7d %8d  %-14s %10d %11v\n", j.name, j.f.NumVars, len(j.f.Clauses), st, s.Stats.Conflicts, d.Round(time.Microsecond))
	}
	fmt.Println(strings.Repeat("-", 92))
	fmt.Printf("total %v — every SAT model was independently re-checked against the clauses\n", total.Round(time.Millisecond))
}
