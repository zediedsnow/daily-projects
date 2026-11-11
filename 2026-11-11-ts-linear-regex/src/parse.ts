// Recursive-descent parser for ECMAScript-flavoured regex syntax (non-unicode mode).
// Everything that would require backtracking (backreferences, lookaround) is
// rejected with a clear error: that restriction is what buys linear time.

import * as CS from './charset';

export type Assertion = 'bol' | 'eol' | 'wordb' | 'nwordb';

export type Node =
  | { t: 'empty' }
  | { t: 'set'; r: CS.Ranges }
  | { t: 'cat'; xs: Node[] }
  | { t: 'alt'; xs: Node[] }
  | { t: 'rep'; x: Node; min: number; max: number; greedy: boolean }
  | { t: 'group'; x: Node; idx: number | null; name?: string }
  | { t: 'assert'; k: Assertion };

export interface Flags { i: boolean; m: boolean; s: boolean }

export class RegexSyntaxError extends Error {
  constructor(msg: string, public pattern: string, public pos: number) {
    super(`${msg} at position ${pos}\n  /${pattern}/\n   ${' '.repeat(pos)}^`);
  }
}

export interface ParseResult { ast: Node; groups: number; names: Map<string, number> }

export function parse(src: string, flags: Flags): ParseResult {
  let pos = 0;
  let groupCount = 0;
  const names = new Map<string, number>();
  const err = (m: string, at = pos): never => { throw new RegexSyntaxError(m, src, at); };
  const peek = () => src[pos];
  const eat = (s: string) => (src.startsWith(s, pos) ? ((pos += s.length), true) : false);

  const lit = (c: number): Node => ({ t: 'set', r: flags.i ? CS.caseFold([c, c]) : [c, c] });
  const set = (r: CS.Ranges, negate = false): Node => {
    let x = CS.normalize(r);
    if (flags.i) x = CS.caseFold(x);
    return { t: 'set', r: negate ? CS.complement(x) : x };
  };

  function parseAlt(): Node {
    const xs = [parseCat()];
    while (eat('|')) xs.push(parseCat());
    return xs.length === 1 ? xs[0] : { t: 'alt', xs };
  }

  function parseCat(): Node {
    const xs: Node[] = [];
    while (pos < src.length && peek() !== '|' && peek() !== ')') xs.push(parseRepeat());
    if (xs.length === 0) return { t: 'empty' };
    return xs.length === 1 ? xs[0] : { t: 'cat', xs };
  }

  // Try to read {m}, {m,}, {m,n}; returns null (and leaves pos) if not a quantifier.
  function braces(): [number, number] | null {
    const m = /^\{(\d+)(,(\d*))?\}/.exec(src.slice(pos));
    if (!m) return null;
    pos += m[0].length;
    const min = +m[1];
    const max = m[2] === undefined ? min : m[3] === '' ? Infinity : +m[3];
    if (max < min) err('numbers out of order in {} quantifier', pos - m[0].length);
    if (min > 1000 || (max !== Infinity && max > 1000)) err('repeat count too large (max 1000)', pos - m[0].length);
    return [min, max];
  }

  function parseRepeat(): Node {
    const start = pos;
    let x = parseAtom();
    const c = peek();
    let q: [number, number] | null = null;
    if (c === '*') { pos++; q = [0, Infinity]; }
    else if (c === '+') { pos++; q = [1, Infinity]; }
    else if (c === '?') { pos++; q = [0, 1]; }
    else if (c === '{') q = braces();
    if (!q) return x;
    if (x.t === 'assert') err('nothing to repeat', start);
    const greedy = !eat('?');
    x = { t: 'rep', x, min: q[0], max: q[1], greedy };
    const n = peek();
    if (n === '*' || n === '+' || n === '?' || (n === '{' && /^\{\d+(,\d*)?\}/.test(src.slice(pos))))
      err('nothing to repeat');
    return x;
  }

  function parseAtom(): Node {
    const c = src[pos];
    switch (c) {
      case '(': {
        const open = pos++;
        let idx: number | null = null, name: string | undefined;
        if (eat('?:')) idx = null;
        else if (src.startsWith('?=', pos) || src.startsWith('?!', pos) ||
                 src.startsWith('?<=', pos) || src.startsWith('?<!', pos))
          err('lookaround is not supported (it cannot be done in linear time with this design)', open);
        else if (eat('?<')) {
          const m = /^([A-Za-z_$][\w$]*)>/.exec(src.slice(pos));
          if (!m) err('invalid group name');
          name = m![1]; pos += m![0].length;
          if (names.has(name)) err(`duplicate group name '${name}'`);
          idx = ++groupCount; names.set(name, idx);
        } else if (peek() === '?') err('invalid group');
        else idx = ++groupCount;
        const x = parseAlt();
        if (!eat(')')) err('unterminated group', open);
        return { t: 'group', x, idx, name };
      }
      case ')': return err('unmatched )');
      case '*': case '+': case '?': return err('nothing to repeat');
      case '{': {
        if (braces()) err('nothing to repeat');
        pos++; return lit(0x7b);
      }
      case '[': return parseClass();
      case '.': pos++; return { t: 'set', r: flags.s ? CS.ANY : CS.DOT };
      case '^': pos++; return { t: 'assert', k: 'bol' };
      case '$': pos++; return { t: 'assert', k: 'eol' };
      case '\\': {
        pos++;
        if (pos >= src.length) err('\\ at end of pattern');
        const e = src[pos];
        if (e === 'b') { pos++; return { t: 'assert', k: 'wordb' }; }
        if (e === 'B') { pos++; return { t: 'assert', k: 'nwordb' }; }
        if (/[1-9]/.test(e)) err('backreferences are not supported (matching them is NP-hard)');
        if (e === 'k' && names.size >= 0 && src[pos + 1] === '<') err('backreferences are not supported (matching them is NP-hard)');
        const cls = classEscape();
        if (cls) return set(cls.r, cls.neg);
        return lit(charEscape());
      }
      default:
        pos++;
        return lit(c.charCodeAt(0));
    }
  }

  // \d \D \w \W \s \S (pos at the letter)
  function classEscape(): { r: CS.Ranges; neg: boolean } | null {
    const e = src[pos];
    const tbl: Record<string, CS.Ranges> = { d: CS.DIGIT, w: CS.WORD, s: CS.SPACE };
    const k = e.toLowerCase();
    if (!(k in tbl)) return null;
    pos++;
    return { r: tbl[k], neg: e !== k };
  }

  // Single-character escapes (pos at the char after '\'); returns the code unit.
  function charEscape(inClass = false): number {
    const e = src[pos++];
    switch (e) {
      case 'n': return 10; case 'r': return 13; case 't': return 9;
      case 'f': return 12; case 'v': return 11;
      case 'b': if (inClass) return 8; break;
      case '0': if (!/[0-9]/.test(src[pos] ?? '')) return 0; break;
      case 'x': {
        const m = /^[0-9a-fA-F]{2}/.exec(src.slice(pos));
        if (m) { pos += 2; return parseInt(m[0], 16); }
        return 0x78;
      }
      case 'u': {
        const m = /^[0-9a-fA-F]{4}/.exec(src.slice(pos));
        if (m) { pos += 4; return parseInt(m[0], 16); }
        return 0x75;
      }
      case 'c': {
        const l = src[pos];
        if (l && /[A-Za-z]/.test(l)) { pos++; return l.charCodeAt(0) % 32; }
        pos--; return 0x5c; // "\c" without letter means a literal backslash
      }
    }
    return e.charCodeAt(0); // identity escape
  }

  function parseClass(): Node {
    const open = pos++;
    const neg = eat('^');
    const r: CS.Ranges = [];
    // one class atom: either a single char code, or a whole set (\d etc.)
    const atom = (): number | CS.Ranges => {
      if (src[pos] === '\\') {
        pos++;
        if (pos >= src.length) err('\\ at end of pattern');
        const cls = classEscape();
        if (cls) return cls.neg ? CS.complement(cls.r) : cls.r;
        if (/[1-7]/.test(src[pos])) { // legacy octal escape inside classes (Annex B)
          const m = /^[0-3][0-7]{0,2}|^[4-7][0-7]?/.exec(src.slice(pos))!;
          pos += m[0].length;
          return parseInt(m[0], 8);
        }
        return charEscape(true);
      }
      return src.charCodeAt(pos++);
    };
    while (true) {
      if (pos >= src.length) err('unterminated character class', open);
      if (eat(']')) break;
      const a = atom();
      if (typeof a === 'number' && src[pos] === '-' && src[pos + 1] !== ']' && pos + 1 < src.length) {
        const save = pos++;
        const b = atom();
        if (typeof b === 'number') {
          if (b < a) err('range out of order in character class', save);
          r.push(a, b);
          continue;
        }
        r.push(a, a, 0x2d, 0x2d, ...b); // [a-\d] → a, '-', digits (Annex B)
        continue;
      }
      if (typeof a === 'number') r.push(a, a);
      else r.push(...a);
    }
    return set(r, neg);
  }

  const ast = parseAlt();
  if (pos < src.length) err(peek() === ')' ? 'unmatched )' : 'unexpected character');
  return { ast, groups: groupCount, names };
}
