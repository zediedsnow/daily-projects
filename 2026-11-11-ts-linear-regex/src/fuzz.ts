// Test suite: hand-written cases + differential fuzzing against V8's own
// backtracking RegExp. Every random pattern is run through both engines and
// the match position AND every capture group must agree exactly.

import { Regex, RegexSyntaxError } from './regex';

let seed = Number(process.env.SEED ?? 20261111);
function rnd(n: number): number { // xorshift32
  seed ^= seed << 13; seed >>>= 0; seed ^= seed >>> 17; seed ^= seed << 5; seed >>>= 0;
  return seed % n;
}
const pick = <T>(xs: T[]): T => xs[rnd(xs.length)];

let groupNo = 0;
function genPattern(depth: number): string {
  if (depth <= 0 || rnd(10) < 3) return genAtom(depth);
  switch (rnd(4)) {
    case 0: return genPattern(depth - 1) + '|' + genPattern(depth - 1);
    default: {
      let s = '';
      const k = 1 + rnd(3);
      for (let i = 0; i < k; i++) s += genPattern(depth - 1);
      return s;
    }
  }
}
function genAtom(depth: number): string {
  const r = rnd(20);
  let atom: string;
  if (r < 6) atom = pick(['a', 'b', 'c', 'A', '1', ' ']);
  else if (r < 8) atom = '.';
  else if (r < 11) atom = pick(['[ab]', '[^a]', '[a-c]', '\\d', '\\w', '\\s', '\\W', '[^\\w]', '[A-Z]', '[]', '[^]']);
  else if (r < 15 && depth > 0) {
    const inner = genPattern(depth - 1);
    atom = pick(['(', '(', '(?:', `(?<n${++groupNo}>`]) + inner + ')';
  } else if (r < 17) return pick(['^', '$', '\\b', '\\B']); // assertions: never quantified
  else atom = pick(['a', 'b', 'x']);
  if (rnd(3) === 0) atom += pick(['*', '+', '?', '{0,2}', '{2}', '{1,}', '{0}']) + (rnd(3) === 0 ? '?' : '');
  return atom;
}
function genString(): string {
  const n = rnd(13);
  let s = '';
  for (let i = 0; i < n; i++) s += pick(['a', 'a', 'b', 'b', 'c', 'A', ' ', '\n', '1', '_', 'x']);
  return s;
}

let failures = 0;
function fail(msg: string) {
  failures++;
  if (failures <= 20) console.log('FAIL ' + msg);
}

// ---------------------------------------------------------------- unit tests
function unit() {
  const eq = (a: unknown, b: unknown, what: string) => {
    if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${what}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);
  };
  const m = new Regex('(?<year>\\d{4})-(?<month>\\d\\d)-(?<day>\\d\\d)').exec('released on 2026-11-11!');
  eq(m && [m.index, m.named], [12, { year: '2026', month: '11', day: '11' }], 'named groups');
  eq(new Regex('(\\w+)@(\\w+)\\.com').replaceAll('mail ann@foo.com, bob@bar.com', '$2:$1'), 'mail foo:ann, bar:bob', 'replaceAll');
  eq([...new Regex('a*').matchAll('baaab')].map(x => [x.index, x.text]), [[0, ''], [1, 'aaa'], [4, ''], [5, '']], 'empty matches');
  eq(new Regex('colou?r', 'i').test('My COLOR'), true, 'case-insensitive');
  eq(new Regex('^b', 'm').test('a\nb'), true, 'multiline');
  eq(new Regex('a.b', 's').test('a\nb'), true, 'dotall');
  eq(new Regex('a.b').test('a\nb'), false, 'dot excludes newline');
  eq(new Regex('\\bcat\\b').test('concatenate'), false, 'word boundary');
  eq(new Regex('(a|ab)(c|bcd)(d*)').exec('abcd')!.groups, ['abcd', 'a', 'bcd', ''], 'leftmost-first, not leftmost-longest');
  eq(new Regex('(a+?)(a*)').exec('aaa')!.groups, ['aaa', 'a', 'aa'], 'lazy quantifier');
  eq(new Regex('(?:(a)|b)+').exec('ab')!.groups, ['ab', undefined], 'captures reset per iteration');
  eq(new Regex('[\\u00e9-\\u00ea]+', 'i').exec('cafÉÊ!')!.text, 'ÉÊ', 'unicode case folding');
  for (const [p, why] of [['(a)\\1', 'backreferences'], ['a(?=b)', 'lookaround'], ['a**', 'nothing to repeat'],
                          ['(ab', 'unterminated group'], ['[z-a]', 'out of order']] as const) {
    try { new Regex(p); fail(`/${p}/ should be rejected (${why})`); }
    catch (e) { if (!(e instanceof RegexSyntaxError) || !e.message.includes(why)) fail(`/${p}/: wrong error ${e}`); }
  }
  // the classic ReDoS patterns must finish instantly
  const t0 = Date.now();
  eq(new Regex('(a?){40}a{40}').test('a'.repeat(40)), true, 'pathological (a?){n}a{n}');
  eq(new Regex('(x+x+)+y').test('x'.repeat(5000)), false, 'pathological (x+x+)+y');
  eq(new Regex('^(\\w+\\s?)*$').exec('a'.repeat(3000) + '!'), null, 'pathological ^(\\w+\\s?)*$');
  if (Date.now() - t0 > 2000) fail('pathological patterns took ' + (Date.now() - t0) + ' ms');
}

// ------------------------------------------------------- differential fuzz
function fuzz(cases: number) {
  let compared = 0, matched = 0, rejectedBoth = 0;
  for (let k = 0; k < cases; k++) {
    groupNo = 0;
    const pat = genPattern(1 + rnd(4));
    const flags = pick(['', '', 'i', 'm', 's', 'im', 'is', 'ims']);
    let native: RegExp | null = null, mine: Regex | null = null;
    try { native = new RegExp(pat, flags + 'g'); } catch { /* invalid in JS */ }
    try { mine = new Regex(pat, flags); } catch (e) {
      if (!(e instanceof RegexSyntaxError)) throw e;
    }
    if (!native || !mine) {
      if (native || mine) fail(`/${pat}/${flags}: validity disagrees (native ${!!native}, linrex ${!!mine})`);
      else rejectedBoth++;
      continue;
    }
    for (let j = 0; j < 6; j++) {
      const s = genString();
      const from = rnd(s.length + 1);
      native.lastIndex = from;
      const want = native.exec(s);
      const got = mine.exec(s, from);
      compared++;
      const wantArr = want ? [want.index, ...Array.from(want)] : null;
      const gotArr = got ? [got.index, ...got.groups] : null;
      if (JSON.stringify(wantArr) !== JSON.stringify(gotArr))
        fail(`/${pat}/${flags} on ${JSON.stringify(s)} from ${from}: native ${JSON.stringify(wantArr)} linrex ${JSON.stringify(gotArr)}`);
      native.lastIndex = 0;
      const wantT = native.test(s);
      if (mine.test(s) !== wantT) fail(`/${pat}/${flags} test(${JSON.stringify(s)}): native ${wantT}, DFA ${!wantT}`);
      if (want) matched++;
    }
  }
  return { compared, matched, rejectedBoth };
}

const cases = Number(process.argv[2] ?? 30000);
const t0 = Date.now();
unit();
const r = fuzz(cases);
console.log(`unit tests + ${cases} random patterns × 6 inputs = ${r.compared} exec() and ${r.compared} test() comparisons against V8`);
console.log(`  ${r.matched} matched, ${r.compared - r.matched} no-match, ${r.rejectedBoth} patterns rejected by both engines`);
console.log(`  ${failures === 0 ? 'ALL AGREE' : failures + ' DISAGREEMENTS'}  (${((Date.now() - t0) / 1000).toFixed(1)} s, seed ${process.env.SEED ?? 20261111})`);
process.exit(failures ? 1 : 0);
