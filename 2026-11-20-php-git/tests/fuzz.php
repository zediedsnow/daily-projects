<?php
declare(strict_types=1);

/**
 * Differential fuzzer: drives acorn and the real git CLI over the same random
 * repositories and demands byte-identical answers.
 *
 *   php tests/fuzz.php [iterations] [seed]
 */
require __DIR__ . '/../src/Repo.php';
require __DIR__ . '/../src/Index.php';
require __DIR__ . '/../src/Diff.php';

$ITER = (int)($argv[1] ?? 20);
$SEED = (int)($argv[2] ?? 1);
mt_srand($SEED);
$ACORN = realpath(__DIR__ . '/../acorn');
$WORK = sys_get_temp_dir() . '/acorn-fuzz-' . getmypid();
@mkdir($WORK, 0777, true);
putenv('GIT_CONFIG_NOSYSTEM=1');
putenv("HOME=$WORK");           // no user ~/.gitconfig
putenv('GIT_AUTHOR_NAME=Ada Lovelace');
putenv('GIT_AUTHOR_EMAIL=ada@example.org');
putenv('GIT_COMMITTER_NAME=Charles Babbage');
putenv('GIT_COMMITTER_EMAIL=cb@example.org');
file_put_contents("$WORK/.gitconfig", "[init]\n\tdefaultBranch = main\n[gc]\n\tauto = 0\n[core]\n\tautocrlf = false\n");

$stats = [];
$identical = [0, 0]; // informational: patches byte-identical to `git diff`
$fail = 0;
function check(string $name, bool $ok, string $detail = ''): void
{
    global $stats, $fail;
    $stats[$name] = ($stats[$name] ?? 0) + 1;
    if (!$ok) {
        $fail++;
        fwrite(STDERR, "\nFAIL [$name] $detail\n");
        if ($fail > 5) exit(1);
    }
}

function sh(string $cmd, string $cwd, ?string $stdin = null): string
{
    $p = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $cwd);
    fwrite($pipes[0], $stdin ?? '');
    fclose($pipes[0]);
    $out = stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    $rc = proc_close($p);
    if ($rc !== 0 && !str_contains($cmd, '|| true')) throw new RuntimeException("`$cmd` failed ($rc) in $cwd:\n$err$out");
    return $out;
}
function acorn(string $args, string $cwd, ?string $stdin = null): string { global $ACORN; return sh("php $ACORN $args", $cwd, $stdin); }
function git(string $args, string $cwd, ?string $stdin = null): string { return sh("git $args", $cwd, $stdin); }

// ------------------------------------------------------------- random trees

const WORDS = ['alpha', 'beta', 'gamma', 'delta', '{', '}', 'return x;', '', '    indent', 'int main()', 'foo(bar)',
               '# comment', 'end', 'tab\there', 'x = 1', 'y = 2', 'the quick brown fox', '// TODO', 'crlf' . "\r"];
const NAMES = ['a', 'b', 'c', 'main.c', 'util.php', 'README', 'x y', 'café', '123', '7', 'Ünï', 'd-1', '.hidden', 'z.txt',
               'a.b', 'a-b', 'a_b', 'notes', 'Makefile', 'q"uote', 'back\\slash'];

function rnd(array $a) { return $a[mt_rand(0, count($a) - 1)]; }

function textContent(): string
{
    $n = mt_rand(0, 3) === 0 ? mt_rand(0, 3) : mt_rand(5, 60);
    $s = '';
    for ($i = 0; $i < $n; $i++) $s .= rnd(WORDS) . (mt_rand(0, 4) === 0 ? ' ' . mt_rand(0, 9) : '') . "\n";
    if ($s !== '' && mt_rand(0, 5) === 0) $s = substr($s, 0, -1); // no newline at EOF
    return $s;
}

/** A file tree as path => [kind, content, exec]; kind f(ile) or l(ink). */
function randomTree(): array
{
    $t = ['seed.txt' => ['f', textContent(), false]];
    $dirs = [''];
    for ($i = 0, $n = mt_rand(3, 25); $i < $n; $i++) {
        $dir = rnd($dirs);
        if (mt_rand(0, 3) === 0 && substr_count($dir, '/') < 3) {
            $d = ($dir === '' ? '' : "$dir/") . rnd(NAMES) . 'd';
            if (!isset($t[$d])) $dirs[] = $d;
            continue;
        }
        $p = ($dir === '' ? '' : "$dir/") . rnd(NAMES);
        if (in_array($p, $dirs, true)) continue;
        $r = mt_rand(0, 12);
        if ($r === 0) $t[$p] = ['l', rnd(['a', '../b', 'nowhere/x', 'x y', 'café'])];
        elseif ($r === 1 && $dir === '') $t["bin-$i.dat"] = ['f', random_bytes(mt_rand(1, 300)) . "\0", false];
        else $t[$p] = ['f', textContent(), mt_rand(0, 4) === 0];
    }
    return $t;
}

function writeTree(string $root, array $t): void
{
    foreach ($t as $p => $e) {
        $full = "$root/$p";
        if (!is_dir(dirname($full))) mkdir(dirname($full), 0777, true);
        if (is_link($full) || is_file($full)) unlink($full);
        if ($e[0] === 'l') symlink($e[1], $full);
        else { file_put_contents($full, $e[1]); chmod($full, $e[2] ? 0755 : 0644); }
    }
}

function editText(string $s): string
{
    $lines = $s === '' ? [] : preg_split('/(?<=\n)/', $s, -1, PREG_SPLIT_NO_EMPTY);
    for ($k = 0, $n = mt_rand(1, 6); $k < $n; $k++) {
        $pos = mt_rand(0, count($lines));
        switch (mt_rand(0, 3)) {
            case 0: array_splice($lines, $pos, 0, [rnd(WORDS) . "\n"]); break;
            case 1: array_splice($lines, $pos, mt_rand(1, 4)); break;
            case 2: if ($lines) $lines[min($pos, count($lines) - 1)] = rnd(WORDS) . " edited\n"; break;
            case 3: $block = []; for ($i = 0; $i < mt_rand(1, 8); $i++) $block[] = rnd(WORDS) . "\n";
                    array_splice($lines, $pos, 0, $block); break;
        }
    }
    $out = implode('', $lines);
    if ($out !== '' && mt_rand(0, 7) === 0) $out = str_ends_with($out, "\n") ? substr($out, 0, -1) : $out . "\n";
    return $out;
}

/**
 * Mutate a tree description (pure function of the RNG, so it can be replayed
 * on two directories). Returns [new tree, list of removed paths].
 */
function mutate(array $t, bool $typechanges): array
{
    $removed = [];
    $paths = array_map('strval', array_keys($t));
    for ($k = 0, $n = mt_rand(1, 6); $k < $n && $paths; $k++) {
        $p = rnd($paths);
        if (!isset($t[$p])) continue;
        $isBin = str_starts_with($p, 'bin-');
        switch (mt_rand(0, 9)) {
            case 0: case 1: case 2: case 3:
                if ($t[$p][0] === 'f' && !$isBin) $t[$p][1] = editText($t[$p][1]);
                break;
            case 4: if (!$isBin) { unset($t[$p]); $removed[] = $p; } break;
            case 5: if ($t[$p][0] === 'f') $t[$p][2] = !$t[$p][2]; break;
            case 6: case 7:
                $dir = dirname($p) === '.' ? '' : dirname($p) . '/';
                $np = $dir . rnd(NAMES) . (mt_rand(0, 1) ? '' : '_new');
                if (!isset($t[$np]) && !array_filter(array_keys($t), fn($x) => str_starts_with((string)$x, "$np/"))) $t[$np] = ['f', textContent(), false];
                break;
            case 8: if ($typechanges && $t[$p][0] === 'f' && !$isBin) $t[$p] = ['l', 'some/target']; break;
            case 9:
                $np = 'newdir' . mt_rand(0, 3) . '/' . rnd(NAMES);
                if (!isset($t[$np]) && !isset($t[dirname($np)])) $t[$np] = ['f', textContent(), false];
                break;
        }
    }
    return [$t, $removed];
}

function applyTree(string $root, array $old, array $new): void
{
    foreach ($old as $p => $_) {
        $p = (string)$p;
        if (!isset($new[$p])) {
            unlink("$root/$p");
            for ($d = dirname("$root/$p"); $d !== $root && count(scandir($d)) === 2; $d = dirname($d)) rmdir($d);
        }
    }
    $changed = [];
    foreach ($new as $p => $e) if (($old[$p] ?? null) !== $e) $changed[$p] = $e;
    writeTree($root, $changed);
}

/** acorn's edit script must never be longer than git's (it is provably minimal; xdiff's is not always). */
function notLonger(array $t, array $g): bool
{
    foreach ($t as $p => [$a, $d]) {
        if ($a + $d > $g[$p][0] + $g[$p][1]) return false;
        if ($a - $d !== $g[$p][0] - $g[$p][1]) return false; // net line delta is fixed by the files
    }
    return true;
}

function rmrf(string $d): void { if (is_dir($d)) sh('rm -rf ' . escapeshellarg($d), '/'); }

function setDate(int $t): void
{
    putenv("GIT_AUTHOR_DATE=@$t +0400");
    putenv("GIT_COMMITTER_DATE=@$t +0400");
}

function numstatMap(string $s): array
{
    $m = [];
    foreach (array_filter(explode("\n", $s)) as $l) {
        [$a, $d, $p] = explode("\t", $l, 3);
        $m[$p] = [($m[$p][0] ?? 0) + (int)$a, ($m[$p][1] ?? 0) + (int)$d];
    }
    ksort($m);
    return $m;
}

// =============================================================== 1. Myers vs LCS

$t0 = microtime(true);
for ($i = 0; $i < 3000 * max(1, intdiv($ITER, 10)); $i++) {
    $a = []; $b = [];
    for ($k = mt_rand(0, 14); $k > 0; $k--) $a[] = (string)mt_rand(0, 3);
    for ($k = mt_rand(0, 14); $k > 0; $k--) $b[] = (string)mt_rand(0, 3);
    $d = Acorn\Diff::lines($a, $b);
    // dynamic-programming LCS gives the true minimum edit distance
    $L = array_fill(0, count($a) + 1, array_fill(0, count($b) + 1, 0));
    for ($x = count($a) - 1; $x >= 0; $x--) for ($y = count($b) - 1; $y >= 0; $y--)
        $L[$x][$y] = $a[$x] === $b[$y] ? $L[$x + 1][$y + 1] + 1 : max($L[$x + 1][$y], $L[$x][$y + 1]);
    $minimal = count($d->delA) + count($d->insB) === count($a) + count($b) - 2 * $L[0][0];
    $kept = [];
    foreach ($a as $x => $v) if (!isset($d->delA[$x])) $kept[] = $v;
    $keptB = [];
    foreach ($b as $y => $v) if (!isset($d->insB[$y])) $keptB[] = $v;
    check('myers-minimal-vs-LCS', $minimal && $kept === $keptB, json_encode([$a, $b]));
}
printf("  myers: %d random sequence pairs checked against DP LCS (%.1fs)\n", $stats['myers-minimal-vs-LCS'], microtime(true) - $t0);

// =============================================================== 2. repo fuzz

for ($it = 0; $it < $ITER; $it++) {
    $T = "$WORK/t$it"; $G = "$WORK/g$it";
    rmrf($T); rmrf($G);
    mkdir($T); mkdir($G);
    acorn('init -q', $T);
    git('init -q', $G);
    $tree = randomTree();
    writeTree($T, $tree);
    writeTree($G, $tree);
    $date = 1700000000 + $it * 100000;
    $commits = mt_rand(3, 9);
    for ($c = 0; $c < $commits; $c++) {
        setDate($date += 3600);
        $msg = "commit $c of run $it\n\n  body line with trailing space   \n\n\nmore  ";
        acorn('add .', $T);
        sh("php $ACORN commit -m " . escapeshellarg($msg) . ' || true', $T);
        git('add -A', $G);
        git('commit -q -m ' . escapeshellarg($msg) . ' || true', $G);
        check('commit-hash == git', acorn('rev-parse HEAD', $T) === git('rev-parse HEAD', $G),
            "run $it commit $c\n" . git('log --stat', $G) . "\n--acorn--\n" . sh("git log --stat", $T));
        check('ls-files -s == git', acorn('ls-files -s', $T) === git('ls-files -s', $T), "run $it");
        check('write-tree == git', acorn('write-tree', $T) === git('write-tree', $G));

        // ---- status & diff differential on a mutated worktree
        [$mut] = mutate($tree, true);
        applyTree($T, $tree, $mut);
        if (mt_rand(0, 1)) { // stage a random subset
            foreach (array_keys($mut) as $p) if (mt_rand(0, 3) === 0) acorn('add ' . escapeshellarg((string)$p), $T);
        }
        $ts = acorn('status --porcelain', $T);
        $gs = git('status --porcelain --no-renames', $T);
        check('status --porcelain == git', $ts === $gs, "run $it\n--acorn--\n$ts--git--\n$gs");
        $tn = numstatMap(acorn('diff --numstat', $T));
        $gn = numstatMap(git('diff --numstat --minimal', $T));
        check('diff numstat <= git --minimal (per file)', array_keys($tn) === array_keys($gn) && notLonger($tn, $gn), "run $it\n" . json_encode($tn) . "\n" . json_encode($gn));
        $tc = numstatMap(acorn('diff --cached --numstat', $T));
        $gc = numstatMap(git('diff --cached --numstat --minimal', $T));
        check('diff --cached numstat <= git (per file)', array_keys($tc) === array_keys($gc) && notLonger($tc, $gc), "run $it\n" . json_encode($tc) . "\n" . json_encode($gc));
        // the patch must apply with `git apply` and reproduce the worktree exactly
        $patch = acorn('diff', $T);
        $GLOBALS['identical'][(int)($patch === git('diff', $T))]++;
        $A = "$WORK/apply$it";
        rmrf($A);
        git("checkout-index -a --prefix=$A/", $T);
        if ($patch !== '' && !str_contains($patch, 'Binary files')) {
            sh('git apply -', $A, $patch);
            $expect = [];
            foreach (explode("\0", rtrim(git('ls-files -z', $T), "\0")) as $p) {
                if ($p === '' || !(is_file("$T/$p") || is_link("$T/$p"))) continue;
                $expect[$p] = is_link("$T/$p") ? 'L:' . readlink("$T/$p") : (is_executable("$T/$p") ? 'X:' : 'F:') . file_get_contents("$T/$p");
            }
            $got = [];
            foreach ($expect as $p => $_) {
                $f = "$A/$p";
                $got[$p] = is_link($f) ? 'L:' . readlink($f) : (is_file($f) ? (is_executable($f) ? 'X:' : 'F:') . file_get_contents($f) : 'missing');
            }
            check('acorn diff | git apply reproduces worktree', $got === $expect, "run $it\n$patch");
        }
        rmrf($A);
        // put both repos on the same next state
        sh('git reset -q --hard && git clean -qfdx', $T);
        [$tree] = mutate($tree, false);
        applyTree($T, git_tree_state($T), $tree);
        applyTree($G, git_tree_state($G), $tree);
    }
    check('git fsck --strict on acorn repo', str_contains(sh('git fsck --strict 2>&1 && echo OK', $T), 'OK'));
    check('log == git log', acorn('log --format=%H%n%an%n%ad%n%s', $T) === git('log --format=%H%n%an%n%ad%n%s', $G));

    // ---- branches, merges and checkout (history written by git, walked by acorn)
    sh('git reset -q --hard && git clean -qfdx', $G);
    setDate($date += 3600);
    git('checkout -q -b side HEAD~1', $G);
    file_put_contents("$G/side-file", "side $it\n");
    git('add -A', $G); git('commit -q -m side', $G);
    setDate($date += 3600);
    git('checkout -q main', $G);
    git('merge -q --no-ff side -m merge', $G);
    check('merge-base == git', acorn('merge-base main side', $G) === git('merge-base main side', $G));
    check('log over merges == git', acorn('log --format=%H', $G) === git('log --format=%H', $G));
    acorn('checkout side', $G);
    check('checkout leaves clean tree for git', git('status --porcelain', $G) === '' && git('rev-parse HEAD', $G) === git('rev-parse side', $G));
    acorn('checkout main', $G);
    check('checkout back is clean too', git('status --porcelain', $G) === '' && git('symbolic-ref HEAD', $G) === "refs/heads/main\n");

    // ---- packfiles: OFS_DELTA (gc --aggressive), then REF_DELTA, packed-refs, index v4
    $all = fn() => git("cat-file --batch-all-objects --batch-check='%(objectname)'", $G);
    $before = git('cat-file --batch', $G, $all());
    git('gc -q --aggressive --prune=now', $G);
    check('read OFS_DELTA packs == git cat-file --batch', acorn('cat-file --batch', $G, $all()) === $before);
    check('verify-pack (ofs)', str_contains(acorn('verify-pack', $G), ': ok'));
    check('log through packed-refs == git', acorn('log --format=%H', $G) === git('log --format=%H', $G));
    git('-c pack.allowDeltaBaseOffset=false repack -q -a -d -f', $G);
    check('read REF_DELTA packs == git cat-file --batch', acorn('cat-file --batch', $G, $all()) === $before);
    $vp = acorn('verify-pack', $G);
    check('verify-pack (ref)', str_contains($vp, ': ok'), $vp);
    git('update-index --index-version 4', $G);
    check('read index v4 == git ls-files -s', acorn('ls-files -s', $G) === git('ls-files -s', $G));
    check('status on packed repo == git', acorn('status --porcelain', $G) === git('status --porcelain', $G));
    rmrf($T); rmrf($G);
    fprintf(STDERR, '.');
}

/** Describe what's on disk right now as a tree map (so applyTree can diff it). */
function git_tree_state(string $root): array
{
    $t = [];
    foreach (Acorn\Worktree::files($root) as $p) {
        $f = "$root/$p";
        $t[$p] = is_link($f) ? ['l', readlink($f)] : ['f', file_get_contents($f), is_executable($f)];
    }
    return $t;
}

echo "\n";
ksort($stats);
foreach ($stats as $k => $v) printf("  %-48s %6d checks\n", $k, $v);
printf("  (informational) acorn diff byte-identical to git diff: %d of %d patches\n", $identical[1], array_sum($identical));
printf("%s: %d checks, %d failures (seed %d)\n", $fail ? 'FAILED' : 'PASSED', array_sum($stats), $fail, $SEED);
rmrf($WORK);
exit($fail ? 1 : 0);
