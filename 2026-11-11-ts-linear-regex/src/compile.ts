// Thompson construction: AST → a flat program for a non-backtracking VM.
// SPLIT has an ordered pair of targets (x preferred over y); that ordering is
// what lets the Pike VM reproduce Perl/JS "leftmost-first" match semantics.

import { Node, Assertion, Flags } from './parse';
import { Ranges, describe } from './charset';

export const enum Op { Char, Split, Jmp, Save, Assert, Reset, Mark, Progress, Match }

export type Inst =
  | { op: Op.Char; r: Ranges }
  | { op: Op.Split; x: number; y: number }
  | { op: Op.Jmp; x: number }
  | { op: Op.Save; n: number }
  | { op: Op.Assert; k: Assertion }
  | { op: Op.Reset; lo: number; hi: number } // clear capture slots [lo, hi)
  | { op: Op.Mark; n: number }     // remember the position where a loop iteration began
  | { op: Op.Progress; n: number } // kill the thread if that iteration consumed nothing
  | { op: Op.Match };

export interface Program {
  insts: Inst[];
  nslots: number; // capture slots + loop-progress registers
  ncaps: number;  // capture slots only: 2 × (groups + 1)
  flags: Flags;
  usesWordB: boolean;
  usesBol: boolean;
  anchoredStart: boolean; // every match must begin at index 0 (non-multiline ^ prefix)
}

export const MAX_PROGRAM = 200_000;

export function compile(ast: Node, groups: number, flags: Flags): Program {
  const insts: Inst[] = [];
  let nslots = 2 * (groups + 1);
  let usesWordB = false, usesBol = false;
  const emit = (i: Inst) => {
    if (insts.length >= MAX_PROGRAM) throw new Error(`pattern too large: program exceeds ${MAX_PROGRAM} instructions`);
    insts.push(i);
    return insts.length - 1;
  };

  // capture-group index range [lo, hi] contained in a subtree, for Reset
  function groupSpan(n: Node): [number, number] | null {
    switch (n.t) {
      case 'group': {
        const inner = groupSpan(n.x);
        if (n.idx === null) return inner;
        return [n.idx, inner ? inner[1] : n.idx];
      }
      case 'cat': case 'alt': {
        let lo = Infinity, hi = -Infinity;
        for (const x of n.xs) { const s = groupSpan(x); if (s) { lo = Math.min(lo, s[0]); hi = Math.max(hi, s[1]); } }
        return lo === Infinity ? null : [lo, hi];
      }
      case 'rep': return groupSpan(n.x);
      default: return null;
    }
  }

  // can this subtree match the empty string?
  function nullable(n: Node): boolean {
    switch (n.t) {
      case 'empty': case 'assert': return true;
      case 'set': return false;
      case 'cat': return n.xs.every(nullable);
      case 'alt': return n.xs.some(nullable);
      case 'group': return nullable(n.x);
      case 'rep': return n.min === 0 || nullable(n.x);
    }
  }

  function gen(n: Node): void {
    switch (n.t) {
      case 'empty': return;
      case 'set': emit({ op: Op.Char, r: n.r }); return;
      case 'assert':
        if (n.k === 'wordb' || n.k === 'nwordb') usesWordB = true;
        if (n.k === 'bol') usesBol = true;
        emit({ op: Op.Assert, k: n.k }); return;
      case 'cat': for (const x of n.xs) gen(x); return;
      case 'group':
        if (n.idx === null) { gen(n.x); return; }
        emit({ op: Op.Save, n: 2 * n.idx });
        gen(n.x);
        emit({ op: Op.Save, n: 2 * n.idx + 1 });
        return;
      case 'alt': {
        // L0: split L1, next0 ; L1: x0 ; jmp end ; next0: split ...
        const jumps: number[] = [];
        for (let k = 0; k < n.xs.length; k++) {
          if (k < n.xs.length - 1) {
            const sp = emit({ op: Op.Split, x: 0, y: 0 });
            (insts[sp] as any).x = insts.length;
            gen(n.xs[k]);
            jumps.push(emit({ op: Op.Jmp, x: 0 }));
            (insts[sp] as any).y = insts.length;
          } else gen(n.xs[k]);
        }
        for (const j of jumps) (insts[j] as any).x = insts.length;
        return;
      }
      case 'rep': {
        const span = groupSpan(n.x);
        // ECMAScript clears a loop body's captures at the start of every iteration
        // ...and rejects an optional iteration that matches the empty string
        // (ECMA-262 RepeatMatcher step "min = 0 and endIndex unchanged → failure").
        const reg = nullable(n.x) && (n.max > n.min) ? nslots++ : -1;
        const body = (optional: boolean) => {
          if (optional && reg >= 0) emit({ op: Op.Mark, n: reg });
          if (span) emit({ op: Op.Reset, lo: 2 * span[0], hi: 2 * span[1] + 2 });
          gen(n.x);
          if (optional && reg >= 0) emit({ op: Op.Progress, n: reg });
        };
        const split = (pc: number, take: number, skip: number) => {
          (insts[pc] as any).x = n.greedy ? take : skip;
          (insts[pc] as any).y = n.greedy ? skip : take;
        };
        for (let k = 0; k < n.min; k++) body(false);
        if (n.max === Infinity) {
          // L: split body, out ; body ; jmp L ; out:
          const L = emit({ op: Op.Split, x: 0, y: 0 });
          body(true);
          emit({ op: Op.Jmp, x: L });
          split(L, L + 1, insts.length);
        } else {
          // nested optionals: (x(x(x)?)?)? — avoids an O(n²) ambiguity blow-up
          const splits: number[] = [];
          for (let k = n.min; k < n.max; k++) {
            const sp = emit({ op: Op.Split, x: 0, y: 0 });
            splits.push(sp);
            body(true);
          }
          const out = insts.length;
          for (const sp of splits) split(sp, sp + 1, out);
        }
        return;
      }
    }
  }

  emit({ op: Op.Save, n: 0 });
  gen(ast);
  emit({ op: Op.Save, n: 1 });
  emit({ op: Op.Match });

  // Is the pattern anchored at the start? (first real instruction is ^ in non-multiline mode)
  let anchoredStart = false;
  if (!flags.m) {
    let pc = 1;
    while (insts[pc] && insts[pc].op === Op.Save) pc++;
    anchoredStart = insts[pc]?.op === Op.Assert && (insts[pc] as any).k === 'bol';
  }

  return { insts, nslots, ncaps: 2 * (groups + 1), flags, usesWordB, usesBol, anchoredStart };
}

export function disassemble(p: Program): string {
  const w = String(p.insts.length - 1).length;
  return p.insts.map((i, pc) => {
    const a = String(pc).padStart(w);
    switch (i.op) {
      case Op.Char: return `${a}  char   ${describe(i.r)}`;
      case Op.Split: return `${a}  split  ${i.x}, ${i.y}`;
      case Op.Jmp: return `${a}  jmp    ${i.x}`;
      case Op.Save: return `${a}  save   ${i.n}`;
      case Op.Assert: return `${a}  assert ${i.k}`;
      case Op.Reset: return `${a}  reset  ${i.lo}..${i.hi - 1}`;
      case Op.Mark: return `${a}  mark   r${i.n}`;
      case Op.Progress: return `${a}  progress r${i.n}`;
      case Op.Match: return `${a}  match`;
    }
  }).join('\n');
}
