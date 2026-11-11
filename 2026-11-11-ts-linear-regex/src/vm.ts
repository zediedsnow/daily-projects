// Two executors for the same program:
//
//  * PikeVM — simulates every NFA thread in lock-step, one input char at a
//    time, keeping threads in priority order. Gives exact leftmost-first
//    spans and capture groups in O(len(input) × len(program)) time.
//
//  * LazyDFA — subset construction done on demand and memoised, so each
//    input char costs one table lookup once the relevant states exist.
//    Answers "is there a match?" without captures.

import { Program, Op } from './compile';
import { contains, isWordChar, isLineTerm, Ranges } from './charset';
import { Assertion } from './parse';

type Caps = (number)[]; // -1 = unset

function assertOk(k: Assertion, prev: number, next: number, multiline: boolean): boolean {
  switch (k) {
    case 'bol': return prev < 0 || (multiline && isLineTerm(prev));
    case 'eol': return next < 0 || (multiline && isLineTerm(next));
    case 'wordb': return (prev >= 0 && isWordChar(prev)) !== (next >= 0 && isWordChar(next));
    case 'nwordb': return (prev >= 0 && isWordChar(prev)) === (next >= 0 && isWordChar(next));
  }
}

export interface VMStats { steps: number }

export class PikeVM {
  private mark: Uint32Array;
  private threadMark: Uint32Array;
  private visitedBits = new Set<number>();
  private gen = 0;
  // stack for the iterative epsilon-closure
  private stackPc: number[] = [];
  private stackBits: number[] = [];
  private stackCaps: Caps[] = [];
  /** Chars that can begin a match, or null if a match can start with anything / be empty. */
  readonly firstSet: Ranges | null;
  stats: VMStats = { steps: 0 };

  constructor(private p: Program) {
    this.mark = new Uint32Array(p.insts.length);
    this.threadMark = new Uint32Array(p.insts.length);
    this.firstSet = this.computeFirstSet();
  }

  private computeFirstSet(): Ranges | null {
    const seen = new Uint8Array(this.p.insts.length);
    const out: number[] = [];
    const stack = [0];
    while (stack.length) {
      const pc = stack.pop()!;
      if (seen[pc]) continue;
      seen[pc] = 1;
      const i = this.p.insts[pc];
      switch (i.op) {
        case Op.Char: out.push(...i.r); break;
        case Op.Match: return null;
        case Op.Split: stack.push(i.x, i.y); break;
        case Op.Jmp: stack.push(i.x); break;
        default: stack.push(pc + 1);
      }
    }
    // normalize
    const pairs: [number, number][] = [];
    for (let k = 0; k < out.length; k += 2) pairs.push([out[k], out[k + 1]]);
    pairs.sort((a, b) => a[0] - b[0]);
    const r: number[] = [];
    for (const [lo, hi] of pairs) {
      if (r.length && lo <= r[r.length - 1] + 1) r[r.length - 1] = Math.max(r[r.length - 1], hi);
      else r.push(lo, hi);
    }
    return r.length > 64 ? null : r; // too fragmented to be a useful prefilter
  }

  // The epsilon-closure is memoised on (pc, bits) where bit r says "loop
  // register r was set at the current position". Two paths reaching the same
  // pc with the same bits have identical futures, so the first (highest
  // priority) one wins — that keeps leftmost-first semantics exact even with
  // ECMAScript's empty-iteration rule, and the work stays O(program) per char.
  private newGen() { this.gen++; this.visitedBits.clear(); }

  private add(pcs: number[], capsList: Caps[], pc0: number, caps0: Caps, s: string, i: number) {
    const insts = this.p.insts, mark = this.mark, tmark = this.threadMark, gen = this.gen, ml = this.p.flags.m;
    const base = this.p.ncaps, vb = this.visitedBits;
    const prev = i > 0 ? s.charCodeAt(i - 1) : -1;
    const next = i < s.length ? s.charCodeAt(i) : -1;
    const sp = this.stackPc, sc = this.stackCaps, sb = this.stackBits;
    sp.push(pc0); sc.push(caps0); sb.push(0);
    while (sp.length) {
      let pc = sp.pop()!;
      let caps = sc.pop()!;
      let bits = sb.pop()!;
      for (;;) {
        if (bits === 0) {
          if (mark[pc] === gen) break;
          mark[pc] = gen;
        } else {
          const key = pc * 1073741824 + bits;
          if (vb.has(key)) break;
          vb.add(key);
        }
        this.stats.steps++;
        const inst = insts[pc];
        if (inst.op === Op.Jmp) { pc = inst.x; continue; }
        if (inst.op === Op.Split) { sp.push(inst.y); sc.push(caps); sb.push(bits); pc = inst.x; continue; }
        if (inst.op === Op.Save) { caps = caps.slice(); caps[inst.n] = i; pc++; continue; }
        if (inst.op === Op.Reset) {
          let dirty = false;
          for (let k = inst.lo; k < inst.hi; k++) if (caps[k] !== -1) { dirty = true; break; }
          if (dirty) { caps = caps.slice(); caps.fill(-1, inst.lo, inst.hi); }
          pc++; continue;
        }
        if (inst.op === Op.Mark) {
          if (caps[inst.n] !== i) { caps = caps.slice(); caps[inst.n] = i; }
          const r = inst.n - base;
          if (r < 30) bits |= 1 << r;
          pc++; continue;
        }
        if (inst.op === Op.Progress) { if (caps[inst.n] === i) break; pc++; continue; }
        if (inst.op === Op.Assert) { if (!assertOk(inst.k, prev, next, ml)) break; pc++; continue; }
        // Char or Match: a real thread. Its future no longer depends on the
        // loop registers (they can't equal any later position), so dedup on pc.
        if (tmark[pc] !== gen) { tmark[pc] = gen; pcs.push(pc); capsList.push(caps); }
        break;
      }
    }
  }

  /** Leftmost-first match starting the search at `from`. Returns capture slots or null. */
  exec(s: string, from = 0): Caps | null {
    const insts = this.p.insts;
    const n = s.length;
    const empty: Caps = new Array(this.p.nslots).fill(-1);
    let cpcs: number[] = [], ccaps: Caps[] = [];
    let npcs: number[] = [], ncaps: Caps[] = [];
    let matched: Caps | null = null;
    const fs = this.firstSet;
    this.newGen();
    for (let i = from; i <= n; i++) {
      if (matched === null && (!this.p.anchoredStart || i === 0)) {
        if (cpcs.length === 0) {
          if (this.p.anchoredStart && i > 0) break;
          // nothing running: jump straight to the next char that could start a match
          if (fs) {
            while (i < n && !contains(fs, s.charCodeAt(i))) i++;
            if (i >= n) break;
          }
          this.newGen(); // the list is empty, so its generation may belong to an earlier position
        }
        // lowest-priority thread: a new match attempt starting at i (same
        // generation as the list, so it is deduplicated against it)
        this.add(cpcs, ccaps, 0, empty, s, i);
      } else if (cpcs.length === 0) break;
      const c = i < n ? s.charCodeAt(i) : -1;
      this.newGen();
      for (let t = 0; t < cpcs.length; t++) {
        const inst = insts[cpcs[t]];
        if (inst.op === Op.Match) { matched = ccaps[t]; break; } // cut lower-priority threads
        if (inst.op === Op.Char && c >= 0 && contains(inst.r, c)) this.add(npcs, ncaps, cpcs[t] + 1, ccaps[t], s, i + 1);
      }
      [cpcs, npcs] = [npcs, cpcs]; [ccaps, ncaps] = [ncaps, ccaps];
      npcs.length = 0; ncaps.length = 0;
    }
    return matched;
  }
}

// ---------------------------------------------------------------------------

const MATCH = -1;
const UNKNOWN = -2;

interface DState {
  pcs: Int32Array;   // NFA pcs pending (before epsilon closure)
  flags: number;     // bit0 atStart, bit1 prevWord, bit2 prevLineTerm
  ascii: Int32Array; // transitions for chars < 256 (UNKNOWN until computed)
  other: Map<number, number>;
}

export interface DFAStats { states: number; flushes: number; transitionsComputed: number }

export class LazyDFA {
  private states: DState[] = [];
  private index = new Map<string, number>();
  private mark: Uint32Array;
  private gen = 0;
  private readonly maxStates: number;
  stats: DFAStats = { states: 0, flushes: 0, transitionsComputed: 0 };

  constructor(private p: Program, maxStates = 10_000) {
    this.mark = new Uint32Array(p.insts.length);
    this.maxStates = maxStates;
  }

  private intern(pcs: number[], flags: number): number {
    pcs.sort((a, b) => a - b);
    const key = flags + ':' + pcs.join(',');
    const hit = this.index.get(key);
    if (hit !== undefined) return hit;
    const ascii = new Int32Array(256).fill(UNKNOWN);
    this.states.push({ pcs: Int32Array.from(pcs), flags, ascii, other: new Map() });
    this.index.set(key, this.states.length - 1);
    this.stats.states++;
    return this.states.length - 1;
  }

  private canonFlags(atStart: boolean, prev: number): number {
    const p = this.p;
    let f = 0;
    if (p.usesBol && atStart) f |= 1;
    if (p.usesWordB && prev >= 0 && isWordChar(prev)) f |= 2;
    if (p.usesBol && p.flags.m && prev >= 0 && isLineTerm(prev)) f |= 4;
    return f;
  }

  private start(): number { return this.intern([0], this.canonFlags(true, -1)); }

  /** Compute (and memoise) the transition from state `sid` on char `c` (-1 = end of input). */
  private step(sid: number, c: number): number {
    const st = this.states[sid];
    this.stats.transitionsComputed++;
    const insts = this.p.insts, ml = this.p.flags.m;
    // reconstruct a representative "previous char" for the assertion checks
    const prev = st.flags & 4 ? 10 : st.flags & 2 ? 0x61 : (st.flags & 1 ? -1 : 0x20);
    const atStart = (st.flags & 1) !== 0;
    this.gen++;
    const mark = this.mark, gen = this.gen;
    const next: number[] = [];
    const stack = Array.from(st.pcs);
    let matched = false;
    while (stack.length && !matched) {
      const pc = stack.pop()!;
      if (mark[pc] === gen) continue;
      mark[pc] = gen;
      const inst = insts[pc];
      switch (inst.op) {
        case Op.Jmp: stack.push(inst.x); break;
        case Op.Split: stack.push(inst.y, inst.x); break;
        case Op.Save: case Op.Reset: case Op.Mark: case Op.Progress: stack.push(pc + 1); break;
        case Op.Assert: {
          const ok = inst.k === 'bol'
            ? atStart || (ml && (st.flags & 4) !== 0)
            : assertOk(inst.k, prev, c, ml);
          if (ok) stack.push(pc + 1);
          break;
        }
        case Op.Match: matched = true; break;
        case Op.Char: if (c >= 0 && contains(inst.r, c)) next.push(pc + 1); break;
      }
    }
    let result: number;
    if (matched) result = MATCH;
    else {
      if (!this.p.anchoredStart) next.push(0); // unanchored search: a new attempt may start here
      const uniq = Array.from(new Set(next));
      result = this.intern(uniq, this.canonFlags(false, c));
    }
    if (this.states.length > this.maxStates) {
      // cache blew its budget: forget everything but keep going (RE2's strategy)
      this.stats.flushes++;
      const keep = result === MATCH ? null : this.states[result];
      this.states = []; this.index.clear();
      return keep ? this.intern(Array.from(keep.pcs), keep.flags) : MATCH;
    }
    if (c >= 0 && c < 256) st.ascii[c] = result;
    else st.other.set(c, result);
    return result;
  }

  /** Does `s` contain a match? One table lookup per char once the DFA is warm. */
  test(s: string): boolean {
    let sid = this.start();
    const n = s.length;
    for (let i = 0; i < n; i++) {
      const c = s.charCodeAt(i);
      const st = this.states[sid];
      let nx = c < 256 ? st.ascii[c] : (st.other.get(c) ?? UNKNOWN);
      if (nx === UNKNOWN) nx = this.step(sid, c);
      if (nx === MATCH) return true;
      sid = nx;
      if (this.states[sid].pcs.length === 0) return false; // dead state
    }
    const st = this.states[sid];
    const fin = st.other.get(-1) ?? this.step(sid, -1);
    return fin === MATCH;
  }
}
