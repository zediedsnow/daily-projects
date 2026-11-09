"""Tests for pydeflate. Run: python3 -m unittest -v test_pydeflate

zlib / gzip from the standard library are used ONLY as a reference oracle here.
"""

import gzip
import random
import unittest
import zlib

import pydeflate as pd


def zlib_raw(data, level=6):
    co = zlib.compressobj(level, zlib.DEFLATED, -15)
    return co.compress(data) + co.flush()


CASES = {
    "empty": b"",
    "one byte": b"x",
    "two bytes": b"ab",
    "all bytes": bytes(range(256)) * 3,
    "long run": b"a" * 70000,
    "run of 258": b"q" * 258,
    "run of 259": b"q" * 259,
    "period 3": b"abc" * 20000,
    "far match": b"HEADER" + bytes(random.Random(1).getrandbits(8) for _ in range(32700)) + b"HEADER",
    "text": (b"It was the best of times, it was the worst of times, " * 500),
    "random": bytes(random.Random(2).getrandbits(8) for _ in range(100000)),  # > 65535: multi stored
}


class TestCRC(unittest.TestCase):
    def test_matches_zlib(self):
        for name, data in CASES.items():
            self.assertEqual(pd.crc32(data), zlib.crc32(data), name)

    def test_check_value(self):
        self.assertEqual(pd.crc32(b"123456789"), 0xCBF43926)


class TestHuffman(unittest.TestCase):
    def test_package_merge_limits_and_kraft(self):
        rng = random.Random(3)
        for _ in range(200):
            n = rng.randint(2, 286)
            # Fibonacci-like weights force very deep unrestricted trees
            freqs = [rng.choice([0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 10 ** 6]) for _ in range(n)]
            if sum(1 for f in freqs if f) < 2:
                continue
            for limit in (7, 9, 15):
                if (1 << limit) < sum(1 for f in freqs if f):
                    continue
                lengths = pd.package_merge(freqs, limit)
                self.assertLessEqual(max(lengths), limit)
                kraft = sum(2.0 ** -l for l in lengths if l)
                self.assertAlmostEqual(kraft, 1.0)  # complete prefix code
                for f, l in zip(freqs, lengths):
                    self.assertEqual(bool(f), bool(l))

    def test_fibonacci_needs_limiting(self):
        fib = [1, 1]
        while len(fib) < 25:
            fib.append(fib[-1] + fib[-2])
        lengths = pd.package_merge(fib, 15)
        self.assertEqual(max(lengths), 15)

    def test_optimal_when_unconstrained(self):
        # package-merge with a loose limit must equal plain Huffman cost
        import heapq
        rng = random.Random(4)
        for _ in range(50):
            freqs = [rng.randint(1, 1000) for _ in range(rng.randint(2, 60))]
            heap = list(freqs)
            heapq.heapify(heap)
            huff = 0
            while len(heap) > 1:
                a, b = heapq.heappop(heap), heapq.heappop(heap)
                huff += a + b
                heapq.heappush(heap, a + b)
            lengths = pd.package_merge(freqs, 15)
            self.assertEqual(sum(f * l for f, l in zip(freqs, lengths)), huff)

    def test_single_symbol(self):
        lengths = pd.package_merge([0, 0, 5], 15)
        self.assertEqual(sorted(l for l in lengths if l), [1, 1])

    def test_rfc_example(self):
        # RFC 1951 3.2.2: lengths (3,3,3,3,3,2,4,4) -> codes 010,011,100,101,110,00,1110,1111
        codes = pd.canonical_codes([3, 3, 3, 3, 3, 2, 4, 4])
        self.assertEqual(codes, [0b010, 0b011, 0b100, 0b101, 0b110, 0b00, 0b1110, 0b1111])


class TestRoundTrip(unittest.TestCase):
    def test_all_levels(self):
        for name, data in CASES.items():
            for level in (0, 1, 4, 6, 9):
                with self.subTest(name=name, level=level):
                    comp = pd.deflate(data, level)
                    self.assertEqual(pd.inflate(comp)[0], data)
                    self.assertEqual(zlib.decompress(comp, -15), data)  # zlib accepts ours

    def test_fuzz_small_alphabets(self):
        rng = random.Random(5)
        for _ in range(300):
            alpha = bytes(rng.sample(range(256), rng.randint(1, 6)))
            data = bytes(rng.choice(alpha) for _ in range(rng.randint(0, 3000)))
            comp = pd.deflate(data, rng.randint(1, 9))
            self.assertEqual(zlib.decompress(comp, -15), data)
            self.assertEqual(pd.inflate(comp)[0], data)

    def test_compresses_well(self):
        data = CASES["text"]
        self.assertLess(len(pd.deflate(data, 6)), len(data) // 50)
        rnd = CASES["random"]
        self.assertLess(len(pd.deflate(rnd, 6)), len(rnd) + 50)  # stored fallback


class TestInflateZlibStreams(unittest.TestCase):
    def test_reads_zlib_output(self):
        for name, data in CASES.items():
            for level in range(0, 10):
                with self.subTest(name=name, level=level):
                    self.assertEqual(pd.inflate(zlib_raw(data, level))[0], data)

    def test_fixed_strategy(self):
        co = zlib.compressobj(6, zlib.DEFLATED, -15, 9, zlib.Z_FIXED)
        data = CASES["text"]
        self.assertEqual(pd.inflate(co.compress(data) + co.flush())[0], data)

    def test_trailing_offset(self):
        comp = zlib_raw(b"hello hello hello") + b"TRAILER"
        out, end = pd.inflate(comp)
        self.assertEqual(out, b"hello hello hello")
        self.assertEqual(comp[end:], b"TRAILER")


class TestGzip(unittest.TestCase):
    def test_gzip_module_reads_ours(self):
        for name, data in CASES.items():
            self.assertEqual(gzip.decompress(pd.gzip_compress(data, filename="x.txt")), data, name)

    def test_we_read_gzip_module(self):
        for name, data in CASES.items():
            self.assertEqual(pd.gzip_decompress(gzip.compress(data)), data, name)

    def test_multi_member(self):
        blob = gzip.compress(b"first ") + pd.gzip_compress(b"second")
        self.assertEqual(pd.gzip_decompress(blob), b"first second")
        self.assertEqual(gzip.decompress(blob), b"first second")

    def test_corruption_detected(self):
        gz = bytearray(pd.gzip_compress(CASES["text"]))
        gz[-6] ^= 0xFF  # flip a CRC byte
        with self.assertRaises(pd.DeflateError):
            pd.gzip_decompress(bytes(gz))

    def test_truncation_detected(self):
        gz = pd.gzip_compress(CASES["text"])
        with self.assertRaises(pd.DeflateError):
            pd.gzip_decompress(gz[: len(gz) // 2])

    def test_garbage_never_crashes_badly(self):
        rng = random.Random(6)
        good = pd.deflate(CASES["text"])
        for _ in range(300):
            bad = bytearray(good)
            for _ in range(rng.randint(1, 5)):
                bad[rng.randrange(len(bad))] = rng.getrandbits(8)
            try:
                pd.inflate(bytes(bad))
            except pd.DeflateError:
                pass  # clean, typed failure is the expected outcome


if __name__ == "__main__":
    unittest.main()
