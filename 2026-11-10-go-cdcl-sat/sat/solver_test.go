package sat

import (
	"math/rand"
	"strings"
	"testing"
)

func bruteForce(f *CNF) bool {
	m := make([]bool, f.NumVars)
	for x := 0; x < 1<<f.NumVars; x++ {
		for v := range m {
			m[v] = x>>v&1 == 1
		}
		if f.Check(m) == nil {
			return true
		}
	}
	return false
}

func randomCNF(rng *rand.Rand, n, m int) *CNF {
	f := &CNF{NumVars: n}
	for i := 0; i < m; i++ {
		k := 1 + rng.Intn(4)
		c := make([]Lit, k)
		for j := range c {
			c[j] = MkLit(rng.Intn(n), rng.Intn(2) == 0)
		}
		f.Add(c...)
	}
	return f
}

// TestAgainstBruteForce cross-checks thousands of small random formulas
// around the satisfiability threshold against exhaustive search.
func TestAgainstBruteForce(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	var sats, unsats int
	for iter := 0; iter < 4000; iter++ {
		n := 3 + rng.Intn(12)
		f := randomCNF(rng, n, n+rng.Intn(n*3))
		want := bruteForce(f)
		s := f.Solver()
		got := s.Solve()
		if (got == Sat) != want {
			t.Fatalf("iter %d: solver says %v, brute force says sat=%v", iter, got, want)
		}
		if got == Sat {
			sats++
			if err := f.Check(s.Model()); err != nil {
				t.Fatalf("iter %d: bad model: %v", iter, err)
			}
		} else {
			unsats++
		}
	}
	t.Logf("%d SAT, %d UNSAT instances verified", sats, unsats)
}

// TestIncrementalEnumeration counts all models via blocking clauses.
func TestIncrementalEnumeration(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for iter := 0; iter < 300; iter++ {
		n := 3 + rng.Intn(7)
		f := randomCNF(rng, n, n+rng.Intn(2*n))
		want := 0
		m := make([]bool, n)
		for x := 0; x < 1<<n; x++ {
			for v := range m {
				m[v] = x>>v&1 == 1
			}
			if f.Check(m) == nil {
				want++
			}
		}
		s := f.Solver()
		got := 0
		for s.Solve() == Sat {
			got++
			block := make([]Lit, n)
			for v := 0; v < n; v++ {
				block[v] = MkLit(v, s.Model()[v])
			}
			s.AddClause(block...)
		}
		if got != want {
			t.Fatalf("iter %d: enumerated %d models, want %d", iter, got, want)
		}
	}
}

func TestDimacsRoundTrip(t *testing.T) {
	src := "c example\np cnf 3 2\n1 -3 0\n2 3 -1 0\n"
	f, err := ParseDimacs(strings.NewReader(src))
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	f.WriteDimacs(&b)
	if b.String() != "p cnf 3 2\n1 -3 0\n2 3 -1 0\n" {
		t.Fatalf("round trip gave %q", b.String())
	}
}

func TestLuby(t *testing.T) {
	want := []uint64{1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8}
	for i, w := range want {
		if g := luby(uint64(i)); g != w {
			t.Fatalf("luby(%d)=%d want %d", i, g, w)
		}
	}
}

func BenchmarkRandom3SAT(b *testing.B) {
	for i := 0; i < b.N; i++ {
		rng := rand.New(rand.NewSource(int64(i)))
		f := &CNF{NumVars: 150}
		for j := 0; j < 639; j++ {
			f.Add(MkLit(rng.Intn(150), rng.Intn(2) == 0), MkLit(rng.Intn(150), rng.Intn(2) == 0), MkLit(rng.Intn(150), rng.Intn(2) == 0))
		}
		f.Solver().Solve()
	}
}
