package sat

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// CNF is a plain clause list, convenient for encoders, verification and I/O.
type CNF struct {
	NumVars int
	Clauses [][]Lit
}

// NewVar allocates a fresh variable and returns its index.
func (f *CNF) NewVar() int { f.NumVars++; return f.NumVars - 1 }

// Add appends a clause.
func (f *CNF) Add(lits ...Lit) {
	for _, l := range lits {
		if l.Var() >= f.NumVars {
			f.NumVars = l.Var() + 1
		}
	}
	f.Clauses = append(f.Clauses, append([]Lit(nil), lits...))
}

// AtMostOne adds pairwise at-most-one constraints.
func (f *CNF) AtMostOne(lits []Lit) {
	for i := range lits {
		for j := i + 1; j < len(lits); j++ {
			f.Add(lits[i].Not(), lits[j].Not())
		}
	}
}

// ExactlyOne adds an at-least-one clause plus pairwise at-most-one.
func (f *CNF) ExactlyOne(lits []Lit) {
	f.Add(lits...)
	f.AtMostOne(lits)
}

// Solver builds a solver loaded with this formula.
func (f *CNF) Solver() *Solver {
	s := New(f.NumVars)
	for _, c := range f.Clauses {
		if !s.AddClause(c...) {
			break
		}
	}
	return s
}

// Check reports whether model satisfies every clause (an independent check of the solver).
func (f *CNF) Check(model []bool) error {
	for i, c := range f.Clauses {
		ok := false
		for _, l := range c {
			if model[l.Var()] != l.Neg() {
				ok = true
				break
			}
		}
		if !ok {
			return fmt.Errorf("clause %d %v is falsified", i+1, c)
		}
	}
	return nil
}

// ParseDimacs reads a CNF in DIMACS format.
func ParseDimacs(r io.Reader) (*CNF, error) {
	f := &CNF{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	var cur []Lit
	declared := -1
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == 'c' || line[0] == '%' {
			continue
		}
		if line[0] == 'p' {
			fs := strings.Fields(line)
			if len(fs) != 4 || fs[1] != "cnf" {
				return nil, fmt.Errorf("bad header %q", line)
			}
			n, err := strconv.Atoi(fs[2])
			if err != nil {
				return nil, err
			}
			declared = n
			if n > f.NumVars {
				f.NumVars = n
			}
			continue
		}
		for _, tok := range strings.Fields(line) {
			d, err := strconv.Atoi(tok)
			if err != nil {
				return nil, fmt.Errorf("bad literal %q", tok)
			}
			if d == 0 {
				f.Add(cur...)
				cur = cur[:0]
			} else {
				cur = append(cur, FromDimacs(d))
			}
		}
	}
	if len(cur) > 0 {
		f.Add(cur...)
	}
	if declared < 0 && len(f.Clauses) == 0 {
		return nil, fmt.Errorf("no clauses found")
	}
	return f, sc.Err()
}

// WriteDimacs writes the formula in DIMACS format.
func (f *CNF) WriteDimacs(w io.Writer) error {
	bw := bufio.NewWriter(w)
	fmt.Fprintf(bw, "p cnf %d %d\n", f.NumVars, len(f.Clauses))
	for _, c := range f.Clauses {
		for _, l := range c {
			bw.WriteString(strconv.Itoa(l.Dimacs()))
			bw.WriteByte(' ')
		}
		bw.WriteString("0\n")
	}
	return bw.Flush()
}
