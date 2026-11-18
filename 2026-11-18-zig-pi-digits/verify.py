#!/usr/bin/env python3
"""Cross-check ludolph's digits against GMP/MPFR (gmpy2), digit for digit.

usage: python3 verify.py [DIGITS]      one size, all four constants
       python3 verify.py sweep [N]     N random sizes (log-uniform, 1..200k digits)
(needs: pip install gmpy2)
"""
import subprocess, sys, time, tempfile, os, random
import gmpy2

def ref(name, D):
    gmpy2.get_context().precision = int(D * 3.3219280948873623) + 128
    x = {"pi": gmpy2.const_pi, "e": lambda: gmpy2.exp(1),
         "sqrt2": lambda: gmpy2.sqrt(2), "phi": lambda: (1 + gmpy2.sqrt(5)) / 2}[name]()
    # floor(x * 10^D) as an integer, then format as "I.FFFF"
    s = gmpy2.mpz(gmpy2.floor(x * gmpy2.mpz(10) ** D)).digits(10)
    return s[:-D] + "." + s[-D:]

if len(sys.argv) > 1 and sys.argv[1] == "sweep":
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    rng = random.Random(2026_11_18)
    bad = 0
    for i in range(n):
        D = max(1, int(10 ** rng.uniform(0, 5.3)))
        for name in ["pi", "e", "sqrt2", "phi"]:
            got = subprocess.run(["./zig-out/bin/ludolph", name, str(D), "-o", "/dev/stdout"],
                                 check=True, capture_output=True, text=True).stdout.split("\n")[0]
            if got != ref(name, D):
                bad += 1
                print("MISMATCH", name, D)
    print(f"sweep: {n} random sizes x 4 constants, {bad} mismatches")
    sys.exit(1 if bad else 0)

D = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
ok = True
with tempfile.TemporaryDirectory() as tmp:
    for name in ["pi", "e", "sqrt2", "phi"]:
        out = os.path.join(tmp, name + ".txt")
        t = time.time()
        subprocess.run(["./zig-out/bin/ludolph", name, str(D), "-o", out], check=True, capture_output=True)
        t_l = time.time() - t
        t = time.time(); want = ref(name, D); t_g = time.time() - t
        got = open(out).read().strip()
        same = got == want
        ok &= same
        if not same:
            bad = next(i for i, (a, b) in enumerate(zip(got, want)) if a != b) if len(got) == len(want) else -1
        print(f"{name:6} {D:>10,} digits  ludolph {t_l:6.2f}s  gmpy2 {t_g:6.2f}s  "
              + ("identical" if same else f"MISMATCH at index {bad}"))
sys.exit(0 if ok else 1)
