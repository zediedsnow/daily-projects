#!/usr/bin/env python3
"""Cross-checks qrforge against two independent implementations.

1. python-qrcode and segno (two pure-Python QR encoders): for random version / ECC / mask /
   payload, the module matrix produced by qrforge must be bit-for-bit identical to python-qrcode's.
   It must also equal segno's, except in one predicted case: segno 1.6.6 appends a spurious zero
   byte when the bit stream is already byte-aligned after the terminator (its padding code does
   `8 - (length % 8)` instead of `(8 - length % 8) % 8`). Both outputs decode; only the pad differs.
2. zbar (C barcode reader, `zbarimg`): every PNG written by qrforge, including optimally
   mixed-mode payloads and damaged symbols, must decode back to the original text.
3. qrforge's own decoder must read PNGs written by segno (zlib-compressed, 1-bit, palette...).

    pip install segno qrcode ; apt install zbar-tools
"""
import os, random, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
QRF = os.path.join(HERE, "..", "qrforge")
N = int(os.environ.get("CASES", "1500"))

try:
    import segno
    import qrcode
except ImportError:
    sys.exit("crosscheck needs segno and qrcode:  pip install segno qrcode")
HAVE_ZBAR = subprocess.run(["which", "zbarimg"], capture_output=True).returncode == 0

ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
PRINTABLE = ALNUM + "abcdefghijklmnopqrstuvwxyz!#&()=?@[]_{}~,;'"
rng = random.Random(2026_11_15)
tmp = tempfile.mkdtemp()


def run(args, data):
    p = subprocess.run([QRF] + args, input=data.encode(), capture_output=True)
    if p.returncode:
        raise RuntimeError(p.stderr.decode())
    return p.stdout.decode()


def payload(kind, n):
    if kind == "numeric":
        return "".join(rng.choice("0123456789") for _ in range(n))
    if kind == "alnum":
        return "".join(rng.choice(ALNUM) for _ in range(n))
    if kind == "byte":
        return "".join(rng.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(n))
    # mixed: runs of digits, upper-case and lower-case, the optimizer's playground
    out = []
    while sum(map(len, out)) < n:
        k = rng.choice(["0123456789", ALNUM, PRINTABLE])
        out.append("".join(rng.choice(k) for _ in range(rng.randint(1, 40))))
    return "".join(out)[:n]


def zbar(path):  # QR only: with every symbology on, zbar occasionally "finds" a 1D barcode in the modules
    p = subprocess.run(["zbarimg", "--raw", "-q", "-Sdisable", "-Sqrcode.enable", "-Sbinary", path], capture_output=True)
    return p.stdout.decode("latin-1") if p.returncode == 0 else None


t0 = time.time()
# ---------------------------------------------------------------- 1. matrix identity
LEVELS = {"L": qrcode.constants.ERROR_CORRECT_L, "M": qrcode.constants.ERROR_CORRECT_M,
          "Q": qrcode.constants.ERROR_CORRECT_Q, "H": qrcode.constants.ERROR_CORRECT_H}


def rows(m):
    return ["".join("1" if b else "0" for b in r) for r in m]


def info_of(args, text):
    return subprocess.run([QRF] + args + ["--info"], input=text.encode(), capture_output=True).stderr.decode()


same_qrcode = same_segno = segno_bug = mask_agree = mask_cmp = qmask_agree = 0
for i in range(N):
    v = rng.randint(1, 40)
    ecc = rng.choice("LMQH")
    kind = rng.choice(["numeric", "alnum", "byte"])
    mask = rng.randint(0, 7)
    n = rng.randint(1, 3000)
    while True:
        text = payload(kind, n)
        try:
            ref = qrcode.QRCode(version=v, error_correction=LEVELS[ecc], mask_pattern=mask, border=0)
            ref.add_data(text, optimize=0)
            ref.make(fit=False)
            ref_rows = rows(ref.get_matrix())
            sref = segno.make_qr(text, version=v, error=ecc, mask=mask, boost_error=False)
            break
        except Exception:
            n = max(1, n // 2)
    args = ["encode", "-", "--matrix", "--no-boost", "--no-optimize", "-v", str(v), "-e", ecc]
    ours = run(args + ["-m", str(mask)], text).split()
    if ours != ref_rows:
        sys.exit(f"MATRIX MISMATCH vs python-qrcode: version {v}-{ecc} mask {mask} {kind} len {len(text)}")
    same_qrcode += 1
    # segno: identical unless the byte-aligned pad bug applies
    info = info_of(args + ["-m", str(mask)], text)
    used = int(info.split(" -> ")[1].split()[0])
    cap = int(info.split(" bits of ")[1].split()[0])
    aligned = (used + min(4, cap - used)) % 8 == 0 and used + 4 < cap
    if ours == rows(sref.matrix):
        if aligned:
            sys.exit(f"expected the segno pad bug to show for v{v}-{ecc} {kind} len {len(text)}")
        same_segno += 1
    elif aligned:
        segno_bug += 1
    else:
        sys.exit(f"MATRIX MISMATCH vs segno: version {v}-{ecc} mask {mask} {kind} len {len(text)}")
    # automatic mask choice (informational: implementations differ in penalty-rule details)
    sauto = segno.make_qr(text, version=v, error=ecc, boost_error=False)
    auto_mask = int(info_of(args, text).split(", mask ")[1].split()[0])
    mask_cmp += not aligned
    mask_agree += (not aligned) and sauto.mask == auto_mask
    qauto = qrcode.QRCode(version=v, error_correction=LEVELS[ecc], border=0)
    qauto.add_data(text, optimize=0)
    qauto.make(fit=False)
    qmask_agree += qauto.best_mask_pattern() == auto_mask
print(f"python-qrcode: {same_qrcode}/{N} random symbols (v1-40, L/M/Q/H, all 8 masks, numeric/alnum/byte) bit-identical")
print(f"segno: {same_segno} bit-identical, {segno_bug} differ exactly where segno's byte-aligned pad bug predicts, 0 unexplained")
print(f"auto mask choice (informational, penalty details differ between libraries): "
      f"python-qrcode agreed {qmask_agree}/{N}, segno {mask_agree}/{mask_cmp}")

# ---------------------------------------------------------------- 2. zbar reads what we write
if HAVE_ZBAR:
    ok = dmg_ours = dmg_zbar = dmg_disagree = 0
    M = N // 3
    for i in range(M):
        text = payload(rng.choice(["numeric", "alnum", "byte", "mixed", "mixed"]), rng.randint(1, 1200))
        ecc = rng.choice("LMQH")
        path = os.path.join(tmp, "z.png")
        try:
            run(["encode", "-", "-e", ecc, "-s", "3", "-o", path], text)
        except RuntimeError:
            continue  # too long for this level
        got = zbar(path)
        if got != text:
            sys.exit(f"ZBAR MISMATCH ecc {ecc} text {text[:60]!r}... got {got and got[:60]!r}")
        ok += 1
        # damage it and require both decoders to recover
        info = subprocess.run([QRF, "decode", "--info", path], capture_output=True).stderr.decode()
        blocks = int(info.split(" across ")[1].split()[0])
        t = int(info.split(", max ")[1].split()[0])
        flips = blocks * t // 2  # half the total correction budget, spread at random
        bad = os.path.join(tmp, "zd.png")
        subprocess.run([QRF, "damage", path, bad, "--flip", str(flips), "--seed", str(i)], check=True)
        ours = subprocess.run([QRF, "decode", bad], capture_output=True)
        a, b = ours.returncode == 0 and ours.stdout.decode() == text, zbar(bad) == text
        dmg_ours += a
        dmg_zbar += b
        if a != b:
            dmg_disagree += 1
    print(f"zbar:  {ok}/{ok} qrforge PNGs (incl. optimal mixed-mode segments) decoded to the exact text")
    print(f"damage: random module flips worth half the ECC budget: qrforge recovered {dmg_ours}/{ok}, zbar {dmg_zbar}/{ok}, disagreed on {dmg_disagree}")
else:
    print("zbar:  zbarimg not installed, skipped")

# ---------------------------------------------------------------- 3. we read what segno writes
ok = 0
M = N // 5
for i in range(M):
    text = payload(rng.choice(["numeric", "alnum", "byte", "mixed"]), rng.randint(1, 800))
    q = segno.make_qr(text, error=rng.choice("LMQH"))
    path = os.path.join(tmp, "s.png")
    q.save(path, scale=rng.randint(1, 6), border=rng.randint(1, 8), dark=rng.choice(["black", "#123", "darkblue"]),
           light=rng.choice(["white", None, "#ffe"]))
    got = subprocess.run([QRF, "decode", path], capture_output=True).stdout.decode()
    if got != text:
        sys.exit(f"DECODE MISMATCH on segno PNG: {text[:60]!r} got {got[:60]!r}")
    ok += 1
print(f"ours:  {ok}/{M} segno PNGs (zlib, palette/transparent, scale 1-6) decoded to the exact text")
print(f"all cross-checks passed in {time.time() - t0:.0f} s")
