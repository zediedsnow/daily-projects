# ludolph

Computes **millions of digits of π, e, √2 and φ** in about 1,000 lines of Zig with no dependencies. It has its own big-integer arithmetic, number-theoretic-transform multiplication, Newton division and square roots, and Chudnovsky binary splitting.

It gets **1,000,000 digits of π in 2.0 s** and **10,000,000 in 35 s** on a 2-core cloud VM. Every digit matches GMP/MPFR (`gmpy2`), including all 10 million. That puts it within about 1.7× of GMP on the same machine.

The name comes from Ludolph van Ceulen, who spent 25 years of his life computing 35 digits of π by hand. Germans still call π *die Ludolphsche Zahl*.

## Why it's interesting

Computing a million digits takes three ideas that each turn an "impossible" cost into a cheap one:

- **Multiplying million-digit numbers in O(n log n).** Schoolbook multiplication of two 1M-digit numbers needs about 3×10¹⁰ limb products. Here both numbers become polynomials, and each one gets a number-theoretic transform: an FFT with exact modular arithmetic instead of floating point. The two transforms are multiplied pointwise and transformed back.
- **Summing a series with 70,000 terms as a single fraction.** Each term of the Chudnovsky series adds 14.18 digits. Adding the terms one by one with full-precision division would cost O(n²). Binary splitting merges neighbouring ranges of terms into one exact integer fraction P/Q/T in a balanced tree. The expensive multiplications happen near the root, where the NTT makes them cheap.
- **Division and square roots via Newton.** No long division happens anywhere. The program computes 1/x and 1/√x with Newton iterations, starting from a 12-digit `f64` seed. Each iteration doubles the number of correct digits, and the working precision doubles with it. All the iterations together cost about as much as 2–3 full multiplications.

Some details that make it fast and easy to check:

- **Limbs are base 10⁶.** Printing the result needs no binary-to-decimal conversion (which is a whole O(n log² n) algorithm of its own). The digits just fall out.
- **One prime, no CRT.** All convolutions run mod the *Goldilocks* prime p = 2⁶⁴ − 2³² + 1. Each output coefficient is below n·10¹², which is less than p for operands up to 18 million limbs (≈108M digits), so one 64-bit transform gives the exact product. Reduction mod p uses no division: 2⁶⁴ ≡ 2³² − 1 and 2⁹⁶ ≡ −1, so a 128-bit product reduces with a few adds and subtracts.
- **Parallel binary splitting.** The top levels of the splitting tree run on separate threads.
- **The root never computes P.** Only T and Q are needed at the top, so the root skips computing P(0, N), which would be the largest product in the whole run.

## Build & run

Needs **Zig 0.14** (`pip install ziglang==0.14.1` works too; then use `python3 -m ziglang` in place of `zig`).

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/ludolph pi 1000000 -o pi.txt     # also: e, sqrt2, phi
./zig-out/bin/ludolph test                     # self-tests of every layer
./zig-out/bin/ludolph bench                    # pi at 10^3 .. 10^6 digits
python3 verify.py 1000000                      # digit-for-digit vs GMP (pip install gmpy2)
python3 verify.py sweep 200                    # 200 random sizes x 4 constants vs GMP
```

## Sample output

```
$ ./zig-out/bin/ludolph pi 1000000 -o pi.txt
pi to 1000000 digits (2 threads)
  first: 3.14159265358979323846264338327950288419716939937510...
  last:  ...56787961303311646283996346460422090106105779458151
  series terms          70515
  binary split       1538.8 ms
  square root         129.0 ms
  division            333.7 ms
  total              2006.4 ms
  wrote pi.txt

$ ./zig-out/bin/ludolph pi 10000000
pi to 10000000 digits (2 threads)
  first: 3.14159265358979323846264338327950288419716939937510...
  last:  ...65326553194060999469787333810631719481735348955897
  series terms         705138
  binary split      25618.7 ms
  square root        2431.1 ms
  division           6971.3 ms
  total             35078.0 ms

$ ./zig-out/bin/ludolph bench
    digits     series       sqrt     divide      total
      1000      0.4ms      0.1ms      0.2ms      0.6ms
     10000      3.5ms      0.6ms      1.8ms      5.9ms
    100000     58.0ms     14.3ms     39.9ms    112.6ms
   1000000   1433.3ms    140.4ms    398.9ms   1978.3ms

$ python3 verify.py 1000000
pi      1,000,000 digits  ludolph   2.05s  gmpy2   1.20s  identical
e       1,000,000 digits  ludolph   1.02s  gmpy2   0.69s  identical
sqrt2   1,000,000 digits  ludolph   0.24s  gmpy2   0.18s  identical
phi     1,000,000 digits  ludolph   0.17s  gmpy2   0.18s  identical

$ python3 verify.py sweep 200
sweep: 200 random sizes x 4 constants, 0 mismatches

$ ./zig-out/bin/ludolph test
  [ok] Goldilocks mulmod == u128 % p on 1,000,000 random pairs
  [ok] NTT product == schoolbook product on 400 random pairs (up to 3000 limbs)
  [ok] signed identities (a+b)-b == a, (a+b)(a-b) == a^2-b^2 on 300 cases
  [ok] 1 - x*recip(x) < 10^(-6p) for 60 random x, p up to 3000 limbs
  [ok] 1 - x*invsqrt(x)^2 < 10^(-6p) for the same x
  [ok] pi matches reference to 100 digits
  [ok] e matches reference to 100 digits
  [ok] sqrt2 matches reference to 100 digits
  [ok] phi matches reference to 100 digits
  [ok] 36 prefix-consistency checks (d digits vs d+37, 1 vs 2 threads)
  [ok] pi to 1,000,000 digits ends ...5779458151
all tests passed
```

The test suite also passes in a `Debug` build, where Zig traps on every integer overflow and out-of-bounds access.

## How it works

| file | what |
|------|------|
| `src/bigint.zig` | base-10⁶ magnitudes, Goldilocks arithmetic, iterative radix-2 NTT, schoolbook/NTT multiply, signed ints |
| `src/float.zig` | big floats `m · 10^(6e)`, truncation, Newton reciprocal and inverse square root, decimal output |
| `src/constants.zig` | Chudnovsky binary splitting (threaded), e = Σ1/k!, √n, φ |
| `src/main.zig` | CLI, benchmark, self-tests |
| `verify.py` | cross-check against GMP/MPFR via gmpy2 |

**π (Chudnovsky).** The series is

  1/π = 12 Σₖ (−1)ᵏ (6k)! (13591409 + 545140134k) / ((3k)! (k!)³ 640320^(3k+3/2))

Binary splitting over [a, b) keeps three integers. At a leaf, P = (6a−5)(2a−1)(6a−1), Q = a³·640320³/24 and T = ±P·(13591409 + 545140134a). Two halves merge as P = PₗPᵣ, Q = QₗQᵣ, T = QᵣTₗ + PₗTᵣ. At the end, π = 426880·√10005·Q / T, which takes one inverse square root, one reciprocal and two multiplications at full precision.

**e.** This is the same idea with a simpler series: Σ_{k=a+1}^{b} a!/k! = P/Q with Q = (a+1)…b, merged as P = PₗQᵣ + Pᵣ. The number of terms N is the smallest with log₁₀ N! > digits + 20.

**Newton.** The reciprocal step is y ← y + y(1 − xy), and the inverse square root step is y ← y + y(1 − xy²)/2. Halving is exact in base 10⁶: multiply by 500000 and shift down one limb. Precision follows the schedule …, p/4, p/2, p, plus two guard limbs. Only the last step runs at full precision, so the whole iteration costs a small constant times one multiplication. The tests check that the residual 1 − x·y is below 10^(−6p) for random inputs whose exponents span ±3000 decimal digits.

**Correctness strategy.** Each layer is tested against a slower but obviously correct version of itself:

- The fast mod-p reduction against u128 `%`.
- NTT multiplication against schoolbook.
- Newton results against their defining identity.
- Each constant at d digits against itself at d+37 digits, single-threaded vs multi-threaded.
- The finished digits against GMP, at 200 random sizes and at 1M and 10M digits.
