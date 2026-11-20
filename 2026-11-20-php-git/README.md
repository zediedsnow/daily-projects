# acorn — git, reimplemented in plain PHP

`acorn` is a working git client written from scratch in about 1,700 lines of PHP 8.3, with no
Composer packages and no shelling out to git. It reads and writes **real `.git` directories**:
real git can work on repositories acorn creates, and acorn can work on repositories git creates,
including `git gc --aggressive` packfiles full of delta chains.

```
$ acorn init -q
$ acorn add .
$ acorn commit -m "Fibonacci, iteratively"
[main (root-commit) dfcfd08] Fibonacci, iteratively
 2 files changed, 8 insertions(+), 0 deletions(-)
$ acorn status --porcelain
 M fib.py
?? notes.txt
$ acorn diff
diff --git a/fib.py b/fib.py
index 49f58e3..2a8afac 100644
--- a/fib.py
+++ b/fib.py
@@ -1,7 +1,7 @@
+from functools import cache
+
+@cache
 def fib(n):
-    a, b = 0, 1
-    for _ in range(n):
-        a, b = b, a + b
-    return a
+    return n if n < 2 else fib(n - 1) + fib(n - 2)
 
 print(fib(10))
$ acorn commit -a -m "Fibonacci, recursively with memoisation"
[main d139fdc] Fibonacci, recursively with memoisation
 1 file changed, 4 insertions(+), 4 deletions(-)
$ acorn log --oneline
d139fdc Fibonacci, recursively with memoisation
dfcfd08 Fibonacci, iteratively

# now ask real git what it thinks of acorn's repository
$ git fsck --strict
$ git log --format='%h %an %s'
d139fdc Ada Lovelace Fibonacci, recursively with memoisation
dfcfd08 Ada Lovelace Fibonacci, iteratively
$ git status --short
?? notes.txt
```

Given the same author, dates and message, acorn's commit hashes are identical to git's, so the two
tools produce the same history down to the last byte. (That patch is also byte-identical to
`git show`.)

## Why it's interesting

Git looks simple from the outside, a content-addressed store of blobs, trees and commits. Matching
it byte for byte means getting a lot of details right:

- **Tree ordering.** Tree entries are sorted as if directory names ended in `/`, so `a.b` comes
  before the directory `a` but after the file `a`. Modes are written without leading zeros, and
  names and SHA-1s are stored as raw bytes.
- **The index (`.git/index`).** This is a binary `DIRC` file: ten 32-bit stat fields per entry,
  flags, NUL padding to 8-byte boundaries, and a trailing SHA-1. Version 4 compresses each path
  against the previous one using git's "offset varint". acorn reads v2, v3 and v4 and writes v2.
- **Racy git.** If a file was modified in the same second the index was written, its cached stat
  data can't be trusted. acorn re-hashes those entries, as git does.
- **Packfiles.** An object may be stored whole, or as an `OFS_DELTA` (base at a relative offset,
  using git's quirky `+1` varint) or a `REF_DELTA` (base named by SHA-1), with copy/insert delta
  opcodes. These chain: the jq repository below has chains 22 deltas deep. The pack index is a
  256-entry fan-out table, sorted names, CRC32s, 31-bit offsets, and a 64-bit overflow table.
- **Status semantics.** `git status --porcelain` shows staged and unstaged changes (`MM`, `AD`,
  typechanges `T`), and collapses untracked directories to the shallowest one with no tracked
  content (`?? newdir/`). Paths with spaces, quotes or non-ASCII bytes are C-quoted, and short
  status also quotes spaces.
- **Diff.** acorn uses Myers' O(ND) algorithm in linear space (the "middle snake" bisection),
  with git's hunk rules: 3 context lines, merging hunks separated by six or fewer lines,
  `\ No newline at end of file`, `-0,0` ranges, and the default *funcname* after `@@`.

### acorn's diffs are shorter than `git diff --minimal`

Myers' algorithm finds a *shortest* edit script, and the fuzzer checks acorn's against a
dynamic-programming LCS on 36,000 random sequence pairs. Git's xdiff is not always minimal, even
with `--minimal`. Its preprocessing step discards lines that occur "too often" before the search
runs, and that can leave a longer script. On real code this shows up:

| file (jq 1.6 → 1.7) | true minimum (DP LCS) | **acorn** | `git diff --minimal` |
|---|---|---|---|
| compile-ios.sh | 166 | **166** | 208 |
| Makefile.am | 156 | **156** | 160 |
| configure.ac | 125 | **125** | 127 |
| src/jv_aux.c | 206 | **206** | 208 |

Across jq 1.5→1.6, 1.6→1.7 and 1.7→1.8.0, every one of acorn's 647 per-file edit scripts is valid,
none is longer than git's, and 16 are strictly shorter. 200 of the 227 file patches for
1.6→1.7 are byte-identical to `git diff`. The rest differ only in where an ambiguous change
"slides" to, because git also runs an indent heuristic. Every acorn patch applies cleanly with
`git apply`.

## Commands

```
init [dir]                     ls-files [-s]          cat-file (-t|-s|-p|--batch) <obj>
add <path>... | -A             ls-tree [-r] <rev>     hash-object [-w] [-t type] <file>
rm [--cached] <path>...        write-tree             rev-parse <rev>   (HEAD~2, main^2, abc12, tags...)
status [--porcelain]           log [--oneline] [-n N] [-p] [--format=%H %h %s %an %ad ...] [<rev>...]
diff [--cached] [--numstat] [<rev> [<rev>]]           show [<rev>]
commit [-a] -m <msg>           branch [-d] [<name> [<start>]]       tag <name> [<rev>]
checkout [-b] <branch|commit>  merge-base <a> <b>     verify-pack
```

`verify-pack` checks everything git's pack format can promise. It verifies the pack and index
trailer checksums, the CRC32 of every raw entry, and the SHA-1 of every reconstructed object, and
it reports delta statistics.

Not implemented: networking (clone/fetch/push), merging, rebasing, `.gitignore`, and writing
packfiles. Acorn reads packs but writes only loose objects.

## How to run

You need PHP ≥ 8.1 with the bundled `zlib` extension, which nearly every PHP build includes.

```sh
./acorn help
./acorn init myrepo && cd myrepo && echo hi > f && ../acorn add f && ../acorn commit -m first
./acorn -C /path/to/any/git/repo log --oneline -n 5
```

Identity comes from `GIT_AUTHOR_NAME`/`EMAIL`/`DATE` (and the `COMMITTER_` variants), then
`user.name` and `user.email` in `.git/config`.

## Testing: a differential fuzzer against real git

```sh
php tests/fuzz.php [iterations] [seed]     # needs `git` on PATH
```

`tests/fuzz.php` builds random repositories and requires acorn's answers to match the real git
CLI. The random trees include nested directories, executable bits, symlinks, binary files, empty
files, files without a final newline, CRLF lines, and names like `x y`, `café`, `q"uote`, `123`
and `.hidden`. For each run it:

1. Builds the same tree in an acorn repo and in a git repo, then commits 3–9 rounds of random
   edits in both. The **commit hashes must be equal** every round. `write-tree` and
   `ls-files -s` must match, and `git fsck --strict` must accept acorn's repository.
2. Mutates the worktree (edits, deletions, new files and directories, chmod, file→symlink) and
   stages a random subset. `status --porcelain` must be **byte-identical** to git's. `diff` and
   `diff --cached` must touch the same files with the same net line change, and must never be
   longer than `git diff --minimal`. Finally, `acorn diff` piped into `git apply` must rebuild
   the worktree exactly.
3. Uses git to add a side branch and a `--no-ff` merge. acorn's `log` order and `merge-base`
   must match git's, and after `acorn checkout` git must report a clean tree.
4. Runs `git gc --aggressive` (OFS deltas plus packed-refs), then repacks with
   `pack.allowDeltaBaseOffset=false` (REF deltas), then converts the index to v4. After each
   step, `acorn cat-file --batch` over **every object** must equal `git cat-file --batch` byte
   for byte, and `verify-pack`, `log` and `status` must agree.

A 120-iteration run:

```
$ php tests/fuzz.php 120 7
  myers: 36000 random sequence pairs checked against DP LCS (0.6s)
........................................................................................................................
  acorn diff | git apply reproduces worktree          623 checks
  checkout back is clean too                          120 checks
  checkout leaves clean tree for git                  120 checks
  commit-hash == git                                  703 checks
  diff --cached numstat <= git (per file)             703 checks
  diff numstat <= git --minimal (per file)            703 checks
  git fsck --strict on acorn repo                     120 checks
  log == git log                                      120 checks
  log over merges == git                              120 checks
  log through packed-refs == git                      120 checks
  ls-files -s == git                                  703 checks
  merge-base == git                                   120 checks
  myers-minimal-vs-LCS                              36000 checks
  read OFS_DELTA packs == git cat-file --batch        120 checks
  read REF_DELTA packs == git cat-file --batch        120 checks
  read index v4 == git ls-files -s                    120 checks
  status --porcelain == git                           703 checks
  status on packed repo == git                        120 checks
  verify-pack (ofs)                                   120 checks
  verify-pack (ref)                                   120 checks
  write-tree == git                                   703 checks
  (informational) acorn diff byte-identical to git diff: 610 of 703 patches
PASSED: 42401 checks, 0 failures (seed 7)
```

To check that the fuzzer can actually catch bugs, I planted one: a tree-entry name corrupted only
for long directory names. The fuzzer flagged it within five runs, through both `commit-hash` and
`write-tree`.

### On a real repository

acorn was also run on a fresh clone of [jq](https://github.com/jqlang/jq): 12,111 objects,
7,870 of them deltified, longest chain 22.

```
$ acorn verify-pack
pack-bb395b81e714608a55317fee04ac6028c0ea9656.pack: ok
  12111 objects (4870 blobs, 2035 commits, 4 tags, 5202 trees)
  7870 deltified (7870 ofs-delta, 0 ref-delta), longest chain 22
  verified in 0.73s
```

`acorn cat-file --batch` over all 12,111 objects produced the same SHA-1 as git's output, in
1.3 s against git's 0.3 s. `log` across 1,987 commits and `status` were identical to git's, and
`diff` between release tags gave the results in the table above.

## How it's organised

| file | what's in it |
|---|---|
| `src/Repo.php` | object database (loose zlib objects, atomic writes), `Pack` (v2 idx fan-out search, OFS/REF delta resolution with a base cache, `verify`), tree read/write in git order, commit parsing, refs + `packed-refs`, revision syntax |
| `src/Index.php` | `DIRC` v2/v3/v4 reader, v2 writer, stat-cache + racy-git change detection, worktree helpers (symlinks, exec bits) |
| `src/Diff.php` | linear-space Myers with middle-snake bisection, unified hunks with git's merge/context rules and funcname, C-style path quoting, `diff --git` headers (new/deleted/mode/binary) |
| `src/Commands.php` | the porcelain: status, add/rm, commit (stat summary, message cleanup), date-ordered log walk via a priority queue, checkout with overwrite protection, branches, tags, merge-base |
| `tests/fuzz.php` | the differential fuzzer above |
