// Public API: a RegExp-like class whose running time is linear in the input,
// whatever the pattern.

import { parse, Flags } from './parse';
import { compile, Program, disassemble } from './compile';
import { PikeVM, LazyDFA } from './vm';

export { RegexSyntaxError } from './parse';

export interface Match {
  index: number;
  end: number;
  text: string;
  groups: (string | undefined)[]; // groups[0] is the whole match
  named: Record<string, string | undefined>;
  spans: [number, number][];      // [-1,-1] for unset groups
}

export class Regex {
  readonly source: string;
  readonly flags: string;
  readonly program: Program;
  readonly groupNames: Map<string, number>;
  private pike: PikeVM;
  private dfa: LazyDFA;

  constructor(source: string, flags = '') {
    for (const f of flags) if (!'ims'.includes(f)) throw new Error(`unsupported flag '${f}' (supported: i, m, s)`);
    const fl: Flags = { i: flags.includes('i'), m: flags.includes('m'), s: flags.includes('s') };
    this.source = source;
    this.flags = flags;
    const { ast, groups, names } = parse(source, fl);
    this.program = compile(ast, groups, fl);
    this.groupNames = names;
    this.pike = new PikeVM(this.program);
    this.dfa = new LazyDFA(this.program);
  }

  /** Fast yes/no answer using the lazy DFA. */
  test(s: string): boolean { return this.dfa.test(s); }

  /** First (leftmost-first) match at or after `from`, with capture groups. */
  exec(s: string, from = 0): Match | null {
    const caps = this.pike.exec(s, from);
    if (!caps) return null;
    const spans: [number, number][] = [];
    const groups: (string | undefined)[] = [];
    for (let g = 0; g < this.program.ncaps; g += 2) {
      const a = caps[g], b = caps[g + 1];
      spans.push([a, b]);
      groups.push(a >= 0 && b >= 0 ? s.slice(a, b) : undefined);
    }
    const named: Record<string, string | undefined> = {};
    for (const [k, v] of this.groupNames) named[k] = groups[v];
    return { index: spans[0][0], end: spans[0][1], text: groups[0]!, groups, named, spans };
  }

  /** All non-overlapping matches, like String.prototype.matchAll with /g. */
  *matchAll(s: string): Generator<Match> {
    let from = 0;
    while (from <= s.length) {
      const m = this.exec(s, from);
      if (!m) return;
      yield m;
      from = m.end > m.index ? m.end : m.end + 1;
    }
  }

  /** Replace every match. `$1`, `$<name>`, `$&` and `$$` work in string replacements. */
  replaceAll(s: string, rep: string | ((m: Match) => string)): string {
    let out = '', last = 0;
    for (const m of this.matchAll(s)) {
      out += s.slice(last, m.index);
      out += typeof rep === 'function' ? rep(m) : rep.replace(/\$(\$|&|\d+|<([^>]+)>)/g, (_, t: string, name?: string) =>
        t === '$' ? '$' : t === '&' ? m.text : name !== undefined ? (m.named[name] ?? '') : (m.groups[+t] ?? ''));
      last = m.end;
    }
    return out + s.slice(last);
  }

  disassemble(): string { return disassemble(this.program); }
  get stats() { return { dfa: { ...this.dfa.stats }, pikeSteps: this.pike.stats.steps }; }
}
