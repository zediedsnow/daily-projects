// Package encode turns classic combinatorial puzzles into CNF.
package encode

import (
	"fmt"
	"math/rand"
	"strings"

	"gosat/sat"
)

// ---------- Sudoku (any n = b*b grid) ----------

// Sudoku holds an encoded puzzle.
type Sudoku struct {
	B, N int
	CNF  *sat.CNF
}

func (s *Sudoku) v(r, c, d int) sat.Lit { return sat.MkLit((r*s.N+c)*s.N+d, false) }

// NewSudoku encodes a puzzle given as a string of N*N cells ('.' or '0' = empty,
// digits 1-9 then letters A.. for larger boxes). box is the box size (3 for 9x9).
func NewSudoku(puzzle string, box int) (*Sudoku, error) {
	n := box * box
	cells := []rune{}
	for _, ch := range puzzle {
		if ch == '.' || ch == '0' || ch == '_' || (ch >= '1' && ch <= '9') || (ch >= 'A' && ch <= 'Z') {
			cells = append(cells, ch)
		}
	}
	if len(cells) != n*n {
		return nil, fmt.Errorf("puzzle has %d cells, want %d", len(cells), n*n)
	}
	s := &Sudoku{B: box, N: n, CNF: &sat.CNF{NumVars: n * n * n}}
	f := s.CNF
	for r := 0; r < n; r++ {
		for c := 0; c < n; c++ {
			var cell, row, col, blk []sat.Lit
			for d := 0; d < n; d++ {
				cell = append(cell, s.v(r, c, d))
				// interpret (r,c) as (unit index, digit) for rows/cols/boxes
				row = append(row, s.v(r, d, c))
				col = append(col, s.v(d, r, c))
				br, bc := (r/box)*box+d/box, (r%box)*box+d%box
				blk = append(blk, s.v(br, bc, c))
			}
			f.ExactlyOne(cell) // each cell holds one digit
			f.ExactlyOne(row)  // row r contains digit c exactly once
			f.ExactlyOne(col)  // column r contains digit c exactly once
			f.ExactlyOne(blk)  // box r contains digit c exactly once
		}
	}
	for i, ch := range cells {
		d := digit(ch)
		if d > n {
			return nil, fmt.Errorf("digit %c out of range", ch)
		}
		if d > 0 {
			f.Add(s.v(i/n, i%n, d-1))
		}
	}
	return s, nil
}

func digit(ch rune) int {
	switch {
	case ch >= '1' && ch <= '9':
		return int(ch - '0')
	case ch >= 'A' && ch <= 'Z':
		return int(ch-'A') + 10
	}
	return 0
}

func sym(d int) string {
	if d < 10 {
		return fmt.Sprint(d)
	}
	return string(rune('A' + d - 10))
}

// Decode extracts the grid from a model.
func (s *Sudoku) Decode(m []bool) [][]int {
	g := make([][]int, s.N)
	for r := range g {
		g[r] = make([]int, s.N)
		for c := 0; c < s.N; c++ {
			for d := 0; d < s.N; d++ {
				if m[s.v(r, c, d).Var()] {
					g[r][c] = d + 1
				}
			}
		}
	}
	return g
}

// Format pretty-prints a grid with box separators.
func (s *Sudoku) Format(g [][]int) string {
	var b strings.Builder
	sep := strings.Repeat("-", 2*s.B+1)
	line := sep
	for i := 1; i < s.B; i++ {
		line += "+" + sep
	}
	for r, row := range g {
		if r > 0 && r%s.B == 0 {
			b.WriteString(line + "\n")
		}
		for c, d := range row {
			if c > 0 && c%s.B == 0 {
				b.WriteString(" |")
			}
			if d == 0 {
				b.WriteString(" .")
			} else {
				b.WriteString(" " + sym(d))
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

// Givens parses the clue grid for display.
func (s *Sudoku) Givens(puzzle string) [][]int {
	g := make([][]int, s.N)
	i := 0
	for r := range g {
		g[r] = make([]int, s.N)
	}
	for _, ch := range puzzle {
		if ch == '.' || ch == '0' || ch == '_' || digit(ch) > 0 {
			g[i/s.N][i%s.N] = digit(ch)
			i++
		}
	}
	return g
}

// ---------- N-Queens ----------

// Queens encodes the N-queens problem: q(r,c) is variable r*n+c.
func Queens(n int) *sat.CNF {
	f := &sat.CNF{NumVars: n * n}
	q := func(r, c int) sat.Lit { return sat.MkLit(r*n+c, false) }
	for r := 0; r < n; r++ {
		var row, col []sat.Lit
		for c := 0; c < n; c++ {
			row = append(row, q(r, c))
			col = append(col, q(c, r))
		}
		f.ExactlyOne(row)
		f.AtMostOne(col)
	}
	for k := -(n - 1); k <= n-1; k++ { // diagonals r-c=k and anti-diagonals r+c=k+n-1
		var d, a []sat.Lit
		for r := 0; r < n; r++ {
			if c := r - k; c >= 0 && c < n {
				d = append(d, q(r, c))
			}
			if c := k + n - 1 - r; c >= 0 && c < n {
				a = append(a, q(r, c))
			}
		}
		f.AtMostOne(d)
		f.AtMostOne(a)
	}
	return f
}

// FormatQueens draws a board from a model.
func FormatQueens(n int, m []bool) string {
	var b strings.Builder
	for r := 0; r < n; r++ {
		for c := 0; c < n; c++ {
			if m[r*n+c] {
				b.WriteString(" Q")
			} else {
				b.WriteString(" .")
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

// ---------- Pigeonhole ----------

// Pigeonhole encodes "n+1 pigeons fit in n holes" — always UNSAT, and
// provably exponential for any resolution-based solver (Haken, 1985).
func Pigeonhole(n int) *sat.CNF {
	f := &sat.CNF{NumVars: (n + 1) * n}
	p := func(i, h int) sat.Lit { return sat.MkLit(i*n+h, false) }
	for i := 0; i <= n; i++ {
		var c []sat.Lit
		for h := 0; h < n; h++ {
			c = append(c, p(i, h))
		}
		f.Add(c...)
	}
	for h := 0; h < n; h++ {
		var c []sat.Lit
		for i := 0; i <= n; i++ {
			c = append(c, p(i, h))
		}
		f.AtMostOne(c)
	}
	return f
}

// ---------- Random k-SAT ----------

// RandomKSAT generates m random k-clauses over n variables.
func RandomKSAT(n, m, k int, seed int64) *sat.CNF {
	rng := rand.New(rand.NewSource(seed))
	f := &sat.CNF{NumVars: n}
	for i := 0; i < m; i++ {
		vs := rng.Perm(n)[:k]
		c := make([]sat.Lit, k)
		for j, v := range vs {
			c[j] = sat.MkLit(v, rng.Intn(2) == 1)
		}
		f.Add(c...)
	}
	return f
}

// ---------- Graph coloring ----------

// Coloring encodes k-coloring of a graph with n vertices and the given edges.
func Coloring(n, k int, edges [][2]int) *sat.CNF {
	f := &sat.CNF{NumVars: n * k}
	x := func(v, c int) sat.Lit { return sat.MkLit(v*k+c, false) }
	for v := 0; v < n; v++ {
		var c []sat.Lit
		for col := 0; col < k; col++ {
			c = append(c, x(v, col))
		}
		f.ExactlyOne(c)
	}
	for _, e := range edges {
		for col := 0; col < k; col++ {
			f.Add(x(e[0], col).Not(), x(e[1], col).Not())
		}
	}
	// symmetry breaking: vertex 0 gets color 0
	f.Add(x(0, 0))
	return f
}

// Mycielski returns the Mycielski graph M_k (triangle-free, chromatic number k).
func Mycielski(k int) (int, [][2]int) {
	n, edges := 2, [][2]int{{0, 1}} // M_2 = K_2
	for i := 2; i < k; i++ {
		// vertices: 0..n-1 originals, n..2n-1 shadows, 2n apex
		var ne [][2]int
		for _, e := range edges {
			ne = append(ne, e, [2]int{e[0], n + e[1]}, [2]int{e[1], n + e[0]})
		}
		for u := 0; u < n; u++ {
			ne = append(ne, [2]int{n + u, 2 * n})
		}
		n, edges = 2*n+1, ne
	}
	return n, edges
}
