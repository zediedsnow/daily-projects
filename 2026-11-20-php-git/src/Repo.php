<?php
declare(strict_types=1);

namespace Acorn;

final class AcornError extends \RuntimeException {}

/**
 * A git repository: the object database (loose objects + packfiles with
 * OFS/REF deltas), refs (loose + packed-refs) and revision parsing.
 */
final class Repo
{
    public string $root;
    public string $gitDir;
    /** @var Pack[]|null */
    private ?array $packs = null;
    /** @var array<string, array{string,string}> small cache of parsed objects */
    private array $cache = [];

    public function __construct(string $root)
    {
        $this->root = rtrim($root, '/');
        $this->gitDir = $this->root . '/.git';
    }

    public static function discover(string $start): self
    {
        $dir = realpath($start);
        while ($dir !== false) {
            if (is_dir("$dir/.git") && is_file("$dir/.git/HEAD")) return new self($dir);
            $parent = dirname($dir);
            if ($parent === $dir) break;
            $dir = $parent;
        }
        throw new AcornError('not a git repository (or any of the parent directories): .git');
    }

    public static function init(string $path, string $branch = 'main'): self
    {
        if (!is_dir($path)) mkdir($path, 0777, true);
        $repo = new self(realpath($path));
        $g = $repo->gitDir;
        $fresh = !is_dir($g);
        foreach (['', '/objects', '/objects/info', '/objects/pack', '/refs', '/refs/heads', '/refs/tags', '/info'] as $d) {
            if (!is_dir($g . $d)) mkdir($g . $d, 0777, true);
        }
        if (!is_file("$g/HEAD")) file_put_contents("$g/HEAD", "ref: refs/heads/$branch\n");
        if (!is_file("$g/config")) {
            file_put_contents("$g/config", "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n");
        }
        if (!is_file("$g/description")) file_put_contents("$g/description", "Unnamed repository; edit this file 'description' to name the repository.\n");
        return $repo;
    }

    // ------------------------------------------------------------------ objects

    public static function hashObject(string $type, string $data): string
    {
        return sha1($type . ' ' . strlen($data) . "\0" . $data);
    }

    public function writeObject(string $type, string $data): string
    {
        $sha = self::hashObject($type, $data);
        $path = $this->gitDir . '/objects/' . substr($sha, 0, 2) . '/' . substr($sha, 2);
        if (!is_file($path) && !$this->inPack($sha)) {
            $dir = dirname($path);
            if (!is_dir($dir)) mkdir($dir, 0777, true);
            $tmp = $dir . '/tmp_obj_' . getmypid() . '_' . bin2hex(random_bytes(4));
            file_put_contents($tmp, gzcompress($type . ' ' . strlen($data) . "\0" . $data, 1));
            chmod($tmp, 0444);
            rename($tmp, $path); // atomic publish
        }
        return $sha;
    }

    public function hasObject(string $sha): bool
    {
        return is_file($this->loosePath($sha)) || $this->inPack($sha);
    }

    private function loosePath(string $sha): string
    {
        return $this->gitDir . '/objects/' . substr($sha, 0, 2) . '/' . substr($sha, 2);
    }

    private function inPack(string $sha): bool
    {
        foreach ($this->packs() as $p) if ($p->find(hex2bin($sha)) !== null) return true;
        return false;
    }

    /** @return array{0:string,1:string} [type, data] */
    public function readObject(string $sha): array
    {
        if (isset($this->cache[$sha])) return $this->cache[$sha];
        $path = $this->loosePath($sha);
        if (is_file($path)) {
            $raw = gzuncompress(file_get_contents($path));
            if ($raw === false) throw new AcornError("corrupt loose object $sha");
            $nul = strpos($raw, "\0");
            [$type, $len] = explode(' ', substr($raw, 0, $nul));
            $data = substr($raw, $nul + 1);
            if (strlen($data) !== (int)$len) throw new AcornError("object $sha: length mismatch");
            $obj = [$type, $data];
        } else {
            $obj = null;
            foreach ($this->packs() as $p) {
                $off = $p->find(hex2bin($sha));
                if ($off !== null) { $obj = $p->readAt($off, $this); break; }
            }
            if ($obj === null) throw new AcornError("object $sha not found");
        }
        if (count($this->cache) > 512) $this->cache = [];
        return $this->cache[$sha] = $obj;
    }

    public function readTyped(string $sha, string $want): string
    {
        [$type, $data] = $this->readObject($sha);
        if ($type !== $want) throw new AcornError("object $sha is a $type, not a $want");
        return $data;
    }

    /** @return Pack[] */
    public function packs(): array
    {
        if ($this->packs === null) {
            $this->packs = [];
            foreach (glob($this->gitDir . '/objects/pack/pack-*.idx') ?: [] as $idx) {
                $this->packs[] = new Pack($idx);
            }
        }
        return $this->packs;
    }

    /** Expand an abbreviated hex object name. */
    public function expandPrefix(string $prefix): ?string
    {
        $prefix = strtolower($prefix);
        if (!preg_match('/^[0-9a-f]{4,40}$/', $prefix)) return null;
        $found = [];
        $dir = $this->gitDir . '/objects/' . substr($prefix, 0, 2);
        foreach (glob($dir . '/' . substr($prefix, 2) . '*') ?: [] as $f) $found[substr($prefix, 0, 2) . basename($f)] = true;
        foreach ($this->packs() as $p) foreach ($p->withPrefix($prefix) as $s) $found[$s] = true;
        if (count($found) > 1) throw new AcornError("short object ID $prefix is ambiguous");
        return $found ? array_key_first($found) : null;
    }

    // --------------------------------------------------------------- trees & commits

    /** @return list<array{mode:string,name:string,sha:string}> */
    public function parseTree(string $sha): array
    {
        $data = $this->readTyped($sha, 'tree');
        $out = [];
        $i = 0;
        $n = strlen($data);
        while ($i < $n) {
            $sp = strpos($data, ' ', $i);
            $nul = strpos($data, "\0", $sp);
            $out[] = [
                'mode' => substr($data, $i, $sp - $i),
                'name' => substr($data, $sp + 1, $nul - $sp - 1),
                'sha' => bin2hex(substr($data, $nul + 1, 20)),
            ];
            $i = $nul + 21;
        }
        return $out;
    }

    /** Flatten a tree recursively into path => [mode, sha] (blobs, links, gitlinks). */
    public function flattenTree(?string $sha, string $prefix = ''): array
    {
        $out = [];
        if ($sha === null) return $out;
        foreach ($this->parseTree($sha) as $e) {
            $path = $prefix . $e['name'];
            if ($e['mode'] === '40000') $out += $this->flattenTree($e['sha'], $path . '/');
            else $out[$path] = [str_pad($e['mode'], 6, '0', STR_PAD_LEFT), $e['sha']];
        }
        return $out;
    }

    /**
     * Build tree objects from a flat path => [mode, sha] map and return the root.
     * Git sorts tree entries as if directory names had a trailing '/'.
     */
    public function writeTreeFromMap(array $files): string
    {
        $root = [];
        foreach ($files as $path => [$mode, $sha]) {
            $parts = explode('/', (string)$path);
            $node = &$root;
            $last = array_pop($parts);
            foreach ($parts as $p) {
                if (!isset($node[$p . '/'])) $node[$p . '/'] = [];
                $node = &$node[$p . '/'];
            }
            $node[$last] = [$mode, $sha];
            unset($node);
        }
        return $this->writeTreeNode($root);
    }

    private function writeTreeNode(array $node): string
    {
        ksort($node, SORT_STRING); // dirs carry their trailing '/', which is exactly git's order
        $buf = '';
        foreach ($node as $key => $val) {
            $key = (string)$key;
            if (str_ends_with($key, '/')) {
                $buf .= '40000 ' . substr($key, 0, -1) . "\0" . hex2bin($this->writeTreeNode($val));
            } else {
                $buf .= ltrim($val[0], '0') . ' ' . $key . "\0" . hex2bin($val[1]);
            }
        }
        return $this->writeObject('tree', $buf);
    }

    /** @return array{tree:string,parents:list<string>,author:string,committer:string,message:string,headers:array} */
    public function parseCommit(string $sha): array
    {
        $data = $this->readTyped($sha, 'commit');
        $split = strpos($data, "\n\n");
        $head = $split === false ? $data : substr($data, 0, $split);
        $c = ['tree' => '', 'parents' => [], 'author' => '', 'committer' => '', 'headers' => [],
              'message' => $split === false ? '' : substr($data, $split + 2)];
        foreach (explode("\n", $head) as $line) {
            if ($line === '' || $line[0] === ' ') continue; // continuation (gpgsig etc.)
            [$k, $v] = explode(' ', $line, 2) + [1 => ''];
            if ($k === 'parent') $c['parents'][] = $v;
            elseif ($k === 'tree' || $k === 'author' || $k === 'committer') $c[$k] = $v;
            else $c['headers'][$k] = $v;
        }
        return $c;
    }

    // ------------------------------------------------------------------- refs

    public function headTarget(): ?string
    {
        $h = trim(file_get_contents($this->gitDir . '/HEAD'));
        return str_starts_with($h, 'ref: ') ? substr($h, 5) : null;
    }

    public function packedRefs(): array
    {
        $out = [];
        $f = $this->gitDir . '/packed-refs';
        if (!is_file($f)) return $out;
        foreach (file($f, FILE_IGNORE_NEW_LINES) as $line) {
            if ($line === '' || $line[0] === '#' || $line[0] === '^') continue;
            [$sha, $name] = explode(' ', $line, 2);
            $out[$name] = $sha;
        }
        return $out;
    }

    public function readRef(string $name, int $depth = 0): ?string
    {
        if ($depth > 5) throw new AcornError("ref loop at $name");
        $f = $this->gitDir . '/' . $name;
        if (is_file($f)) {
            $v = trim(file_get_contents($f));
            if (str_starts_with($v, 'ref: ')) return $this->readRef(substr($v, 5), $depth + 1);
            return $v;
        }
        return $this->packedRefs()[$name] ?? null;
    }

    public function updateRef(string $name, string $sha): void
    {
        $f = $this->gitDir . '/' . $name;
        if (!is_dir(dirname($f))) mkdir(dirname($f), 0777, true);
        $tmp = $f . '.lock';
        file_put_contents($tmp, $sha . "\n");
        rename($tmp, $f);
    }

    public function headCommit(): ?string
    {
        $t = $this->headTarget();
        return $t === null ? trim(file_get_contents($this->gitDir . '/HEAD')) : $this->readRef($t);
    }

    /** @return array<string,string> branch name => sha */
    public function branches(): array
    {
        $out = [];
        foreach ($this->packedRefs() as $n => $s) if (str_starts_with($n, 'refs/heads/')) $out[substr($n, 11)] = $s;
        $base = $this->gitDir . '/refs/heads';
        if (is_dir($base)) {
            $it = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($base, \FilesystemIterator::SKIP_DOTS));
            foreach ($it as $f) {
                if (str_ends_with($f->getFilename(), '.lock')) continue;
                $out[substr($f->getPathname(), strlen($base) + 1)] = trim(file_get_contents($f->getPathname()));
            }
        }
        ksort($out, SORT_STRING);
        return $out;
    }

    /** Resolve a revision: sha / prefix / ref names, with ~N and ^N suffixes. */
    public function revParse(string $rev): string
    {
        if (!preg_match('/^(.*?)((?:[~^]\d*)*)$/', $rev, $m)) throw new AcornError("bad revision '$rev'");
        [$base, $suffix] = [$m[1], $m[2]];
        $sha = null;
        if ($base === 'HEAD' || $base === '@') $sha = $this->headCommit();
        else {
            foreach (["$base", "refs/$base", "refs/tags/$base", "refs/heads/$base"] as $r) {
                if (str_starts_with($r, 'refs/') && ($s = $this->readRef($r)) !== null) { $sha = $s; break; }
            }
            if ($sha === null && preg_match('/^[0-9a-f]{40}$/', $base) && $this->hasObject($base)) $sha = $base;
            if ($sha === null) $sha = $this->expandPrefix($base);
        }
        if ($sha === null) throw new AcornError("ambiguous argument '$rev': unknown revision");
        preg_match_all('/([~^])(\d*)/', $suffix, $ops, PREG_SET_ORDER);
        foreach ($ops as [, $op, $num]) {
            $sha = $this->peelToCommit($sha);
            $n = $num === '' ? 1 : (int)$num;
            if ($op === '~') {
                for ($i = 0; $i < $n; $i++) {
                    $p = $this->parseCommit($sha)['parents'];
                    if (!$p) throw new AcornError("revision '$rev' goes past the root commit");
                    $sha = $p[0];
                }
            } elseif ($n > 0) {
                $p = $this->parseCommit($sha)['parents'];
                if (!isset($p[$n - 1])) throw new AcornError("commit has no parent $n");
                $sha = $p[$n - 1];
            }
        }
        return $sha;
    }

    public function peelToCommit(string $sha): string
    {
        for ($i = 0; $i < 10; $i++) {
            [$type, $data] = $this->readObject($sha);
            if ($type === 'commit') return $sha;
            if ($type !== 'tag') throw new AcornError("$sha is a $type, not a commit");
            $sha = substr($data, 7, 40); // "object <sha>\n"
        }
        throw new AcornError('tag chain too deep');
    }

    public function treeOf(string $rev): string
    {
        [$type] = $this->readObject($rev);
        return $type === 'tree' ? $rev : $this->parseCommit($this->peelToCommit($rev))['tree'];
    }

    public function config(string $key): ?string
    {
        $f = $this->gitDir . '/config';
        if (!is_file($f)) return null;
        [$section, $name] = array_pad(explode('.', $key, 2), 2, '');
        $cur = '';
        foreach (file($f, FILE_IGNORE_NEW_LINES) as $line) {
            $line = trim($line);
            if (preg_match('/^\[([^\]\s]+)\]$/', $line, $m)) { $cur = strtolower($m[1]); continue; }
            if ($cur === strtolower($section) && preg_match('/^([A-Za-z0-9-]+)\s*=\s*(.*)$/', $line, $m)
                && strtolower($m[1]) === strtolower($name)) return trim($m[2], '"');
        }
        return null;
    }
}

/**
 * A packfile + its v2 index. Objects may be stored whole or as OFS_DELTA /
 * REF_DELTA instructions against a base, possibly in long chains.
 */
final class Pack
{
    public string $idxPath;
    public string $packPath;
    private string $idx;
    private ?string $pack = null;
    public int $count;
    private array $baseCache = [];

    public function __construct(string $idxPath)
    {
        $this->idxPath = $idxPath;
        $this->packPath = substr($idxPath, 0, -4) . '.pack';
        $this->idx = file_get_contents($idxPath);
        if (substr($this->idx, 0, 4) !== "\xfftOc" || unpack('N', $this->idx, 4)[1] !== 2) {
            throw new AcornError("unsupported pack index $idxPath");
        }
        $this->count = unpack('N', $this->idx, 8 + 255 * 4)[1];
    }

    private function data(): string
    {
        return $this->pack ??= file_get_contents($this->packPath);
    }

    public function nameAt(int $i): string { return substr($this->idx, 8 + 1024 + $i * 20, 20); }
    public function crcAt(int $i): int { return unpack('N', $this->idx, 8 + 1024 + $this->count * 20 + $i * 4)[1]; }

    public function offsetAt(int $i): int
    {
        $base = 8 + 1024 + $this->count * 24;
        $o = unpack('N', $this->idx, $base + $i * 4)[1];
        if ($o & 0x80000000) { // index into the 64-bit offset table
            $big = $base + $this->count * 4 + ($o & 0x7fffffff) * 8;
            [, $hi, $lo] = unpack('N2', $this->idx, $big);
            $o = ($hi << 32) | $lo;
        }
        return $o;
    }

    /** Binary search the sorted name table, narrowed by the fan-out table. */
    public function find(string $bin): ?int
    {
        $b = ord($bin[0]);
        $lo = $b === 0 ? 0 : unpack('N', $this->idx, 8 + ($b - 1) * 4)[1];
        $hi = unpack('N', $this->idx, 8 + $b * 4)[1];
        while ($lo < $hi) {
            $mid = ($lo + $hi) >> 1;
            $c = strcmp($this->nameAt($mid), $bin);
            if ($c === 0) return $this->offsetAt($mid);
            if ($c < 0) $lo = $mid + 1; else $hi = $mid;
        }
        return null;
    }

    public function withPrefix(string $hex): array
    {
        $out = [];
        $b = hexdec(substr($hex, 0, 2));
        $lo = $b === 0 ? 0 : unpack('N', $this->idx, 8 + ($b - 1) * 4)[1];
        $hi = unpack('N', $this->idx, 8 + $b * 4)[1];
        for ($i = $lo; $i < $hi; $i++) {
            $h = bin2hex($this->nameAt($i));
            if (str_starts_with($h, $hex)) $out[] = $h;
        }
        return $out;
    }

    const TYPES = [1 => 'commit', 2 => 'tree', 3 => 'blob', 4 => 'tag'];

    /** @return array{type:int,size:int,hdr:int} raw entry header at offset */
    public function header(int $off): array
    {
        $d = $this->data();
        $c = ord($d[$off]);
        $type = ($c >> 4) & 7;
        $size = $c & 15;
        $shift = 4;
        $p = $off + 1;
        while ($c & 0x80) {
            $c = ord($d[$p++]);
            $size |= ($c & 0x7f) << $shift;
            $shift += 7;
        }
        return ['type' => $type, 'size' => $size, 'hdr' => $p - $off];
    }

    /** @return array{0:string,1:string} */
    public function readAt(int $off, Repo $repo, int $depth = 0): array
    {
        if (isset($this->baseCache[$off])) return $this->baseCache[$off];
        if ($depth > 10000) throw new AcornError('delta chain too long');
        $d = $this->data();
        $h = $this->header($off);
        $p = $off + $h['hdr'];
        if ($h['type'] === 6) { // OFS_DELTA: base is at a negative offset (git's +1 varint)
            $c = ord($d[$p++]);
            $rel = $c & 0x7f;
            while ($c & 0x80) {
                $c = ord($d[$p++]);
                $rel = (($rel + 1) << 7) | ($c & 0x7f);
            }
            [$btype, $bdata] = $this->readAt($off - $rel, $repo, $depth + 1);
            $obj = [$btype, self::applyDelta($bdata, self::inflate($d, $p, $h['size']))];
        } elseif ($h['type'] === 7) { // REF_DELTA: base named by SHA-1 (may live anywhere)
            $baseSha = bin2hex(substr($d, $p, 20));
            [$btype, $bdata] = $repo->readObject($baseSha);
            $obj = [$btype, self::applyDelta($bdata, self::inflate($d, $p + 20, $h['size']))];
        } elseif (isset(self::TYPES[$h['type']])) {
            $obj = [self::TYPES[$h['type']], self::inflate($d, $p, $h['size'])];
        } else {
            throw new AcornError("bad pack object type {$h['type']} at $off");
        }
        if (count($this->baseCache) > 256) $this->baseCache = [];
        return $this->baseCache[$off] = $obj;
    }

    private static function inflate(string $d, int $pos, int $size): string
    {
        // zlib stops at the end of the stream; trailing pack bytes are ignored.
        $out = @gzuncompress(substr($d, $pos, $size + 64 + ($size >> 1)));
        if ($out === false) $out = @gzuncompress(substr($d, $pos));
        if ($out === false || strlen($out) !== $size) throw new AcornError("corrupt zlib stream at $pos");
        return $out;
    }

    /** Apply git's binary delta format: varint sizes, then copy/insert ops. */
    public static function applyDelta(string $base, string $delta): string
    {
        $p = 0;
        $varint = function () use ($delta, &$p): int {
            $v = 0; $s = 0;
            do { $c = ord($delta[$p++]); $v |= ($c & 0x7f) << $s; $s += 7; } while ($c & 0x80);
            return $v;
        };
        $srcSize = $varint();
        $dstSize = $varint();
        if ($srcSize !== strlen($base)) throw new AcornError('delta base size mismatch');
        $out = '';
        $n = strlen($delta);
        while ($p < $n) {
            $op = ord($delta[$p++]);
            if ($op & 0x80) {
                $off = 0; $len = 0;
                for ($i = 0; $i < 4; $i++) if ($op & (1 << $i)) $off |= ord($delta[$p++]) << (8 * $i);
                for ($i = 0; $i < 3; $i++) if ($op & (0x10 << $i)) $len |= ord($delta[$p++]) << (8 * $i);
                if ($len === 0) $len = 0x10000;
                $out .= substr($base, $off, $len);
            } elseif ($op > 0) {
                $out .= substr($delta, $p, $op);
                $p += $op;
            } else {
                throw new AcornError('delta opcode 0 is reserved');
            }
        }
        if (strlen($out) !== $dstSize) throw new AcornError('delta result size mismatch');
        return $out;
    }

    /**
     * Verify everything: trailer checksums, every object's SHA-1 against the
     * index, and the CRC32 of every raw entry. Returns stats.
     */
    public function verify(Repo $repo): array
    {
        $d = $this->data();
        if (substr($d, 0, 4) !== 'PACK') throw new AcornError('bad pack signature');
        $n = unpack('N', $d, 8)[1];
        if ($n !== $this->count) throw new AcornError("pack has $n objects, index says {$this->count}");
        if (sha1(substr($d, 0, -20), true) !== substr($d, -20)) throw new AcornError('pack checksum mismatch');
        if (substr($this->idx, -40, 20) !== substr($d, -20)) throw new AcornError('index does not match pack');
        if (sha1(substr($this->idx, 0, -20), true) !== substr($this->idx, -20)) throw new AcornError('index checksum mismatch');
        $entries = [];
        for ($i = 0; $i < $this->count; $i++) $entries[] = [$this->offsetAt($i), $i];
        sort($entries);
        $stats = ['objects' => $n, 'deltas' => 0, 'ofs' => 0, 'ref' => 0, 'maxChain' => 0, 'types' => []];
        foreach ($entries as $k => [$off, $i]) {
            $end = $entries[$k + 1][0] ?? strlen($d) - 20;
            if (crc32(substr($d, $off, $end - $off)) !== $this->crcAt($i)) throw new AcornError("CRC mismatch at offset $off");
            [$type, $data] = $this->readAt($off, $repo);
            if (sha1("$type " . strlen($data) . "\0" . $data, true) !== $this->nameAt($i)) {
                throw new AcornError('SHA-1 mismatch for ' . bin2hex($this->nameAt($i)));
            }
            $stats['types'][$type] = ($stats['types'][$type] ?? 0) + 1;
            $chain = 0;
            for ($o = $off; ; $chain++) {
                $h = $this->header($o);
                if ($h['type'] === 6) {
                    $p = $o + $h['hdr']; $c = ord($d[$p++]); $rel = $c & 0x7f;
                    while ($c & 0x80) { $c = ord($d[$p++]); $rel = (($rel + 1) << 7) | ($c & 0x7f); }
                    if ($chain === 0) $stats['ofs']++;
                    $o -= $rel;
                } elseif ($h['type'] === 7) {
                    if ($chain === 0) $stats['ref']++;
                    $base = $this->find(substr($d, $o + $h['hdr'], 20));
                    if ($base === null) { $chain++; break; }
                    $o = $base;
                } else break;
            }
            if ($chain > 0) $stats['deltas']++;
            $stats['maxChain'] = max($stats['maxChain'], $chain);
        }
        return $stats;
    }
}
