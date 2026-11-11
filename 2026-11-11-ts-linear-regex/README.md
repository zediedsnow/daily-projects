# linrex — a regex engine that can't be ReDoS'd

`linrex` is a regular-expression engine written from scratch in TypeScript that **always runs in
time linear in the input**, whatever the pattern. It parses JavaScript regex syntax, compiles it to a
Thompson NFA, and runs it two ways: a **Pike VM** for exact matches and capture groups, and a
**lazy DFA** (built on demand and cached) for fast yes/no searches. It ships as a library
(`Regex` class with `test`, `exec`, `matchAll`, `replaceAll`) and a small `grep`/`sed`-style CLI.

~1,200 lines, zero runtime dependencies.

## Why it's interesting

JavaScript's built-in `RegExp`, like the engines in Python, Java, Ruby and PCRE, is a *backtracking*
matcher. On some patterns it tries exponentially many ways to split the input before giving up.
`/^(\w+\s?)*$/` checked against 28 `a`s and a `!` takes V8 more than 5 seconds. This is
**ReDoS** (regular-expression denial of service), and it has taken down Stack Overflow (2016) and
Cloudflare (2019).

`linrex` uses the approach Ken Thompson described in 1968, later revived by Russ Cox and used in RE2,
Go and Rust: it simulates every possible path *at once*, one input character at a time, and never
goes back. The same pattern on 5,000 characters finishes in 0.2 ms.

The hard part is matching the **exact semantics of JavaScript's backtracking engine** without
backtracking: leftmost-first alternation, lazy quantifiers, capture groups that reset on every loop
iteration, and ECMAScript's rule that an optional loop iteration may not match the empty string.
A differential fuzzer runs 180,000 random pattern/input pairs against V8, and both the match position
and every capture group have to come out identical.

## Build & run

Needs Node 18+.

```sh
npm install          # dev-only: typescript + @types/node
npm run build        # tsc → dist/
npm test             # unit tests + differential fuzzing against V8 (SEED=n to vary)
npm run bench        # the race below

node dist/cli.js match '(?<user>\w+)@(?<host>[\w.]+)\.(com|org)' 'mail ann@example.com or bob@lists.gnu.org'
node dist/cli.js grep -n -i '\bcat\b' notes.txt          # also -v -c -o --color; stdin if no file
echo "2026-11-11" | node dist/cli.js replace '(?<y>\d{4})-(\d\d)-(\d\d)' '$3/$2/$<y>'
node dist/cli.js dump '(a|b)*?c{1,3}'                    # show the compiled NFA program
```

As a library:

```ts
import { Regex } from './src/regex';
const re = new Regex('(?<key>\\w+)=(?<val>\\d+)', 'i');   // flags: i, m, s
re.test('x=1');                                          // lazy DFA
re.exec('a b=42')?.named;                                // { key: 'b', val: '42' }
[...re.matchAll('a=1 b=2')].map(m => m.text);            // ['a=1', 'b=2']
```

## Supported syntax

Literals and escapes (`\n \t \xHH \uHHHH \cX`), `.`, classes `[a-z] [^…] \d \w \s \D \W \S`,
groups `(…)`, `(?:…)`, `(?<name>…)`, alternation, `* + ? {m} {m,} {m,n}` and their lazy `?` forms,
anchors `^ $ \b \B`, and flags `i` (with ECMAScript case folding over all of UTF-16), `m`, `s`.

Backreferences and lookaround are **rejected** with an explanation, because they're exactly the
features that can't run in linear time. Matching with backreferences is NP-hard.

```
$ linrex match '(\w+)\1' x
linrex: syntax error: backreferences are not supported (matching them is NP-hard) at position 6
  /(\w+)\1/
         ^
```

## Sample output

`npm run bench` (Node 22, one core). V8 runs in a child process that is killed after 5 s:

```
pattern                       n     V8 RegExp        linrex   DFA states
──────────────────────────────────────────────────────────────────────────
^(a|a)*$  vs  a{n}b           16        4.3 ms      0.157 ms        3
^(a|a)*$  vs  a{n}b           20       63.4 ms      0.336 ms        3
^(a|a)*$  vs  a{n}b           24       1036 ms      0.270 ms        3
^(a|a)*$  vs  a{n}b           28       > 5 s ✗      0.175 ms        3
^(a|a)*$  vs  a{n}b         5000       > 5 s ✗      0.676 ms        3

(x+x+)+y  vs  x{n}            20       53.6 ms      0.298 ms        6
(x+x+)+y  vs  x{n}            24        714 ms      0.189 ms        6
(x+x+)+y  vs  x{n}            28       > 5 s ✗      0.225 ms        6
(x+x+)+y  vs  x{n}          5000       > 5 s ✗      0.287 ms        6

^(\w+\s?)*$  vs  a{n}!        20       56.0 ms      0.193 ms        4
^(\w+\s?)*$  vs  a{n}!        24        914 ms      0.145 ms        4
^(\w+\s?)*$  vs  a{n}!        28       > 5 s ✗      0.166 ms        4
^(\w+\s?)*$  vs  a{n}!      5000       > 5 s ✗      0.219 ms        4

(.*a){n}  vs  a{2n}b          16        4.4 ms      0.371 ms       17
(.*a){n}  vs  a{2n}b          20       66.7 ms      0.532 ms       21
(.*a){n}  vs  a{2n}b          24       1072 ms      0.631 ms       25
(.*a){n}  vs  a{2n}b          28       > 5 s ✗      0.713 ms       29

Ordinary workload: grep 100,000 log lines (7.6 MB), test() per line

pattern                                      hits     V8 RegExp     linrex DFA
──────────────────────────────────────────────────────────────────────────────
\b(ERROR|WARN)\b.*timeout after \d+ms         671     151 MB/s       80 MB/s   (31 states)
user=\d+ (cache|db|pool)                    13505     532 MB/s       89 MB/s   (20 states)
^\S+Z (INFO|DEBUG) GET /api                   437     935 MB/s      198 MB/s   (24 states)
```

On ordinary patterns, V8's JIT-compiled native code is 2–6× faster than a lazy DFA written in
JavaScript. The guarantee you get in exchange is that no input can make `linrex` slow.

The fuzzer:

```
unit tests + 30000 random patterns × 6 inputs = 180000 exec() and 180000 test() comparisons against V8
  89126 matched, 90874 no-match, 0 patterns rejected by both engines
  ALL AGREE  (6.9 s, seed 20261111)
```

The compiled program for `/(a|b)*?c{1,3}/` (`split x, y` tries `x` first):

```
 0  save   0
 1  split  10, 2      ← lazy *?: prefer leaving the loop
 2  reset  2..3       ← JS clears group 1 at the start of each iteration
 3  save   2
 4  split  5, 7
 5  char   'a'
 6  jmp    8
 7  char   'b'
 8  save   3
 9  jmp    1
10  char   'c'
11  split  12, 15     ← c{1,3} becomes c(c(c)?)?
12  char   'c'
13  split  14, 15
14  char   'c'
15  save   1
16  match
```

## How it works

| file | role |
|------|------|
| `src/parse.ts` | Recursive-descent parser for ECMAScript (non-unicode) syntax, including Annex B quirks like a literal `{` and `[]`/`[^]`. Error messages point at the offending column. |
| `src/charset.ts` | Character classes as sorted UTF-16 range lists with complement, binary-search membership, and `i`-flag closure using the spec's `Canonicalize` (upper-case, never map non-ASCII to ASCII). |
| `src/compile.ts` | Thompson construction into `char / split / jmp / save / assert / reset / mark / progress / match` instructions. `split` targets are ordered, which encodes greedy vs. lazy and alternation priority. Counted repeats are unrolled as nested optionals to avoid quadratic ambiguity. |
| `src/vm.ts` | **PikeVM**: keeps the live threads in priority order and advances them all together, one character at a time. A thread that reaches `match` cuts off every lower-priority thread, which gives leftmost-first (Perl/JS) semantics rather than POSIX leftmost-longest. **LazyDFA**: subset construction done on demand. Each DFA state is a set of NFA pcs plus the context bits that assertions need (at start, previous char is a word char, previous char is a newline). Transitions are memoised in a 256-entry table plus a map. If the cache passes 10,000 states it is flushed and rebuilt, so memory stays bounded. |
| `src/regex.ts` | The public `Regex` class. |
| `src/fuzz.ts` | Unit tests plus the differential fuzzer against V8. |

**Two subtle problems the fuzzer found:**

1. **Empty iterations.** ECMA-262 says an optional loop iteration that consumes nothing fails, so
   `/(a*)?/` on `""` leaves group 1 *undefined*, not `""`. `linrex` compiles a `mark` at the start of
   each optional iteration of a nullable loop body and a `progress` check at the end. The check kills
   the thread if the position hasn't moved.
2. **Deduplication.** A Pike VM normally keeps only the first (highest-priority) thread to reach each
   pc. With progress registers that isn't enough: in `/(\w*?|c)*/` a lower-priority path could claim a
   pc first and block a later iteration that should have won. The fix keys the epsilon-closure's
   visited set on *(pc, which loop registers were set at this position)*. Once a thread consumes a
   character, no register can equal a future position, so threads at `char` instructions are still
   deduplicated by pc alone. The work per character stays O(program size), and the fuzzer has agreed
   with V8 on every seed tried since.

**Complexity:** `exec` is O(n × m) for input length n and program size m, with captures. `test` is
amortised O(n) table lookups once the DFA is warm. A first-character prefilter lets `exec` skip
straight to positions where a match could start.
