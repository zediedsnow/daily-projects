package encode

import (
	"testing"

	"gosat/sat"
)

func countModels(f *sat.CNF) int {
	s := f.Solver()
	n := 0
	for s.Solve() == sat.Sat {
		n++
		var block []sat.Lit
		for v, val := range s.Model() {
			block = append(block, sat.MkLit(v, val))
		}
		s.AddClause(block...)
	}
	return n
}

// Known N-queens solution counts (OEIS A000170).
func TestQueensCounts(t *testing.T) {
	want := []int{1, 0, 0, 2, 10, 4, 40, 92, 352}
	for i, w := range want {
		if got := countModels(Queens(i + 1)); got != w {
			t.Errorf("%d-queens: %d solutions, want %d", i+1, got, w)
		}
	}
}

func TestSudokuSolvesAndRespectsClues(t *testing.T) {
	p := "53..7....6..195....98....6.8...6...34..8.3..17...2...6.6....28....419..5....8..79"
	sd, err := NewSudoku(p, 3)
	if err != nil {
		t.Fatal(err)
	}
	s := sd.CNF.Solver()
	if s.Solve() != sat.Sat {
		t.Fatal("expected SAT")
	}
	g, giv := sd.Decode(s.Model()), sd.Givens(p)
	for r := 0; r < 9; r++ {
		seenR, seenC := map[int]bool{}, map[int]bool{}
		for c := 0; c < 9; c++ {
			if giv[r][c] != 0 && giv[r][c] != g[r][c] {
				t.Fatalf("clue changed at %d,%d", r, c)
			}
			seenR[g[r][c]], seenC[g[c][r]] = true, true
		}
		if len(seenR) != 9 || len(seenC) != 9 {
			t.Fatalf("row/col %d not a permutation", r)
		}
	}
	if countModels(sd.CNF) != 1 {
		t.Fatal("classic puzzle should have a unique solution")
	}
}

func TestPigeonholeUnsat(t *testing.T) {
	for n := 1; n <= 6; n++ {
		if Pigeonhole(n).Solver().Solve() != sat.Unsat {
			t.Fatalf("PHP(%d) should be UNSAT", n)
		}
	}
}

func TestMycielskiChromatic(t *testing.T) {
	for k := 3; k <= 5; k++ {
		n, e := Mycielski(k)
		if Coloring(n, k-1, e).Solver().Solve() != sat.Unsat || Coloring(n, k, e).Solver().Solve() != sat.Sat {
			t.Fatalf("M_%d should have chromatic number %d", k, k)
		}
	}
}
