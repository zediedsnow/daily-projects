<?php
declare(strict_types=1);

namespace Acorn;

final class Cli
{
    private ?Repo $repo = null;
    private string $out = '';

    public function __construct(private string $cwd) {}

    private function repo(): Repo { return $this->repo ??= Repo::discover($this->cwd); }
    private function p(string $s): void { $this->out .= $s; if (strlen($this->out) > 65536) $this->flush(); }
    /** print with ANSI colors, stripped when stdout is not a terminal */
    private function pc(string $s): void { $this->p(stream_isatty(STDOUT) ? $s : preg_replace('/\033\[[0-9;]*m/', '', $s)); }
    public function flush(): void
    {
        if (@fwrite(STDOUT, $this->out) === false) exit(0); // reader went away (e.g. `| head`)
        $this->out = '';
    }

    public function run(array $argv): int
    {
        $cmd = array_shift($argv) ?? 'help';
        $method = 'cmd' . str_replace('-', '', ucwords($cmd, '-'));
        if (!method_exists($this, $method)) {
            fwrite(STDERR, "acorn: '$cmd' is not a acorn command. See 'acorn help'.\n");
            return 1;
        }
        try {
            $rc = $this->$method($argv);
            $this->flush();
            return $rc ?? 0;
        } catch (AcornError $e) {
            $this->flush();
            fwrite(STDERR, 'fatal: ' . $e->getMessage() . "\n");
            return 128;
        }
    }

    /** Path given on the command line -> repository-relative path. */
    private function rel(string $p): string
    {
        $root = $this->repo()->root;
        $abs = str_starts_with($p, '/') ? $p : $this->cwd . '/' . $p;
        $parts = [];
        foreach (explode('/', $abs) as $seg) {
            if ($seg === '' || $seg === '.') continue;
            if ($seg === '..') array_pop($parts); else $parts[] = $seg;
        }
        $abs = '/' . implode('/', $parts);
        if ($abs === $root) return '';
        if (!str_starts_with($abs, $root . '/')) throw new AcornError("'$p' is outside repository");
        return substr($abs, strlen($root) + 1);
    }

    // ------------------------------------------------------------ plumbing

    public function cmdHelp(array $a): int
    {
        $this->p(<<<TXT
        usage: acorn <command> [<args>]

          init [dir]                 create an empty repository
          add <path>...              stage files (directories recurse; deletions too)
          rm [--cached] <path>...    remove files from the index (and worktree)
          status [--porcelain]       show staged, unstaged and untracked changes
          diff [--cached] [--numstat] [<rev> [<rev>]]
          commit -m <msg>            record the index as a new commit
          log [--oneline] [-n N] [--format=..] [<rev>]
          show [<rev>]               commit header + patch
          branch [-d] [<name> [<start>]]
          checkout [-b] <branch|commit>
          tag <name> [<rev>]
          merge-base <a> <b>
          rev-parse <rev>  |  cat-file (-t|-s|-p) <obj>  |  hash-object [-w] <file>
          ls-files [-s]  |  ls-tree [-r] <tree-ish>  |  write-tree
          verify-pack                check every packfile: checksums, CRCs, SHA-1s, delta chains

        TXT);
        return 0;
    }

    public function cmdInit(array $a): int
    {
        $quiet = in_array('-q', $a, true);
        $dir = array_values(array_filter($a, fn($x) => $x !== '-q'))[0] ?? '.';
        $path = str_starts_with($dir, '/') ? $dir : $this->cwd . '/' . $dir;
        $existed = is_dir("$path/.git");
        $r = Repo::init($path);
        if (!$quiet) $this->p(($existed ? 'Reinitialized existing' : 'Initialized empty') . " Git repository in {$r->gitDir}/\n");
        return 0;
    }

    public function cmdHashObject(array $a): int
    {
        $write = in_array('-w', $a, true);
        $type = 'blob';
        $files = [];
        for ($i = 0; $i < count($a); $i++) {
            if ($a[$i] === '-w') continue;
            if ($a[$i] === '-t') { $type = $a[++$i]; continue; }
            $files[] = $a[$i];
        }
        foreach ($files as $f) {
            $data = $f === '--stdin' ? stream_get_contents(STDIN) : file_get_contents($f);
            $this->p(($write ? $this->repo()->writeObject($type, $data) : Repo::hashObject($type, $data)) . "\n");
        }
        return 0;
    }

    public function cmdCatFile(array $a): int
    {
        $r = $this->repo();
        if (($a[0] ?? '') === '--batch') { // same wire format as `git cat-file --batch`
            while (($line = fgets(STDIN)) !== false) {
                $sha = trim($line);
                if ($sha === '') continue;
                [$type, $data] = $r->readObject($sha);
                $this->p("$sha $type " . strlen($data) . "\n" . $data . "\n");
            }
            return 0;
        }
        [$flag, $rev] = count($a) === 2 ? $a : ['-p', $a[0] ?? ''];
        $sha = $r->revParse($rev);
        [$type, $data] = $r->readObject($sha);
        match ($flag) {
            '-t' => $this->p("$type\n"),
            '-s' => $this->p(strlen($data) . "\n"),
            '-e' => null,
            '-p' => $type === 'tree' ? $this->printTree($sha, false, '') : $this->p($data),
            default => throw new AcornError("unknown option $flag"),
        };
        return 0;
    }

    private function printTree(string $sha, bool $recursive, string $prefix): void
    {
        foreach ($this->repo()->parseTree($sha) as $e) {
            $mode = str_pad($e['mode'], 6, '0', STR_PAD_LEFT);
            $type = match ($mode) { '040000' => 'tree', '160000' => 'commit', default => 'blob' };
            if ($recursive && $type === 'tree') { $this->printTree($e['sha'], true, $prefix . $e['name'] . '/'); continue; }
            $this->p("$mode $type {$e['sha']}\t" . Diff::quote($prefix . $e['name']) . "\n");
        }
    }

    public function cmdLsTree(array $a): int
    {
        $rec = in_array('-r', $a, true);
        $rev = array_values(array_filter($a, fn($x) => $x !== '-r'))[0] ?? 'HEAD';
        $this->printTree($this->repo()->treeOf($this->repo()->revParse($rev)), $rec, '');
        return 0;
    }

    public function cmdLsFiles(array $a): int
    {
        $idx = new Index($this->repo());
        $paths = array_map('strval', array_keys($idx->entries));
        sort($paths, SORT_STRING);
        foreach ($paths as $p) {
            $e = $idx->entries[$p];
            $this->p((in_array('-s', $a, true) ? "{$e['mode']} {$e['sha']} 0\t" : '') . Diff::quote($p) . "\n");
        }
        return 0;
    }

    public function cmdWriteTree(array $a): int
    {
        $this->p($this->repo()->writeTreeFromMap((new Index($this->repo()))->asMap()) . "\n");
        return 0;
    }

    public function cmdRevParse(array $a): int
    {
        foreach ($a as $rev) $this->p($this->repo()->revParse($rev) . "\n");
        return 0;
    }

    public function cmdVerifyPack(array $a): int
    {
        $r = $this->repo();
        if (!$r->packs()) { $this->p("no packfiles\n"); return 0; }
        foreach ($r->packs() as $p) {
            $t0 = microtime(true);
            $s = $p->verify($r);
            ksort($s['types']);
            $types = implode(', ', array_map(fn($k, $v) => "$v {$k}s", array_keys($s['types']), $s['types']));
            $this->p(sprintf("%s: ok\n  %d objects (%s)\n  %d deltified (%d ofs-delta, %d ref-delta), longest chain %d\n  verified in %.2fs\n",
                basename($p->packPath), $s['objects'], $types, $s['deltas'], $s['ofs'], $s['ref'], $s['maxChain'], microtime(true) - $t0));
        }
        return 0;
    }

    // ------------------------------------------------------------ staging

    public function cmdAdd(array $a): int
    {
        $r = $this->repo();
        $idx = new Index($r);
        if (!$a) throw new AcornError('Nothing specified, nothing added.');
        foreach ($a as $spec) {
            if ($spec === '-A' || $spec === '--all') $spec = $r->root;
            $rel = $this->rel($spec);
            $full = $rel === '' ? $r->root : $r->root . '/' . $rel;
            $matched = false;
            if (is_link($full) || is_file($full)) { $idx->add($rel); $matched = true; }
            elseif (is_dir($full)) {
                foreach (Worktree::files($r->root, $rel) as $f) $idx->add($f);
                $matched = true;
            }
            // stage deletions under the pathspec
            foreach (array_keys($idx->entries) as $p) {
                $p = (string)$p;
                if (($rel === '' || $p === $rel || str_starts_with($p, $rel . '/')) && !is_link($r->root . "/$p") && !is_file($r->root . "/$p")) {
                    unset($idx->entries[$p]);
                    $matched = true;
                }
            }
            if (!$matched) throw new AcornError("pathspec '$spec' did not match any files");
        }
        $idx->save();
        return 0;
    }

    public function cmdRm(array $a): int
    {
        $r = $this->repo();
        $idx = new Index($r);
        $cached = in_array('--cached', $a, true);
        foreach (array_filter($a, fn($x) => $x !== '--cached') as $spec) {
            $rel = $this->rel($spec);
            if (!isset($idx->entries[$rel])) throw new AcornError("pathspec '$spec' did not match any files");
            unset($idx->entries[$rel]);
            if (!$cached && (is_file("{$r->root}/$rel") || is_link("{$r->root}/$rel"))) {
                unlink("{$r->root}/$rel");
                $this->pruneDirs(dirname("{$r->root}/$rel"));
            }
            $this->p("rm '$rel'\n");
        }
        $idx->save();
        return 0;
    }

    private function pruneDirs(string $dir): void
    {
        $root = $this->repo()->root;
        while ($dir !== $root && str_starts_with($dir, $root) && is_dir($dir) && count(scandir($dir)) === 2) {
            rmdir($dir);
            $dir = dirname($dir);
        }
    }

    // ------------------------------------------------------------ status & diff

    private function headMap(): array
    {
        $h = $this->repo()->headCommit();
        return $h === null ? [] : $this->repo()->flattenTree($this->repo()->treeOf($h));
    }

    private static function kind(string $mode): string { return $mode === '120000' ? 'l' : ($mode === '160000' ? 'g' : 'f'); }

    /** @return array{staged:array, unstaged:array, untracked:list<string>} */
    private function collectStatus(Index $idx): array
    {
        $r = $this->repo();
        $head = $this->headMap();
        $index = $idx->asMap();
        $staged = [];
        foreach ($index as $p => [$mode, $sha]) {
            if (!isset($head[$p])) $staged[$p] = 'A';
            elseif ($head[$p][1] !== $sha || $head[$p][0] !== $mode) {
                $staged[$p] = self::kind($head[$p][0]) !== self::kind($mode) ? 'T' : 'M';
            }
        }
        foreach ($head as $p => $_) if (!isset($index[(string)$p])) $staged[(string)$p] = 'D';
        $unstaged = [];
        foreach ($index as $p => [$mode]) {
            if ($mode === '160000') continue; // submodules: not descended into
            $st = $idx->worktreeState((string)$p);
            if ($st === null) continue;
            $unstaged[$p] = $st[1] === null ? 'D' : (self::kind($st[0]) !== self::kind($mode) ? 'T' : 'M');
        }
        // untracked: collapse to the shallowest directory with no tracked content
        $trackedDirs = [];
        foreach ($index as $p => $_) {
            for ($d = dirname((string)$p); $d !== '.'; $d = dirname($d)) $trackedDirs[$d] = true;
        }
        $untracked = [];
        foreach (Worktree::files($r->root) as $f) {
            if (isset($index[$f])) continue;
            $show = $f;
            $parts = explode('/', $f);
            $acc = '';
            for ($i = 0; $i < count($parts) - 1; $i++) {
                $acc = $acc === '' ? $parts[$i] : "$acc/{$parts[$i]}";
                if (!isset($trackedDirs[$acc])) { $show = "$acc/"; break; }
            }
            $untracked[$show] = true;
        }
        $untracked = array_map('strval', array_keys($untracked));
        sort($untracked, SORT_STRING);
        return ['staged' => $staged, 'unstaged' => $unstaged, 'untracked' => $untracked];
    }

    public function cmdStatus(array $a): int
    {
        $r = $this->repo();
        $idx = new Index($r);
        $s = $this->collectStatus($idx);
        $paths = array_map('strval', array_keys($s['staged'] + $s['unstaged']));
        sort($paths, SORT_STRING);
        if (in_array('--porcelain', $a, true) || in_array('-s', $a, true) || in_array('--short', $a, true)) {
            foreach ($paths as $p) {
                $this->p(($s['staged'][$p] ?? ' ') . ($s['unstaged'][$p] ?? ' ') . ' ' . Diff::quote($p, true) . "\n");
            }
            foreach ($s['untracked'] as $u) $this->p('?? ' . Diff::quote($u, true) . "\n");
            return 0;
        }
        $t = $r->headTarget();
        $this->p($t !== null ? 'On branch ' . preg_replace('#^refs/heads/#', '', $t) . "\n" : 'HEAD detached at ' . substr((string)$r->headCommit(), 0, 7) . "\n");
        if ($r->headCommit() === null) $this->p("\nNo commits yet\n");
        $names = ['A' => 'new file:   ', 'M' => 'modified:   ', 'D' => 'deleted:    ', 'T' => 'typechange: '];
        $section = function (string $title, string $color, array $map) use ($paths, $names) {
            $rows = array_filter($paths, fn($p) => isset($map[$p]));
            if (!$rows) return;
            $this->p("\n$title\n");
            foreach ($rows as $p) $this->pc("\t$color" . $names[$map[$p]] . Diff::quote($p) . "\033[m\n");
        };
        $section('Changes to be committed:', "\033[32m", $s['staged']);
        $section('Changes not staged for commit:', "\033[31m", $s['unstaged']);
        if ($s['untracked']) {
            $this->p("\nUntracked files:\n");
            foreach ($s['untracked'] as $u) $this->pc("\t\033[31m" . Diff::quote($u) . "\033[m\n");
        }
        if (!$paths && !$s['untracked']) $this->p("nothing to commit, working tree clean\n");
        return 0;
    }

    /** Diff two path => [mode, sha] maps; $wt marks the new side as live worktree files. */
    private function diffMaps(array $old, array $new, bool $numstat, ?callable $newContent = null): array
    {
        $r = $this->repo();
        $paths = array_map('strval', array_keys($old + $new));
        sort($paths, SORT_STRING);
        $blob = fn(string $sha) => $r->readTyped($sha, 'blob');
        $content = fn(array $e) => $e[0] === '160000' ? "Subproject commit {$e[1]}\n" : $blob($e[1]);
        $text = '';
        $totals = [0, 0, 0];
        foreach ($paths as $p) {
            $o = $old[$p] ?? null;
            $n = $new[$p] ?? null;
            if ($o && $n && $o[0] === $n[0] && $o[1] === $n[1]) continue;
            $oc = $o ? [$o[0], $o[1], $content($o)] : null;
            $nc = $n ? [$n[0], $n[1], $newContent && $n[0] !== '160000' ? $newContent($p) : $content($n)] : null;
            // a file <-> symlink change is shown as a deletion plus an addition
            $pieces = ($oc && $nc && self::kind($oc[0]) !== self::kind($nc[0])) ? [[$oc, null], [null, $nc]] : [[$oc, $nc]];
            foreach ($pieces as [$x, $y]) {
                [$patch, $add, $del] = Diff::filePatch($p, $x, $y);
                $bin = Diff::isBinary($x[2] ?? '') || Diff::isBinary($y[2] ?? '');
                if ($numstat) $text .= ($bin ? "-\t-" : "$add\t$del") . "\t" . Diff::quote($p) . "\n";
                else $text .= $patch;
                $totals[0]++; $totals[1] += $add; $totals[2] += $del;
            }
        }
        return [$text, $totals];
    }

    public function cmdDiff(array $a): int
    {
        $r = $this->repo();
        $numstat = in_array('--numstat', $a, true);
        $cached = in_array('--cached', $a, true) || in_array('--staged', $a, true);
        $revs = array_values(array_filter($a, fn($x) => !str_starts_with($x, '--')));
        $idx = new Index($r);
        if (count($revs) === 2) {
            [$text] = $this->diffMaps($r->flattenTree($r->treeOf($r->revParse($revs[0]))), $r->flattenTree($r->treeOf($r->revParse($revs[1]))), $numstat);
        } elseif ($cached) {
            $old = $revs ? $r->flattenTree($r->treeOf($r->revParse($revs[0]))) : $this->headMap();
            [$text] = $this->diffMaps($old, $idx->asMap(), $numstat);
        } else {
            $old = $revs ? $r->flattenTree($r->treeOf($r->revParse($revs[0]))) : $idx->asMap();
            // the worktree side: tracked paths as they exist on disk right now
            $new = [];
            $cache = [];
            foreach ($idx->asMap() + ($revs ? $old : []) as $p => $_) {
                $p = (string)$p;
                $full = "{$r->root}/$p";
                $st = @lstat($full);
                if ($st === false || (is_dir($full) && !is_link($full))) continue;
                [$mode, $content] = Worktree::read($full, $st);
                $cache[$p] = $content;
                $new[$p] = [$mode, Repo::hashObject('blob', $content)];
            }
            [$text] = $this->diffMaps($old, $new, $numstat, fn($p) => $cache[$p]);
        }
        $this->p($text);
        return 0;
    }

    // ------------------------------------------------------------ history

    private function ident(string $role): string
    {
        $r = $this->repo();
        $R = strtoupper($role);
        $name = getenv("GIT_{$R}_NAME") ?: ($r->config('user.name') ?? 'Acorn User');
        $email = getenv("GIT_{$R}_EMAIL") ?: ($r->config('user.email') ?? 'acorn@localhost');
        $date = getenv("GIT_{$R}_DATE") ?: '';
        if (preg_match('/^@?(\d+)(?:\s+([+-]\d{4}))?$/', trim($date), $m)) {
            $when = $m[1] . ' ' . ($m[2] ?? '+0000');
        } else {
            $off = (int)date('Z');
            $when = time() . ' ' . ($off < 0 ? '-' : '+') . sprintf('%02d%02d', intdiv(abs($off), 3600), intdiv(abs($off) % 3600, 60));
        }
        return "$name <$email> $when";
    }

    /** git's "whitespace" cleanup for -m messages. */
    private static function cleanMessage(string $msg): string
    {
        $lines = array_map('rtrim', explode("\n", $msg));
        $out = [];
        foreach ($lines as $l) {
            if ($l === '' && (!$out || end($out) === '')) continue;
            $out[] = $l;
        }
        while ($out && end($out) === '') array_pop($out);
        return $out ? implode("\n", $out) . "\n" : '';
    }

    public function cmdCommit(array $a): int
    {
        $r = $this->repo();
        $msgs = [];
        for ($i = 0; $i < count($a); $i++) {
            if ($a[$i] === '-m') $msgs[] = $a[++$i] ?? '';
            elseif (str_starts_with($a[$i], '-m')) $msgs[] = substr($a[$i], 2);
            elseif ($a[$i] === '-a') $this->cmdAddTracked();
        }
        $msg = self::cleanMessage(implode("\n\n", $msgs));
        if ($msg === '') throw new AcornError('Aborting commit due to empty commit message.');
        $idx = new Index($r);
        $tree = $r->writeTreeFromMap($idx->asMap());
        $parent = $r->headCommit();
        $parentTree = $parent ? $r->treeOf($parent) : null;
        if ($tree === $parentTree || ($parent === null && !$idx->entries)) {
            $this->p("nothing to commit, working tree clean\n");
            return 1;
        }
        $body = "tree $tree\n" . ($parent ? "parent $parent\n" : '')
            . 'author ' . $this->ident('author') . "\n"
            . 'committer ' . $this->ident('committer') . "\n\n" . $msg;
        $sha = $r->writeObject('commit', $body);
        $target = $r->headTarget();
        if ($target !== null) $r->updateRef($target, $sha);
        else file_put_contents($r->gitDir . '/HEAD', "$sha\n");
        $branch = $target !== null ? preg_replace('#^refs/heads/#', '', $target) : 'detached HEAD';
        [, $t] = $this->diffMaps($parentTree ? $r->flattenTree($parentTree) : [], $idx->asMap(), true);
        $this->p("[$branch" . ($parent ? '' : ' (root-commit)') . ' ' . substr($sha, 0, 7) . '] ' . strtok($msg, "\n") . "\n");
        $this->p(sprintf(" %d file%s changed, %d insertion%s(+), %d deletion%s(-)\n",
            $t[0], $t[0] === 1 ? '' : 's', $t[1], $t[1] === 1 ? '' : 's', $t[2], $t[2] === 1 ? '' : 's'));
        return 0;
    }

    private function cmdAddTracked(): void
    {
        $r = $this->repo();
        $idx = new Index($r);
        foreach (array_keys($idx->entries) as $p) {
            $p = (string)$p;
            $st = $idx->worktreeState($p);
            if ($st === null) continue;
            if ($st[1] === null) unset($idx->entries[$p]); else $idx->add($p);
        }
        $idx->save();
    }

    private static function fmtDate(string $ident): array
    {
        preg_match('/^(.*) <(.*)> (\d+) ([+-])(\d\d)(\d\d)$/', $ident, $m);
        $off = ($m[4] === '-' ? -1 : 1) * ((int)$m[5] * 3600 + (int)$m[6] * 60);
        return ['name' => $m[1], 'email' => $m[2], 'ts' => (int)$m[3],
                'date' => gmdate('D M j H:i:s Y', (int)$m[3] + $off) . " {$m[4]}{$m[5]}{$m[6]}"];
    }

    /** Commits reachable from $starts, newest committer date first (like git log). */
    private function walk(array $starts): \Generator
    {
        $r = $this->repo();
        $seen = [];
        $heap = new \SplPriorityQueue();
        $seq = PHP_INT_MAX;
        $push = function (string $sha) use (&$seen, $heap, &$seq, $r) {
            if (isset($seen[$sha])) return;
            $seen[$sha] = true;
            $c = $r->parseCommit($sha);
            $heap->insert([$sha, $c], [self::fmtDate($c['committer'])['ts'], $seq--]);
        };
        foreach ($starts as $s) $push($s);
        while (!$heap->isEmpty()) {
            [$sha, $c] = $heap->extract();
            yield $sha => $c;
            foreach ($c['parents'] as $p) $push($p);
        }
    }

    public function cmdLog(array $a): int
    {
        $r = $this->repo();
        $oneline = false; $limit = PHP_INT_MAX; $format = null; $revs = []; $patch = false;
        for ($i = 0; $i < count($a); $i++) {
            $x = $a[$i];
            if ($x === '--oneline') $oneline = true;
            elseif ($x === '-p' || $x === '--patch') $patch = true;
            elseif ($x === '-n') $limit = (int)$a[++$i];
            elseif (preg_match('/^-(\d+)$/', $x, $m)) $limit = (int)$m[1];
            elseif (preg_match('/^--(?:format|pretty)=(?:format:|tformat:)?(.*)$/s', $x, $m)) $format = $m[1];
            else $revs[] = $x;
        }
        $starts = $revs ? array_map(fn($x) => $r->peelToCommit($r->revParse($x)), $revs) : array_filter([$r->headCommit()]);
        if (!$starts) throw new AcornError("your current branch does not have any commits yet");
        $n = 0;
        foreach ($this->walk($starts) as $sha => $c) {
            if ($n++ >= $limit) break;
            if ($format !== null) { $this->p($this->expandFormat($format, $sha, $c) . "\n"); continue; }
            if ($oneline) { $this->p(substr($sha, 0, 7) . ' ' . strtok($c['message'], "\n") . "\n"); continue; }
            if ($n > 1) $this->p("\n");
            $this->printCommitHeader($sha, $c);
            if ($patch) $this->p("\n" . $this->commitPatch($c));
        }
        return 0;
    }

    private function printCommitHeader(string $sha, array $c): void
    {
        $au = self::fmtDate($c['author']);
        $this->pc("\033[33mcommit $sha\033[m\n");
        if (count($c['parents']) > 1) $this->p('Merge: ' . implode(' ', array_map(fn($p) => substr($p, 0, 7), $c['parents'])) . "\n");
        $this->p("Author: {$au['name']} <{$au['email']}>\nDate:   {$au['date']}\n\n");
        foreach (explode("\n", rtrim($c['message'], "\n")) as $l) $this->p(($l === '' ? '' : '    ' . $l) . "\n");
    }

    private function commitPatch(array $c): string
    {
        $r = $this->repo();
        $old = $c['parents'] ? $r->flattenTree($r->treeOf($c['parents'][0])) : [];
        return $this->diffMaps($old, $r->flattenTree($c['tree']), false)[0];
    }

    private function expandFormat(string $f, string $sha, array $c): string
    {
        $au = self::fmtDate($c['author']);
        return preg_replace_callback('/%(H|h|T|P|an|ae|ad|at|s|n|%)/', fn($m) => match ($m[1]) {
            'H' => $sha, 'h' => substr($sha, 0, 7), 'T' => $c['tree'], 'P' => implode(' ', $c['parents']),
            'an' => $au['name'], 'ae' => $au['email'], 'ad' => $au['date'], 'at' => (string)$au['ts'],
            's' => strtok($c['message'], "\n") ?: '', 'n' => "\n", '%' => '%',
        }, $f);
    }

    public function cmdShow(array $a): int
    {
        $r = $this->repo();
        $sha = $r->peelToCommit($r->revParse($a[0] ?? 'HEAD'));
        $c = $r->parseCommit($sha);
        $this->printCommitHeader($sha, $c);
        $patch = $this->commitPatch($c);
        if ($patch !== '') $this->p("\n" . $patch);
        return 0;
    }

    public function cmdMergeBase(array $a): int
    {
        $r = $this->repo();
        [$x, $y] = [$r->revParse($a[0]), $r->revParse($a[1])];
        $ancX = [];
        foreach ($this->walk([$x]) as $s => $_) $ancX[$s] = true;
        // first common ancestor in date order that is not an ancestor of another candidate
        $cands = [];
        foreach ($this->walk([$y]) as $s => $_) if (isset($ancX[$s])) $cands[] = $s;
        foreach ($cands as $cand) {
            $redundant = false;
            foreach ($cands as $other) {
                if ($other === $cand) continue;
                foreach ($this->walk([$other]) as $s => $_) if ($s === $cand) { $redundant = true; break 2; }
            }
            if (!$redundant) { $this->p("$cand\n"); return 0; }
        }
        return 1;
    }

    // ------------------------------------------------------------ branches

    public function cmdBranch(array $a): int
    {
        $r = $this->repo();
        if (!$a) {
            $cur = $r->headTarget();
            foreach ($r->branches() as $name => $_) {
                $this->pc(($cur === "refs/heads/$name" ? "* \033[32m$name\033[m" : "  $name") . "\n");
            }
            return 0;
        }
        if ($a[0] === '-d' || $a[0] === '-D') {
            $name = $a[1];
            if ($r->headTarget() === "refs/heads/$name") throw new AcornError("cannot delete branch '$name' used by HEAD");
            $f = $r->gitDir . "/refs/heads/$name";
            if (!is_file($f)) throw new AcornError("branch '$name' not found");
            $sha = trim(file_get_contents($f));
            unlink($f);
            $this->p("Deleted branch $name (was " . substr($sha, 0, 7) . ").\n");
            return 0;
        }
        $name = $a[0];
        if (!preg_match('#^(?!-)(?!.*\.\.)(?!.*//)[A-Za-z0-9._/-]+(?<!\.lock)(?<![/.])$#', $name)) throw new AcornError("'$name' is not a valid branch name");
        if ($r->readRef("refs/heads/$name") !== null) throw new AcornError("a branch named '$name' already exists");
        $r->updateRef("refs/heads/$name", $r->peelToCommit($r->revParse($a[1] ?? 'HEAD')));
        return 0;
    }

    public function cmdTag(array $a): int
    {
        $r = $this->repo();
        if (!$a) {
            foreach (glob($r->gitDir . '/refs/tags/*') ?: [] as $t) $this->p(basename($t) . "\n");
            return 0;
        }
        if ($r->readRef("refs/tags/{$a[0]}") !== null) throw new AcornError("tag '{$a[0]}' already exists");
        $r->updateRef("refs/tags/{$a[0]}", $r->revParse($a[1] ?? 'HEAD'));
        return 0;
    }

    public function cmdCheckout(array $a): int
    {
        $r = $this->repo();
        $create = false;
        if (($a[0] ?? '') === '-b') { $create = true; array_shift($a); }
        $target = $a[0] ?? throw new AcornError('checkout: missing branch or commit');
        if ($create) {
            $this->cmdBranch([$target, $a[1] ?? 'HEAD']);
            file_put_contents($r->gitDir . '/HEAD', "ref: refs/heads/$target\n");
            $this->p("Switched to a new branch '$target'\n");
            return 0;
        }
        $isBranch = $r->readRef("refs/heads/$target") !== null;
        $sha = $r->peelToCommit($r->revParse($target));
        $idx = new Index($r);
        $s = $this->collectStatus($idx);
        $want = $r->flattenTree($r->treeOf($sha));
        $have = $idx->asMap();
        // refuse to clobber local changes to files that differ between the two trees
        foreach ($s['staged'] + $s['unstaged'] as $p => $_) {
            $p = (string)$p;
            if (($want[$p] ?? null) !== ($this->headMap()[$p] ?? null)) {
                throw new AcornError("Your local changes to '$p' would be overwritten by checkout.\nPlease commit your changes or stash them before you switch branches.");
            }
        }
        foreach ($want as $p => $_) {
            $p = (string)$p;
            if (!isset($have[$p]) && (is_file("{$r->root}/$p") || is_link("{$r->root}/$p"))) {
                throw new AcornError("The untracked working tree file '$p' would be overwritten by checkout.");
            }
        }
        foreach ($have as $p => $_) {
            $p = (string)$p;
            if (!isset($want[$p])) {
                @unlink("{$r->root}/$p");
                $this->pruneDirs(dirname("{$r->root}/$p"));
                unset($idx->entries[$p]);
            }
        }
        foreach ($want as $p => [$mode, $blob]) {
            $p = (string)$p;
            if (isset($have[$p]) && $have[$p] === [$mode, $blob] && !isset($s['unstaged'][$p])) continue;
            $full = "{$r->root}/$p";
            if ($mode === '160000') { // submodule: just leave an empty directory, like git
                if (!is_dir($full)) mkdir($full, 0777, true);
                $idx->entries[$p] = Index::statEntry(lstat($full), $mode, $blob);
                continue;
            }
            if (is_dir($full) && !is_link($full)) throw new AcornError("directory '$p' is in the way");
            Worktree::write($full, $mode, $r->readTyped($blob, 'blob'));
            clearstatcache(true, $full);
            $idx->entries[$p] = Index::statEntry(lstat($full), $mode, $blob);
        }
        $idx->save();
        if ($isBranch) {
            file_put_contents($r->gitDir . '/HEAD', "ref: refs/heads/$target\n");
            $this->p("Switched to branch '$target'\n");
        } else {
            file_put_contents($r->gitDir . '/HEAD', "$sha\n");
            $this->p('HEAD is now at ' . substr($sha, 0, 7) . ' ' . strtok($r->parseCommit($sha)['message'], "\n") . "\n");
        }
        return 0;
    }
}
