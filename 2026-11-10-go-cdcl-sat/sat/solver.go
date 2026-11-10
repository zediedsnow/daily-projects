// Package sat implements a CDCL (conflict-driven clause learning) SAT solver.
//
// Techniques: two-watched-literal propagation with blocker literals, VSIDS
// branching on a binary heap, phase saving, first-UIP conflict analysis with
// recursive clause minimization, non-chronological backjumping, Luby restarts
// and LBD-based ("glue") learnt clause database reduction.
package sat

import (
	"fmt"
	"sort"
)

// Lit is a literal: variable v (0-based) is encoded as 2v (positive) or 2v+1 (negative).
type Lit int32

// MkLit builds a literal from a 0-based variable and a sign (true = negated).
func MkLit(v int, neg bool) Lit {
	if neg {
		return Lit(2*v + 1)
	}
	return Lit(2 * v)
}

// FromDimacs converts a DIMACS literal (±1-based) into a Lit.
func FromDimacs(d int) Lit {
	if d < 0 {
		return MkLit(-d-1, true)
	}
	return MkLit(d-1, false)
}

func (l Lit) Var() int  { return int(l >> 1) }
func (l Lit) Neg() bool { return l&1 == 1 }
func (l Lit) Not() Lit  { return l ^ 1 }
func (l Lit) Dimacs() int {
	if l.Neg() {
		return -(l.Var() + 1)
	}
	return l.Var() + 1
}
func (l Lit) String() string { return fmt.Sprint(l.Dimacs()) }

type lbool int8

const (
	lUndef lbool = 0
	lTrue  lbool = 1
	lFalse lbool = -1
)

// Status is the outcome of Solve.
type Status int

const (
	Unknown Status = iota
	Sat
	Unsat
)

func (s Status) String() string {
	return [...]string{"UNKNOWN", "SATISFIABLE", "UNSATISFIABLE"}[s]
}

type clause struct {
	lits    []Lit
	act     float64
	lbd     int
	learnt  bool
	deleted bool
}

type watcher struct {
	c       *clause
	blocker Lit // some other literal of c; if it is true, c is satisfied and can be skipped
}

// Stats are counters gathered during search.
type Stats struct {
	Decisions, Propagations, Conflicts, Restarts uint64
	Learnt, Deleted, MinimizedLits, LearntLits   uint64
}

// Solver is a CDCL SAT solver. Create one with New, add clauses, call Solve.
type Solver struct {
	nVars   int
	clauses []*clause
	learnts []*clause
	watches [][]watcher // indexed by Lit: clauses watching that literal

	assigns  []lbool
	level    []int
	reason   []*clause
	polarity []bool // saved phase (true = negative)
	trail    []Lit
	trailLim []int
	qhead    int

	activity []float64
	varInc   float64
	claInc   float64
	heap     varHeap

	seen     []bool
	toClear  []Lit
	stack    []Lit
	lbdSeen  []uint64
	lbdStamp uint64

	ok        bool
	model     []bool
	maxLearnt float64
	Stats     Stats
	// ConflictLimit aborts Solve with Unknown after this many conflicts (0 = no limit).
	ConflictLimit uint64
}

// New creates a solver with n variables.
func New(n int) *Solver {
	s := &Solver{varInc: 1, claInc: 1, ok: true}
	s.heap.act = &s.activity
	s.EnsureVars(n)
	return s
}

// EnsureVars grows the solver to at least n variables.
func (s *Solver) EnsureVars(n int) {
	for s.nVars < n {
		v := s.nVars
		s.nVars++
		s.watches = append(s.watches, nil, nil)
		s.assigns = append(s.assigns, lUndef)
		s.level = append(s.level, 0)
		s.reason = append(s.reason, nil)
		s.polarity = append(s.polarity, true)
		s.activity = append(s.activity, 0)
		s.seen = append(s.seen, false)
		s.heap.insert(v)
	}
}

func (s *Solver) NumVars() int    { return s.nVars }
func (s *Solver) NumClauses() int { return len(s.clauses) }

func (s *Solver) value(l Lit) lbool {
	v := s.assigns[l>>1]
	if l&1 == 1 {
		return -v
	}
	return v
}

func (s *Solver) decisionLevel() int { return len(s.trailLim) }

// AddClause adds a clause (at decision level 0). It returns false if the
// formula has become trivially unsatisfiable.
func (s *Solver) AddClause(lits ...Lit) bool {
	if !s.ok {
		return false
	}
	s.cancelUntil(0)
	for _, l := range lits {
		s.EnsureVars(l.Var() + 1)
	}
	// Normalise: sort, drop duplicates and level-0 false literals, detect tautologies / satisfied.
	ls := append([]Lit(nil), lits...)
	sort.Slice(ls, func(i, j int) bool { return ls[i] < ls[j] })
	out := ls[:0]
	var prev Lit = -1
	for _, l := range ls {
		if s.value(l) == lTrue || l == prev.Not() {
			return true
		}
		if s.value(l) == lFalse || l == prev {
			continue
		}
		out = append(out, l)
		prev = l
	}
	switch len(out) {
	case 0:
		s.ok = false
		return false
	case 1:
		s.enqueue(out[0], nil)
		if s.propagate() != nil {
			s.ok = false
		}
		return s.ok
	}
	c := &clause{lits: out}
	s.clauses = append(s.clauses, c)
	s.attach(c)
	return true
}

func (s *Solver) attach(c *clause) {
	s.watches[c.lits[0]] = append(s.watches[c.lits[0]], watcher{c, c.lits[1]})
	s.watches[c.lits[1]] = append(s.watches[c.lits[1]], watcher{c, c.lits[0]})
}

func (s *Solver) enqueue(l Lit, from *clause) {
	v := l.Var()
	if l.Neg() {
		s.assigns[v] = lFalse
	} else {
		s.assigns[v] = lTrue
	}
	s.level[v] = s.decisionLevel()
	s.reason[v] = from
	s.trail = append(s.trail, l)
}

// propagate performs unit propagation over the two-watched-literal scheme.
// It returns a conflicting clause, or nil.
func (s *Solver) propagate() *clause {
	for s.qhead < len(s.trail) {
		p := s.trail[s.qhead]
		s.qhead++
		s.Stats.Propagations++
		falseLit := p.Not()
		ws := s.watches[falseLit]
		i, j := 0, 0
		for i < len(ws) {
			w := ws[i]
			i++
			c := w.c
			if c.deleted {
				continue // lazily drop watchers of removed clauses
			}
			if s.value(w.blocker) == lTrue {
				ws[j] = w
				j++
				continue
			}
			if c.lits[0] == falseLit {
				c.lits[0], c.lits[1] = c.lits[1], c.lits[0]
			}
			first := c.lits[0]
			if first != w.blocker && s.value(first) == lTrue {
				ws[j] = watcher{c, first}
				j++
				continue
			}
			// Look for a new literal to watch.
			moved := false
			for k := 2; k < len(c.lits); k++ {
				if s.value(c.lits[k]) != lFalse {
					c.lits[1], c.lits[k] = c.lits[k], c.lits[1]
					s.watches[c.lits[1]] = append(s.watches[c.lits[1]], watcher{c, first})
					moved = true
					break
				}
			}
			if moved {
				continue
			}
			ws[j] = watcher{c, first}
			j++
			if s.value(first) == lFalse { // conflict
				j += copy(ws[j:], ws[i:])
				s.watches[falseLit] = ws[:j]
				s.qhead = len(s.trail)
				return c
			}
			s.enqueue(first, c) // unit
		}
		s.watches[falseLit] = ws[:j]
	}
	return nil
}

func (s *Solver) bumpVar(v int) {
	s.activity[v] += s.varInc
	if s.activity[v] > 1e100 {
		for i := range s.activity {
			s.activity[i] *= 1e-100
		}
		s.varInc *= 1e-100
	}
	if s.heap.contains(v) {
		s.heap.up(s.heap.idx[v])
	}
}

func (s *Solver) bumpClause(c *clause) {
	c.act += s.claInc
	if c.act > 1e20 {
		for _, l := range s.learnts {
			l.act *= 1e-20
		}
		s.claInc *= 1e-20
	}
}

func (s *Solver) abstractLevel(v int) uint32 { return 1 << (uint(s.level[v]) & 31) }

// analyze derives a first-UIP learnt clause from a conflict and returns it
// together with the level to backjump to. learnt[0] is the asserting literal.
func (s *Solver) analyze(confl *clause) ([]Lit, int) {
	learnt := []Lit{0}
	pathC := 0
	var p Lit = -1
	idx := len(s.trail) - 1
	c := confl
	for {
		if c.learnt {
			s.bumpClause(c)
		}
		start := 0
		if p != -1 {
			start = 1 // c.lits[0] == p for reason clauses
		}
		for _, q := range c.lits[start:] {
			v := q.Var()
			if !s.seen[v] && s.level[v] > 0 {
				s.bumpVar(v)
				s.seen[v] = true
				if s.level[v] >= s.decisionLevel() {
					pathC++
				} else {
					learnt = append(learnt, q)
				}
			}
		}
		for !s.seen[s.trail[idx].Var()] {
			idx--
		}
		p = s.trail[idx]
		idx--
		c = s.reason[p.Var()]
		s.seen[p.Var()] = false
		pathC--
		if pathC <= 0 {
			break
		}
	}
	learnt[0] = p.Not()

	// Recursive minimisation: drop literals implied by the rest of the clause.
	s.toClear = append(s.toClear[:0], learnt...)
	var abs uint32
	for _, l := range learnt[1:] {
		abs |= s.abstractLevel(l.Var())
	}
	before := len(learnt)
	j := 1
	for i := 1; i < len(learnt); i++ {
		l := learnt[i]
		if s.reason[l.Var()] == nil || !s.litRedundant(l, abs) {
			learnt[j] = l
			j++
		}
	}
	learnt = learnt[:j]
	s.Stats.MinimizedLits += uint64(before - len(learnt))
	for _, l := range s.toClear {
		s.seen[l.Var()] = false
	}

	// Find backjump level; put that literal at index 1 so it gets watched.
	bt := 0
	if len(learnt) > 1 {
		maxI := 1
		for i := 2; i < len(learnt); i++ {
			if s.level[learnt[i].Var()] > s.level[learnt[maxI].Var()] {
				maxI = i
			}
		}
		learnt[1], learnt[maxI] = learnt[maxI], learnt[1]
		bt = s.level[learnt[1].Var()]
	}
	return learnt, bt
}

func (s *Solver) litRedundant(p Lit, abs uint32) bool {
	s.stack = append(s.stack[:0], p)
	top := len(s.toClear)
	for len(s.stack) > 0 {
		q := s.stack[len(s.stack)-1]
		s.stack = s.stack[:len(s.stack)-1]
		c := s.reason[q.Var()]
		for _, l := range c.lits[1:] {
			v := l.Var()
			if s.seen[v] || s.level[v] == 0 {
				continue
			}
			if s.reason[v] != nil && s.abstractLevel(v)&abs != 0 {
				s.seen[v] = true
				s.stack = append(s.stack, l)
				s.toClear = append(s.toClear, l)
			} else {
				for _, t := range s.toClear[top:] {
					s.seen[t.Var()] = false
				}
				s.toClear = s.toClear[:top]
				return false
			}
		}
	}
	return true
}

func (s *Solver) computeLBD(lits []Lit) int {
	s.lbdStamp++
	n := 0
	for _, l := range lits {
		lv := s.level[l.Var()]
		for len(s.lbdSeen) <= lv {
			s.lbdSeen = append(s.lbdSeen, 0)
		}
		if s.lbdSeen[lv] != s.lbdStamp {
			s.lbdSeen[lv] = s.lbdStamp
			n++
		}
	}
	return n
}

func (s *Solver) cancelUntil(lvl int) {
	if s.decisionLevel() <= lvl {
		return
	}
	for i := len(s.trail) - 1; i >= s.trailLim[lvl]; i-- {
		v := s.trail[i].Var()
		s.polarity[v] = s.trail[i].Neg()
		s.assigns[v] = lUndef
		s.reason[v] = nil
		if !s.heap.contains(v) {
			s.heap.insert(v)
		}
	}
	s.trail = s.trail[:s.trailLim[lvl]]
	s.trailLim = s.trailLim[:lvl]
	s.qhead = len(s.trail)
}

func (s *Solver) locked(c *clause) bool {
	l := c.lits[0]
	return s.reason[l.Var()] == c && s.value(l) == lTrue
}

// reduceDB removes roughly half of the learnt clauses, keeping "glue"
// clauses (LBD <= 2) and anything currently acting as a reason.
func (s *Solver) reduceDB() {
	sort.Slice(s.learnts, func(i, j int) bool {
		a, b := s.learnts[i], s.learnts[j]
		if a.lbd != b.lbd {
			return a.lbd > b.lbd
		}
		return a.act < b.act
	})
	half := len(s.learnts) / 2
	out := s.learnts[:0]
	for i, c := range s.learnts {
		if i < half && c.lbd > 2 && len(c.lits) > 2 && !s.locked(c) {
			c.deleted = true
			s.Stats.Deleted++
		} else {
			out = append(out, c)
		}
	}
	s.learnts = out
}

func (s *Solver) pickBranch() Lit {
	for !s.heap.empty() {
		v := s.heap.pop()
		if s.assigns[v] == lUndef {
			return MkLit(v, s.polarity[v])
		}
	}
	return -1
}

// luby returns the i-th element (0-based) of the Luby sequence 1,1,2,1,1,2,4,...
func luby(i uint64) uint64 {
	size, seq := uint64(1), uint64(0)
	for size < i+1 {
		seq++
		size = 2*size + 1
	}
	for size-1 != i {
		size = (size - 1) / 2
		seq--
		i %= size
	}
	return 1 << seq
}

// search runs CDCL until a result or until nConflicts conflicts (restart).
func (s *Solver) search(nConflicts uint64) Status {
	var conflicts uint64
	for {
		confl := s.propagate()
		if confl != nil {
			s.Stats.Conflicts++
			conflicts++
			if s.decisionLevel() == 0 {
				return Unsat
			}
			learnt, bt := s.analyze(confl)
			s.cancelUntil(bt)
			s.Stats.LearntLits += uint64(len(learnt))
			if len(learnt) == 1 {
				s.enqueue(learnt[0], nil)
			} else {
				c := &clause{lits: learnt, learnt: true, lbd: s.computeLBD(learnt)}
				s.learnts = append(s.learnts, c)
				s.attach(c)
				s.bumpClause(c)
				s.enqueue(learnt[0], c)
				s.Stats.Learnt++
			}
			s.varInc /= 0.95
			s.claInc /= 0.999
			continue
		}
		if s.ConflictLimit > 0 && s.Stats.Conflicts >= s.ConflictLimit {
			s.cancelUntil(0)
			return Unknown
		}
		if conflicts >= nConflicts {
			s.cancelUntil(0)
			return Unknown
		}
		if float64(len(s.learnts))-float64(len(s.trail)) >= s.maxLearnt {
			s.reduceDB()
			s.maxLearnt *= 1.1
		}
		next := s.pickBranch()
		if next == -1 {
			return Sat
		}
		s.Stats.Decisions++
		s.trailLim = append(s.trailLim, len(s.trail))
		s.enqueue(next, nil)
	}
}

// Solve decides satisfiability. On Sat, Model() returns a satisfying assignment.
// Solve may be called again after adding more clauses (incremental use).
func (s *Solver) Solve() Status {
	s.model = nil
	if !s.ok {
		return Unsat
	}
	s.cancelUntil(0)
	if s.propagate() != nil {
		s.ok = false
		return Unsat
	}
	if s.maxLearnt == 0 {
		s.maxLearnt = float64(len(s.clauses))/3 + 2000
	}
	for r := uint64(0); ; r++ {
		st := s.search(luby(r) * 100)
		switch {
		case st == Sat:
			s.model = make([]bool, s.nVars)
			for v := range s.model {
				s.model[v] = s.assigns[v] == lTrue
			}
			s.cancelUntil(0)
			return Sat
		case st == Unsat:
			s.ok = false
			return Unsat
		case s.ConflictLimit > 0 && s.Stats.Conflicts >= s.ConflictLimit:
			return Unknown
		}
		s.Stats.Restarts++
	}
}

// Model returns the last satisfying assignment (model[v] is the value of variable v).
func (s *Solver) Model() []bool { return s.model }

// Value reports the model value of literal l.
func (s *Solver) ModelValue(l Lit) bool { return s.model[l.Var()] != l.Neg() }
