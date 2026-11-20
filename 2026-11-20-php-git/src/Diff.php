<?php
declare(strict_types=1);

namespace Acorn;

/**
 * Myers' O(ND) diff in linear space (the "middle snake" divide and conquer
 * from the 1986 paper), producing a minimal edit script, plus git-style
 * unified patch output.
 */
final class Diff
{
    /** @var list<int> */ private array $a;
    /** @var list<int> */ private array $b;
    /** @var array<int,bool> */ public array $delA = [];
    /** @var array<int,bool> */ public array $insB = [];

    /**
     * Compute which lines of $a are deleted and which lines of $b inserted.
     * Lines are interned to integers so comparisons are O(1).
     */
    public static function lines(array $a, array $b): self
    {
        $ids = [];
        $d = new self();
        $d->a = array_map(function ($l) use (&$ids) { return $ids[$l] ??= count($ids); }, $a);
        $d->b = array_map(function ($l) use (&$ids) { return $ids[$l] ??= count($ids); }, $b);
        $d->compare(0, count($a), 0, count($b));
        return $d;
    }

    private function compare(int $a0, int $a1, int $b0, int $b1): void
    {
        // strip common prefix / suffix: cheap and makes the snake search smaller
        while ($a0 < $a1 && $b0 < $b1 && $this->a[$a0] === $this->b[$b0]) { $a0++; $b0++; }
        while ($a0 < $a1 && $b0 < $b1 && $this->a[$a1 - 1] === $this->b[$b1 - 1]) { $a1--; $b1--; }
        if ($a0 === $a1) { for ($j = $b0; $j < $b1; $j++) $this->insB[$j] = true; return; }
        if ($b0 === $b1) { for ($i = $a0; $i < $a1; $i++) $this->delA[$i] = true; return; }
        [$x, $y, $u, $v] = $this->middleSnake($a0, $a1, $b0, $b1);
        $this->compare($a0, $x, $b0, $y);
        $this->compare($u, $a1, $v, $b1);
    }

    /**
     * Run the forward and reverse greedy searches simultaneously until they
     * overlap; the overlapping diagonal run is part of some shortest edit path.
     * @return array{int,int,int,int} snake start (x,y) and end (u,v)
     */
    private function middleSnake(int $a0, int $a1, int $b0, int $b1): array
    {
        $n = $a1 - $a0; $m = $b1 - $b0;
        $delta = $n - $m;
        $odd = ($delta & 1) === 1;
        $max = intdiv($n + $m + 1, 2);
        $vf = [1 => 0];
        $vb = [1 => 0];
        $A = $this->a; $B = $this->b;
        for ($d = 0; $d <= $max; $d++) {
            for ($k = -$d; $k <= $d; $k += 2) { // forward
                if ($k === -$d || ($k !== $d && $vf[$k - 1] < $vf[$k + 1])) $x = $vf[$k + 1];
                else $x = $vf[$k - 1] + 1;
                $y = $x - $k;
                $sx = $x; $sy = $y;
                while ($x < $n && $y < $m && $A[$a0 + $x] === $B[$b0 + $y]) { $x++; $y++; }
                $vf[$k] = $x;
                if ($odd && $k - $delta >= -($d - 1) && $k - $delta <= $d - 1 && isset($vb[$delta - $k])
                    && $x + $vb[$delta - $k] >= $n) {
                    return [$a0 + $sx, $b0 + $sy, $a0 + $x, $b0 + $y];
                }
            }
            for ($k = -$d; $k <= $d; $k += 2) { // reverse (k measured from the end)
                if ($k === -$d || ($k !== $d && $vb[$k - 1] < $vb[$k + 1])) $x = $vb[$k + 1];
                else $x = $vb[$k - 1] + 1;
                $y = $x - $k;
                $sx = $x; $sy = $y;
                while ($x < $n && $y < $m && $A[$a1 - 1 - $x] === $B[$b1 - 1 - $y]) { $x++; $y++; }
                $vb[$k] = $x;
                if (!$odd && $delta - $k >= -$d && $delta - $k <= $d && isset($vf[$delta - $k])
                    && $x + $vf[$delta - $k] >= $n) {
                    return [$a1 - $x, $b1 - $y, $a1 - $sx, $b1 - $sy];
                }
            }
        }
        throw new \LogicException('unreachable: no middle snake');
    }

    /** Split blob content into lines that keep their "\n" (so a missing final newline is a difference). */
    public static function split(string $s): array
    {
        if ($s === '') return [];
        return preg_split('/(?<=\n)/', $s, -1, PREG_SPLIT_NO_EMPTY);
    }

    public static function isBinary(string $s): bool
    {
        return str_contains(substr($s, 0, 8000), "\0");
    }

    /**
     * Unified hunks with git's defaults: 3 lines of context, hunks merged when
     * separated by <= 6 unchanged lines, "funcname" context after the @@.
     * @return array{0:string,1:int,2:int} [text, added, removed]
     */
    public static function unified(string $old, string $new, int $ctx = 3): array
    {
        $a = self::split($old);
        $b = self::split($new);
        $d = self::lines($a, $b);
        // walk both sides producing an op list: ' ', '-', '+'
        $ops = [];
        $i = $j = 0;
        $na = count($a); $nb = count($b);
        while ($i < $na || $j < $nb) {
            if ($i < $na && isset($d->delA[$i])) { $ops[] = ['-', $i++, $j]; }
            elseif ($j < $nb && isset($d->insB[$j])) { $ops[] = ['+', $i, $j++]; }
            else { $ops[] = [' ', $i++, $j++]; }
        }
        $changes = [];
        foreach ($ops as $k => $op) if ($op[0] !== ' ') $changes[] = $k;
        if (!$changes) return ['', 0, 0];
        // group changes into hunks
        $groups = [];
        $start = $changes[0]; $end = $changes[0];
        foreach ($changes as $c) {
            if ($c - $end - 1 > 2 * $ctx) { $groups[] = [$start, $end]; $start = $c; }
            $end = $c;
        }
        $groups[] = [$start, $end];
        $out = '';
        $added = $removed = 0;
        foreach ($groups as [$s, $e]) {
            $s = max(0, $s - $ctx);
            $e = min(count($ops) - 1, $e + $ctx);
            $oldStart = $ops[$s][1]; $newStart = $ops[$s][2];
            $oc = $nc = 0;
            $body = '';
            for ($k = $s; $k <= $e; $k++) {
                [$t, $ii, $jj] = $ops[$k];
                $line = $t === '+' ? $b[$jj] : $a[$ii];
                if ($t !== '+') $oc++;
                if ($t !== '-') $nc++;
                if ($t === '+') $added++;
                if ($t === '-') $removed++;
                $body .= $t . $line;
                if (!str_ends_with($line, "\n")) $body .= "\n\\ No newline at end of file\n";
            }
            $hdr = '@@ -' . self::range($oldStart, $oc) . ' +' . self::range($newStart, $nc) . ' @@';
            $fn = self::funcname($a, $oldStart);
            $out .= $hdr . ($fn !== '' ? ' ' . $fn : '') . "\n" . $body;
        }
        return [$out, $added, $removed];
    }

    private static function range(int $start, int $count): string
    {
        if ($count === 1) return (string)($start + 1);
        return ($count === 0 ? $start : $start + 1) . ',' . $count;
    }

    /** git's default funcname: nearest preceding line starting with a letter, '_' or '$'. */
    private static function funcname(array $a, int $before): string
    {
        for ($i = $before - 1; $i >= 0; $i--) {
            $l = $a[$i];
            if ($l !== '' && (ctype_alpha($l[0]) || $l[0] === '_' || $l[0] === '$')) {
                return substr(rtrim($l), 0, 80);
            }
        }
        return '';
    }

    /** C-style quoting as git does for paths with special bytes (core.quotePath=true). */
    public static function quote(string $s, bool $quoteSpace = false): string
    {
        if (!preg_match($quoteSpace ? '/[\x00-\x20"\\\\\x7f-\xff]/' : '/[\x00-\x1f"\\\\\x7f-\xff]/', $s)) return $s;
        $map = ["\a" => '\a', "\b" => '\b', "\t" => '\t', "\n" => '\n', "\v" => '\v', "\f" => '\f', "\r" => '\r',
                '"' => '\"', '\\' => '\\\\'];
        $out = '"';
        for ($i = 0, $n = strlen($s); $i < $n; $i++) {
            $c = $s[$i];
            $o = ord($c);
            if (isset($map[$c])) $out .= $map[$c];
            elseif ($o < 0x20 || $o >= 0x7f) $out .= sprintf('\\%03o', $o);
            else $out .= $c;
        }
        return $out . '"';
    }

    /**
     * A complete "diff --git" section for one path. $old/$new are
     * [mode, sha, content] or null for creation/deletion.
     */
    public static function filePatch(string $path, ?array $old, ?array $new): array
    {
        $qa = self::quote("a/$path");
        $qb = self::quote("b/$path");
        $tab = str_contains($path, ' ') ? "\t" : '';
        $out = "diff --git $qa $qb\n";
        $abbr = fn(?array $x) => $x ? substr($x[1], 0, 7) : '0000000';
        if ($old === null) $out .= "new file mode {$new[0]}\n";
        elseif ($new === null) $out .= "deleted file mode {$old[0]}\n";
        elseif ($old[0] !== $new[0]) $out .= "old mode {$old[0]}\nnew mode {$new[0]}\n";
        if ($old !== null && $new !== null && $old[1] === $new[1]) return [$out, 0, 0]; // mode-only change
        $out .= 'index ' . $abbr($old) . '..' . $abbr($new);
        if ($old !== null && $new !== null && $old[0] === $new[0]) $out .= ' ' . $new[0];
        $out .= "\n";
        $oc = $old[2] ?? '';
        $nc = $new[2] ?? '';
        if (self::isBinary($oc) || self::isBinary($nc)) {
            return [$out . 'Binary files ' . ($old ? $qa : '/dev/null') . ' and ' . ($new ? $qb : '/dev/null') . " differ\n", 0, 0];
        }
        if ($oc === '' && $nc === '') return [$out, 0, 0];
        $out .= '--- ' . ($old ? $qa . $tab : '/dev/null') . "\n";
        $out .= '+++ ' . ($new ? $qb . $tab : '/dev/null') . "\n";
        [$hunks, $add, $del] = self::unified($oc, $nc);
        return [$out . $hunks, $add, $del];
    }
}
