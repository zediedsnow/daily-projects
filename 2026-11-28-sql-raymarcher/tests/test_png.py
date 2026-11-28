#!/usr/bin/env python3
"""Differential tests for umbra's SQL PNG encoder against Python's zlib and Pillow.

Every check sends data to PostgreSQL through psql, runs the SQL implementation,
and compares with an independent implementation:
  * crc32 / adler32          vs zlib.crc32 / zlib.adler32
  * deflate                  vs zlib.decompress (raw inflate must give the input back)
  * png_encode               vs Pillow decoding the file + pngcheck validating it
"""
import io, os, random, shutil, subprocess, sys, tempfile, zlib

from PIL import Image

PSQL = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]


def sql_many(template, blobs):
    """Run `template` (with {hex}) for many byte strings in one psql session."""
    script = "\n".join(template.format(hex=b.hex()) for b in blobs)
    out = subprocess.run(PSQL, input=script, capture_output=True, text=True, check=True).stdout
    return out.strip().split("\n")


def gen_blob(rng):
    kind = rng.randrange(5)
    n = rng.choice([0, 1, 2, 3, 4, 7, 100, 258, 259, 260, 261, 517, 1000, 5000, rng.randrange(20000)])
    if kind == 0:                                   # white noise
        return bytes(rng.randrange(256) for _ in range(n))
    if kind == 1:                                   # long runs of a few symbols
        out = bytearray()
        while len(out) < n:
            out += bytes([rng.choice([0, 1, 255])]) * rng.choice([1, 2, 3, 257, 258, 259, 600])
        return bytes(out[:n])
    if kind == 2:
        return bytes([rng.randrange(256)]) * n      # one single run
    if kind == 3:                                   # mostly runs of length 1..5
        out = bytearray()
        while len(out) < n:
            out += bytes([rng.randrange(256)]) * rng.randrange(1, 6)
        return bytes(out[:n])
    return bytes(range(256)) * (n // 256 + 1)       # every byte value


def main():
    rng = random.Random(28)
    failures = 0

    blobs = [gen_blob(rng) for _ in range(400)]
    got = sql_many("select umbra.crc32('\\x{hex}'::bytea) || ' ' || umbra.adler32('\\x{hex}'::bytea);", blobs)
    for b, line in zip(blobs, got):
        c, a = map(int, line.split())
        if c != zlib.crc32(b) or a != zlib.adler32(b):
            failures += 1
            print(f"checksum mismatch on {len(b)}-byte input")
    print(f"crc32 + adler32: {len(blobs)} inputs checked against zlib")

    blobs = [b for b in blobs if b]  # deflate of empty input is not needed by PNG
    got = sql_many("select encode(umbra.deflate('\\x{hex}'::bytea), 'hex');", blobs)
    raw_in = raw_out = 0
    for b, line in zip(blobs, got):
        comp = bytes.fromhex(line)
        try:
            ok = zlib.decompress(comp, -15) == b
        except zlib.error as e:
            ok = False
        if not ok:
            failures += 1
            print(f"deflate round-trip failed on {len(b)}-byte input")
        raw_in += len(b); raw_out += len(comp)
    print(f"deflate: {len(blobs)} streams inflate back exactly ({raw_in} -> {raw_out} bytes)")

    images = []
    for k in range(60):
        w, h = rng.choice([(1, 1), (1, 9), (9, 1), (3, 7), (16, 16), (31, 17), (64, 48), (257, 5)])
        style = k % 4
        px = bytearray()
        for y in range(h):
            for x in range(w):
                if style == 0:
                    px += bytes(rng.randrange(256) for _ in range(3))
                elif style == 1:
                    px += bytes([(x * 7) % 256, (y * 13) % 256, (x * y) % 256])
                elif style == 2:
                    px += bytes([200, 30, 30]) if (x // 4 + y // 4) % 2 else bytes([20, 20, 240])
                else:
                    px += bytes([min(255, x + y), 128, rng.choice([0, 255])])
        images.append((w, h, bytes(px)))
    script = "\n".join(f"select encode(umbra.png_encode({w}, {h}, '\\x{p.hex()}'::bytea), 'hex');"
                       for w, h, p in images)
    out = subprocess.run(PSQL, input=script, capture_output=True, text=True, check=True).stdout.split()
    have_pngcheck = shutil.which("pngcheck") is not None
    for (w, h, p), hx in zip(images, out):
        data = bytes.fromhex(hx)
        im = Image.open(io.BytesIO(data))
        im.load()
        if im.size != (w, h) or im.mode != "RGB" or im.tobytes() != p:
            failures += 1
            print(f"PNG pixel mismatch at {w}x{h}")
        if have_pngcheck:
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
                f.write(data)
            r = subprocess.run(["pngcheck", "-q", f.name], capture_output=True, text=True)
            os.unlink(f.name)
            if r.returncode != 0:
                failures += 1
                print("pngcheck:", r.stdout.strip())
    print(f"png_encode: {len(images)} images decode pixel-exact in Pillow"
          + (", all pass pngcheck" if have_pngcheck else ""))

    print("FAILURES:", failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
