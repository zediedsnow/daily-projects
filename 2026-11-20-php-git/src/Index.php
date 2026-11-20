<?php
declare(strict_types=1);

namespace Acorn;

/**
 * The staging area: git's binary DIRC file. Reads versions 2, 3 and 4
 * (v4 prefix-compresses path names), writes version 2.
 */
final class Index
{
    /** @var array<string, array> path => entry (stage 0 only is written back) */
    public array $entries = [];
    public int $mtime = 0;
    private string $path;

    public function __construct(private Repo $repo)
    {
        $this->path = $repo->gitDir . '/index';
        if (is_file($this->path)) $this->load();
    }

    private function load(): void
    {
        $d = file_get_contents($this->path);
        $this->mtime = filemtime($this->path);
        if (strlen($d) < 32 || substr($d, 0, 4) !== 'DIRC') throw new AcornError('index file corrupt (bad signature)');
        if (sha1(substr($d, 0, -20), true) !== substr($d, -20)) throw new AcornError('index file corrupt (bad checksum)');
        $ver = unpack('N', $d, 4)[1];
        $n = unpack('N', $d, 8)[1];
        if ($ver < 2 || $ver > 4) throw new AcornError("index version $ver unsupported");
        $p = 12;
        $prev = '';
        for ($i = 0; $i < $n; $i++) {
            $start = $p;
            $f = unpack('Nctime/Nctime_ns/Nmtime/Nmtime_ns/Ndev/Nino/Nmode/Nuid/Ngid/Nsize', $d, $p);
            $p += 40;
            $f['sha'] = bin2hex(substr($d, $p, 20));
            $p += 20;
            $flags = unpack('n', $d, $p)[1];
            $p += 2;
            $f['stage'] = ($flags >> 12) & 3;
            if (($flags & 0x4000) && $ver >= 3) $p += 2; // extended flags (skip-worktree, intent-to-add)
            if ($ver === 4) {
                // varint: how many bytes to drop from the end of the previous path
                $c = ord($d[$p++]); $strip = $c & 0x7f;
                while ($c & 0x80) { $c = ord($d[$p++]); $strip = (($strip + 1) << 7) | ($c & 0x7f); }
                $nul = strpos($d, "\0", $p);
                $name = substr($prev, 0, strlen($prev) - $strip) . substr($d, $p, $nul - $p);
                $p = $nul + 1;
            } else {
                $nul = strpos($d, "\0", $p);
                $name = substr($d, $p, $nul - $p);
                $p = $start + (($nul - $start + 8) & ~7); // 1..8 NULs pad to 8 bytes
            }
            $prev = $name;
            $f['mode'] = sprintf('%06o', $f['mode']);
            if ($f['stage'] === 0) $this->entries[$name] = $f;
        }
        // extensions (TREE, REUC, ...) follow; all optional, so we drop them
    }

    public function save(): void
    {
        $paths = array_map('strval', array_keys($this->entries));
        sort($paths, SORT_STRING);
        $buf = 'DIRC' . pack('NN', 2, count($paths));
        foreach ($paths as $path) {
            $e = $this->entries[$path];
            $len = min(strlen($path), 0xfff);
            $entry = pack('N10', $e['ctime'], $e['ctime_ns'] ?? 0, $e['mtime'], $e['mtime_ns'] ?? 0, $e['dev'] & 0xffffffff,
                    $e['ino'] & 0xffffffff, octdec($e['mode']), $e['uid'], $e['gid'], $e['size'] & 0xffffffff)
                . hex2bin($e['sha']) . pack('n', $len) . $path;
            $entry .= str_repeat("\0", 8 - (strlen($entry) % 8));
            $buf .= $entry;
        }
        $buf .= sha1($buf, true);
        $lock = $this->path . '.lock';
        file_put_contents($lock, $buf);
        rename($lock, $this->path);
        clearstatcache();
        $this->mtime = filemtime($this->path);
    }

    /** Stage one worktree path (file or symlink): hash it and record stat data. */
    public function add(string $path): void
    {
        $full = $this->repo->root . '/' . $path;
        $st = lstat($full);
        [$mode, $content] = Worktree::read($full, $st);
        $sha = $this->repo->writeObject('blob', $content);
        $this->entries[$path] = self::statEntry($st, $mode, $sha);
        // a file replacing a directory (or vice versa) evicts the old entries
        foreach (array_keys($this->entries) as $p) {
            $p = (string)$p;
            if (str_starts_with($p, $path . '/') || str_starts_with($path, $p . '/')) unset($this->entries[$p]);
        }
    }

    public static function statEntry(array $st, string $mode, string $sha): array
    {
        return ['ctime' => $st['ctime'], 'ctime_ns' => 0, 'mtime' => $st['mtime'], 'mtime_ns' => 0,
                'dev' => $st['dev'], 'ino' => $st['ino'], 'mode' => $mode, 'uid' => $st['uid'],
                'gid' => $st['gid'], 'size' => $st['size'], 'sha' => $sha, 'stage' => 0];
    }

    /** @return array<string, array{0:string,1:string}> path => [mode, sha] */
    public function asMap(): array
    {
        $out = [];
        foreach ($this->entries as $p => $e) $out[(string)$p] = [$e['mode'], $e['sha']];
        return $out;
    }

    /**
     * Does the worktree file still match this entry? Uses the stat cache when
     * it is trustworthy, and re-hashes "racily clean" entries (modified in the
     * same second the index was written) exactly like git does.
     * Returns null if unchanged, otherwise the new [mode, sha] (sha null if deleted).
     */
    public function worktreeState(string $path): ?array
    {
        $e = $this->entries[$path];
        $full = $this->repo->root . '/' . $path;
        $st = @lstat($full);
        if ($st === false || is_dir($full) && !is_link($full)) return ['', null];
        $mode = Worktree::modeOf($st);
        if ($mode !== $e['mode']) return [$mode, Repo::hashObject('blob', Worktree::read($full, $st)[1])];
        if ($st['size'] !== $e['size'] || $st['mtime'] !== $e['mtime'] || $st['ino'] !== $e['ino']
            || $st['mtime'] >= $this->mtime) {
            $sha = Repo::hashObject('blob', Worktree::read($full, $st)[1]);
            return $sha === $e['sha'] ? null : [$mode, $sha];
        }
        return null;
    }
}

final class Worktree
{
    public static function modeOf(array $st): string
    {
        $t = $st['mode'] & 0170000;
        if ($t === 0120000) return '120000';
        return ($st['mode'] & 0100) ? '100755' : '100644';
    }

    /** @return array{0:string,1:string} [mode, blob content] */
    public static function read(string $full, array $st): array
    {
        $mode = self::modeOf($st);
        return [$mode, $mode === '120000' ? readlink($full) : file_get_contents($full)];
    }

    public static function write(string $full, string $mode, string $content): void
    {
        if (!is_dir(dirname($full))) mkdir(dirname($full), 0777, true);
        if (is_link($full) || is_file($full)) unlink($full);
        if ($mode === '120000') { symlink($content, $full); return; }
        file_put_contents($full, $content);
        chmod($full, $mode === '100755' ? 0755 : 0644);
    }

    /** All files and symlinks under the worktree (relative paths), skipping .git. */
    public static function files(string $root, string $rel = ''): array
    {
        $out = [];
        $dir = $rel === '' ? $root : "$root/$rel";
        $names = @scandir($dir);
        if ($names === false) return $out;
        foreach ($names as $n) {
            if ($n === '.' || $n === '..' || ($rel === '' && $n === '.git')) continue;
            $p = $rel === '' ? $n : "$rel/$n";
            if (is_dir("$root/$p") && !is_link("$root/$p")) {
                if (is_dir("$root/$p/.git")) continue; // nested repository
                array_push($out, ...self::files($root, $p));
            } else {
                $out[] = $p;
            }
        }
        return $out;
    }
}
