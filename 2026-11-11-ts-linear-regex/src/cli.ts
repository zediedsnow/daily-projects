#!/usr/bin/env node
import * as fs from 'fs';
import { spawnSync } from 'child_process';
import { Regex, RegexSyntaxError } from './regex';

const USAGE = `linrex — a regex engine that cannot be ReDoS'd

usage:
  linrex grep [-i] [-v] [-c] [-n] [-o] [--color] PATTERN [FILE...]   search lines (stdin if no file)
  linrex match [-i|-m|-s...] PATTERN TEXT                          show every match and its groups
  linrex replace [-i] PATTERN REPLACEMENT [FILE]                   like sed s///g ($1, $<name>, $&)
  linrex dump PATTERN [FLAGS]                                      print the compiled NFA program
  linrex bench                                                     race against V8's backtracking RegExp
`;

function die(msg: string): never { process.stderr.write(msg + '\n'); process.exit(2); }

function compileOrDie(p: string, flags: string): Regex {
  try { return new Regex(p, flags); }
  catch (e) { die(e instanceof RegexSyntaxError ? 'linrex: syntax error: ' + e.message : String(e)); }
}

function parseOpts(args: string[], allowed: string) {
  const opts = new Set<string>();
  const rest: string[] = [];
  for (const a of args) {
    if (a === '--color') opts.add('color');
    else if (/^-[a-z]+$/.test(a) && rest.length === 0) {
      for (const ch of a.slice(1)) { if (!allowed.includes(ch)) die(`unknown option -${ch}\n\n` + USAGE); opts.add(ch); }
    } else rest.push(a);
  }
  return { opts, rest };
}

function readInput(file?: string): string {
  try { return fs.readFileSync(file ?? 0, 'utf8'); }
  catch (e) { die(`linrex: ${file ?? 'stdin'}: ${(e as NodeJS.ErrnoException).code ?? e}`); }
}

function grep(args: string[]) {
  const { opts, rest } = parseOpts(args, 'ivcno');
  if (rest.length < 1) die(USAGE);
  const re = compileOrDie(rest[0], opts.has('i') ? 'i' : '');
  const files = rest.slice(1);
  const color = opts.has('color') || process.stdout.isTTY;
  let total = 0;
  const out: string[] = [];
  for (const f of files.length ? files : [undefined]) {
    const lines = readInput(f).split('\n');
    if (lines[lines.length - 1] === '') lines.pop();
    let count = 0;
    lines.forEach((line, k) => {
      const hit = re.test(line); // lazy DFA: one table lookup per char
      if (hit === opts.has('v')) return;
      count++;
      if (opts.has('c')) return;
      const prefix = (files.length > 1 ? (color ? `\x1b[35m${f}\x1b[0m:` : `${f}:`) : '') +
                     (opts.has('n') ? (color ? `\x1b[32m${k + 1}\x1b[0m:` : `${k + 1}:`) : '');
      if (opts.has('o') && !opts.has('v')) {
        for (const m of re.matchAll(line)) if (m.text) out.push(prefix + (color ? `\x1b[1;31m${m.text}\x1b[0m` : m.text));
      } else if (color && !opts.has('v')) {
        out.push(prefix + re.replaceAll(line, m => m.text ? `\x1b[1;31m${m.text}\x1b[0m` : ''));
      } else out.push(prefix + line);
    });
    if (opts.has('c')) out.push((files.length > 1 ? `${f}:` : '') + count);
    total += count;
  }
  if (out.length) process.stdout.write(out.join('\n') + '\n');
  process.exit(total ? 0 : 1);
}

function match(args: string[]) {
  const { opts, rest } = parseOpts(args, 'ims');
  if (rest.length !== 2) die(USAGE);
  const re = compileOrDie(rest[0], [...opts].join(''));
  let n = 0;
  for (const m of re.matchAll(rest[1])) {
    n++;
    console.log(`match ${n} at [${m.index}, ${m.end}): ${JSON.stringify(m.text)}`);
    const names = new Map([...re.groupNames].map(([k, v]) => [v, k]));
    for (let g = 1; g < m.groups.length; g++)
      console.log(`  group ${g}${names.has(g) ? ` <${names.get(g)}>` : ''}: ${m.groups[g] === undefined ? '(unset)' : JSON.stringify(m.groups[g])}`);
  }
  if (!n) { console.log('no match'); process.exit(1); }
}

function replace(args: string[]) {
  const { opts, rest } = parseOpts(args, 'ims');
  if (rest.length < 2) die(USAGE);
  const re = compileOrDie(rest[0], [...opts].join(''));
  process.stdout.write(re.replaceAll(readInput(rest[2]), rest[1]));
}

function dump(args: string[]) {
  if (args.length < 1) die(USAGE);
  const re = compileOrDie(args[0], args[1] ?? '');
  console.log(`/${re.source}/${re.flags}  →  ${re.program.insts.length} instructions, ${re.program.ncaps / 2 - 1} capture groups`);
  console.log(re.disassemble());
}

// ----------------------------------------------------------------- bench
function timeNative(pattern: string, input: string, budgetMs: number): number | null {
  const code = `const re=new RegExp(${JSON.stringify(pattern)});const s=${JSON.stringify(input)};` +
    `const t=process.hrtime.bigint();re.test(s);console.log(Number(process.hrtime.bigint()-t)/1e6)`;
  const r = spawnSync(process.execPath, ['-e', code], { timeout: budgetMs, encoding: 'utf8' });
  if (r.error || r.status !== 0 || r.signal) return null;
  return parseFloat(r.stdout);
}
function timeMine(pattern: string, input: string): { ms: number; hit: boolean; states: number } {
  const t = process.hrtime.bigint();
  const re = new Regex(pattern);
  const hit = re.test(input);
  return { ms: Number(process.hrtime.bigint() - t) / 1e6, hit, states: re.stats.dfa.states };
}
const fmt = (ms: number | null, budget: number) =>
  ms === null ? `> ${budget / 1000} s ✗`.padStart(12) : (ms < 1 ? ms.toFixed(3) : ms < 100 ? ms.toFixed(1) : ms.toFixed(0)).padStart(9) + ' ms';

function bench() {
  const budget = 5000;
  const cases: [string, (n: number) => string, (n: number) => string, number[]][] = [
    ['^(a|a)*$  vs  a{n}b', () => '^(a|a)*$', n => 'a'.repeat(n) + 'b', [10, 16, 20, 24, 28, 5000]],
    ['(x+x+)+y  vs  x{n}', () => '(x+x+)+y', n => 'x'.repeat(n), [10, 16, 20, 24, 28, 5000]],
    ['^(\\w+\\s?)*$  vs  a{n}!', () => '^(\\w+\\s?)*$', n => 'a'.repeat(n) + '!', [10, 16, 20, 24, 28, 5000]],
    ['(.*a){n}  vs  a{2n}b', n => `(.*a){${n}}`, n => 'a'.repeat(2 * n) + 'b', [4, 8, 12, 16, 20, 24, 28]],
  ];
  console.log(`Pathological patterns (V8 runs in a child process, killed after ${budget / 1000} s)\n`);
  console.log('pattern                       n     V8 RegExp        linrex   DFA states');
  console.log('─'.repeat(74));
  for (const [name, pat, inp, ns] of cases) {
    for (const n of ns) {
      const p = pat(n), s = inp(n);
      const native = timeNative(p, s, budget);
      const mine = timeMine(p, s);
      console.log(`${name.padEnd(26)} ${String(n).padStart(5)}  ${fmt(native, budget)}  ${fmt(mine.ms, budget)}   ${String(mine.states).padStart(6)}`);
    }
    console.log();
  }

  // Ordinary workload: honest throughput numbers on a synthetic log file.
  const words = ['GET', 'POST', '/api/users', '/static/app.js', 'ok', 'cache', 'miss', 'user=42', 'latency', 'ms', 'db', 'pool'];
  let seed = 7;
  const rnd = (n: number) => ((seed = (Math.imul(seed, 1103515245) + 12345) >>> 0) >>> 8) % n;
  const lines: string[] = [];
  for (let k = 0; k < 100_000; k++) {
    let l = `2026-11-11T08:${String(rnd(60)).padStart(2, '0')}:${String(rnd(60)).padStart(2, '0')}Z ${['INFO', 'INFO', 'INFO', 'DEBUG', 'WARN', 'ERROR'][rnd(6)]}`;
    for (let w = 0; w < 6 + rnd(6); w++) l += ' ' + words[rnd(words.length)];
    if (rnd(50) === 0) l += ' timeout after ' + rnd(9000) + 'ms';
    lines.push(l);
  }
  const text = lines.join('\n');
  const mb = text.length / 1e6;
  console.log(`Ordinary workload: grep ${lines.length.toLocaleString()} log lines (${mb.toFixed(1)} MB), test() per line\n`);
  console.log('pattern                                      hits     V8 RegExp     linrex DFA');
  console.log('─'.repeat(78));
  for (const p of ['\\b(ERROR|WARN)\\b.*timeout after \\d+ms', 'user=\\d+ (cache|db|pool)', '^\\S+Z (INFO|DEBUG) GET /api']) {
    const nat = new RegExp(p), mine = new Regex(p);
    let t = process.hrtime.bigint(), h1 = 0;
    for (const l of lines) if (nat.test(l)) h1++;
    const tn = Number(process.hrtime.bigint() - t) / 1e6;
    t = process.hrtime.bigint(); let h2 = 0;
    for (const l of lines) if (mine.test(l)) h2++;
    const tm = Number(process.hrtime.bigint() - t) / 1e6;
    if (h1 !== h2) die(`hit counts differ for /${p}/: ${h1} vs ${h2}`);
    console.log(`${p.padEnd(42)} ${String(h1).padStart(6)}  ${(mb / tn * 1000).toFixed(0).padStart(6)} MB/s   ${(mb / tm * 1000).toFixed(0).padStart(6)} MB/s   (${mine.stats.dfa.states} states)`);
  }
}

const [cmd, ...args] = process.argv.slice(2);
switch (cmd) {
  case 'grep': grep(args); break;
  case 'match': match(args); break;
  case 'replace': replace(args); break;
  case 'dump': dump(args); break;
  case 'bench': bench(); break;
  default: process.stdout.write(USAGE); process.exit(cmd ? 2 : 0);
}
