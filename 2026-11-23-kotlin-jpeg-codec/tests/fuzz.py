#!/usr/bin/env python3
"""
Differential fuzzer: ochre vs libjpeg-turbo (through Pillow).

For every random case it
  1. makes a random image (noise, gradients, shapes, photo crops; gray or RGB; 1..W x 1..H),
  2. has Pillow/libjpeg-turbo encode it with random quality / subsampling / optimize /
     progressive / restart-interval settings,
  3. has ochre DECODE that file          -> pixels must equal Pillow's decode exactly,
  4. has ochre ENCODE the same source    -> the .jpg must be byte-identical to Pillow's,
and additionally round-trips 4:4:0 / 4:1:1 files (which Pillow cannot write) through
ochre's encoder and both decoders.

usage: tests/fuzz.py [cases] [seed]
"""
import os, random, shutil, subprocess, sys, tempfile, time
import numpy as np
from PIL import Image, ImageDraw, features

HERE = os.path.dirname(os.path.abspath(__file__))
JAR = os.path.join(HERE, "..", "ochre.jar")
PHOTO = os.path.join(HERE, "..", "examples", "render.png")

def rand_image(rng: random.Random, photo):
    big = rng.random() < 0.03
    w = rng.choice([1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 33]) if rng.random() < 0.25 else rng.randint(1, 960 if big else 260)
    h = rng.choice([1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 33]) if rng.random() < 0.25 else rng.randint(1, 540 if big else 260)
    kind = rng.choice(["noise", "gradient", "shapes", "photo", "photo", "flat"])
    nr = np.random.default_rng(rng.getrandbits(32))
    if kind == "noise":
        a = nr.integers(0, 256, (h, w, 3), dtype=np.uint8)
        im = Image.fromarray(a)
    elif kind == "gradient":
        y, x = np.mgrid[0:h, 0:w]
        f = [rng.uniform(-3, 3) for _ in range(6)]
        a = np.stack([(x * f[0] + y * f[1]) % 256, (x * f[2] + y * f[3] + 90) % 256, (x * f[4] * y * 0.05 + y * f[5]) % 256], -1)
        im = Image.fromarray(a.astype(np.uint8))
    elif kind == "shapes":
        im = Image.new("RGB", (w, h), tuple(rng.randrange(256) for _ in range(3)))
        dr = ImageDraw.Draw(im)
        for _ in range(rng.randint(1, 12)):
            box = sorted([rng.randint(-10, w + 10) for _ in range(2)]), sorted([rng.randint(-10, h + 10) for _ in range(2)])
            xy = [box[0][0], box[1][0], box[0][1], box[1][1]]
            col = tuple(rng.randrange(256) for _ in range(3))
            rng.choice([dr.rectangle, dr.ellipse])(xy, fill=col)
    elif kind == "flat":
        im = Image.new("RGB", (w, h), tuple(rng.randrange(256) for _ in range(3)))
    else:
        pw, ph = photo.size
        x0, y0 = rng.randint(0, max(0, pw - w)), rng.randint(0, max(0, ph - h))
        im = photo.crop((x0, y0, x0 + w, y0 + h))
    if rng.random() < 0.2:
        im = im.convert("L")
    return im, kind

def main():
    cases = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(seed)
    photo = Image.open(PHOTO).convert("RGB")
    tmp = tempfile.mkdtemp(prefix="ochre-fuzz-")
    jobs, meta = [], []
    skipped = 0
    i = 0
    while i < cases:
        im, kind = rand_image(rng, photo)
        q = rng.choice([rng.randint(1, 100), 75, 90, 95, 100, 50, 10])
        sub = rng.choice([0, 1, 2])
        opt = rng.random() < 0.35
        prog = rng.random() < 0.35
        rst = rng.choice([0, 0, 0, 1, 2, 5, 17])
        src = f"{tmp}/{i}.src.{'pgm' if im.mode == 'L' else 'ppm'}"
        im.save(src)
        ref = f"{tmp}/{i}.ref.jpg"
        kw = dict(quality=q, optimize=opt, progressive=prog)
        if im.mode == "RGB":
            kw["subsampling"] = sub
        if rst:
            kw["restart_marker_blocks"] = rst
        try:
            im.save(ref, **kw)
        except OSError:  # Pillow's suspending-destination bug ("Suspension not allowed here") on some tiny images
            skipped += 1
            continue
        flags = ["-q", str(q), "-s", ["444", "422", "420"][sub]]
        if opt: flags.append("--optimize")
        if prog: flags.append("--progressive")
        if rst: flags += ["--restart", str(rst)]
        jobs.append(f"decode {ref} {tmp}/{i}.dec.{'pgm' if im.mode == 'L' else 'ppm'}")
        jobs.append(f"encode {src} {tmp}/{i}.enc.jpg " + " ".join(flags))
        meta.append((i, im.mode, im.size, kind, kw))
        i += 1
    # exotic samplings that Pillow can't write: encode with ochre, decode with both
    exotic = []
    for j in range(cases // 5):
        im, kind = rand_image(rng, photo)
        im = im.convert("RGB")
        sub = rng.choice(["440", "411"])
        src = f"{tmp}/x{j}.src.ppm"; im.save(src)
        jobs.append(f"encode {src} {tmp}/x{j}.jpg -s {sub} -q {rng.randint(20, 100)}" + (" --progressive" if rng.random() < 0.5 else ""))
        jobs.append(f"decode {tmp}/x{j}.jpg {tmp}/x{j}.dec.ppm")
        exotic.append((j, im.size, sub))
    with open(f"{tmp}/jobs.txt", "w") as f:
        f.write("\n".join(jobs) + "\n")
    t0 = time.time()
    r = subprocess.run(["java", "-jar", JAR, "batch", f"{tmp}/jobs.txt"], capture_output=True, text=True)
    elapsed = time.time() - t0
    print(r.stdout.strip())
    err = [l for l in r.stderr.splitlines() if l.startswith("FAIL")]
    for l in err[:10]: print(l)

    dec_ok = enc_ok = 0
    fails = []
    for i, mode, size, kind, kw in meta:
        ext = "pgm" if mode == "L" else "ppm"
        try:
            want = np.asarray(Image.open(f"{tmp}/{i}.ref.jpg"))
            got = np.asarray(Image.open(f"{tmp}/{i}.dec.{ext}"))
            if want.shape == got.shape and (want == got).all(): dec_ok += 1
            else: fails.append(("decode", i, mode, size, kind, kw, int(np.abs(want.astype(int) - got.astype(int)).max()) if want.shape == got.shape else "shape"))
        except Exception as e:
            fails.append(("decode", i, mode, size, kind, kw, repr(e)))
        try:
            a = open(f"{tmp}/{i}.ref.jpg", "rb").read(); b = open(f"{tmp}/{i}.enc.jpg", "rb").read()
            if a == b: enc_ok += 1
            else:
                k = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
                fails.append(("encode", i, mode, size, kind, kw, f"len {len(a)} vs {len(b)}, first diff @{k}"))
        except Exception as e:
            fails.append(("encode", i, mode, size, kind, kw, repr(e)))
    ex_ok = 0
    for j, size, sub in exotic:
        try:
            want = np.asarray(Image.open(f"{tmp}/x{j}.jpg").convert("RGB"))
            got = np.asarray(Image.open(f"{tmp}/x{j}.dec.ppm"))
            if (want == got).all(): ex_ok += 1
            else: fails.append(("exotic", j, "RGB", size, sub, {}, int(np.abs(want.astype(int) - got.astype(int)).max())))
        except Exception as e:
            fails.append(("exotic", j, "RGB", size, sub, {}, repr(e)))
    for f in fails[:15]: print("MISMATCH", f)
    print(f"libjpeg-turbo {features.version('jpg')} via Pillow; {cases} cases, seed {seed}, ochre batch time {elapsed:.1f}s ({skipped} cases Pillow itself failed to write were skipped)")
    print(f"  decode bit-exact : {dec_ok}/{cases}")
    print(f"  encode identical : {enc_ok}/{cases}")
    print(f"  4:4:0/4:1:1 decode agrees with libjpeg-turbo: {ex_ok}/{len(exotic)}")
    if not fails and not err:
        shutil.rmtree(tmp)
    else:
        print("files kept in", tmp)
    sys.exit(0 if not fails and not err else 1)

if __name__ == "__main__":
    main()
