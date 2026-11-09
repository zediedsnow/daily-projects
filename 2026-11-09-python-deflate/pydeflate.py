#!/usr/bin/env python3
"""
pydeflate - a from-scratch DEFLATE (RFC 1951) + gzip (RFC 1952) codec in pure Python.

No zlib, no gzip module: LZ77 with hash chains and lazy matching, length-limited
Huffman codes via the package-merge algorithm, per-block choice between stored /
fixed / dynamic encodings, a table-driven inflater, and a hand-rolled CRC-32.

Output is byte-for-byte valid gzip: `gunzip`, `zcat` and Python's gzip module
read it, and pydeflate reads theirs.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time

# --------------------------------------------------------------------------- #
#  CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) - slicing-by-1 table        #
# --------------------------------------------------------------------------- #

def _make_crc_table():
    table = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
        table.append(c)
    return table

_CRC_TABLE = _make_crc_table()


def crc32(data: bytes, crc: int = 0) -> int:
    t = _CRC_TABLE
    c = crc ^ 0xFFFFFFFF
    for b in data:
        c = t[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


# --------------------------------------------------------------------------- #
#  DEFLATE constant tables (RFC 1951 section 3.2.5)                            #
# --------------------------------------------------------------------------- #

LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
             257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
             8193, 12289, 16385, 24577]
DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
              7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

WINDOW = 32768
MIN_MATCH, MAX_MATCH = 3, 258

# length (3..258) -> (symbol index 0..28, extra bits, extra value)
_LEN_LOOKUP = [None] * (MAX_MATCH + 1)
for _code in range(29):
    for _l in range(LEN_BASE[_code], LEN_BASE[_code] + (1 << LEN_EXTRA[_code])):
        if _l <= MAX_MATCH and _LEN_LOOKUP[_l] is None:
            _LEN_LOOKUP[_l] = (_code, LEN_EXTRA[_code], _l - LEN_BASE[_code])
_LEN_LOOKUP[258] = (28, 0, 0)  # 258 has its own zero-extra code

# distance (1..32768) -> (symbol, extra bits, extra value)
_DIST_LOOKUP = [None] * (WINDOW + 1)
for _code in range(30):
    for _d in range(DIST_BASE[_code], DIST_BASE[_code] + (1 << DIST_EXTRA[_code])):
        if _d <= WINDOW:
            _DIST_LOOKUP[_d] = (_code, DIST_EXTRA[_code], _d - DIST_BASE[_code])

FIXED_LIT_LENGTHS = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
FIXED_DIST_LENGTHS = [5] * 30


class DeflateError(ValueError):
    pass


# --------------------------------------------------------------------------- #
#  Bit I/O - DEFLATE packs bits LSB-first                                      #
# --------------------------------------------------------------------------- #

class BitWriter:
    __slots__ = ("out", "acc", "nbits")

    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.nbits = 0

    def write(self, value: int, n: int):
        self.acc |= value << self.nbits
        self.nbits += n
        if self.nbits >= 32:
            k = self.nbits >> 3
            self.out += (self.acc & ((1 << (k * 8)) - 1)).to_bytes(k, "little")
            self.acc >>= k * 8
            self.nbits -= k * 8

    def align(self):
        if self.nbits & 7:
            self.write(0, 8 - (self.nbits & 7))
        k = self.nbits >> 3
        if k:
            self.out += self.acc.to_bytes(k, "little")
        self.acc = 0
        self.nbits = 0

    def bit_length(self) -> int:
        return len(self.out) * 8 + self.nbits

    def getvalue(self) -> bytes:
        self.align()
        return bytes(self.out)


class BitReader:
    __slots__ = ("data", "pos", "acc", "nbits")

    def __init__(self, data: bytes, pos: int = 0):
        self.data = data
        self.pos = pos
        self.acc = 0
        self.nbits = 0

    def _fill(self, n: int):
        # pull whole bytes until we hold >= n bits; past EOF we pad with zeros
        # (peek may look ahead; consuming phantom bits is caught in need())
        while self.nbits < n:
            if self.pos < len(self.data):
                self.acc |= self.data[self.pos] << self.nbits
            self.pos += 1
            self.nbits += 8

    def bits(self, n: int) -> int:
        if n == 0:
            return 0
        if self.nbits < n:
            self._fill(n)
        v = self.acc & ((1 << n) - 1)
        self.acc >>= n
        self.nbits -= n
        if self.pos * 8 - self.nbits > len(self.data) * 8:
            raise DeflateError("unexpected end of compressed stream")
        return v

    def align(self):
        drop = self.nbits & 7
        self.acc >>= drop
        self.nbits -= drop

    def byte_pos(self) -> int:
        """Byte offset of the next unread whole byte (after align())."""
        return self.pos - (self.nbits >> 3)

    def bit_pos(self) -> int:
        return self.pos * 8 - self.nbits


# --------------------------------------------------------------------------- #
#  Huffman coding                                                              #
# --------------------------------------------------------------------------- #

def package_merge(freqs: list[int], max_bits: int) -> list[int]:
    """Optimal length-limited prefix code lengths (Larmore & Hirschberg 1990).

    Returns one code length per symbol (0 = unused). Guarantees no length
    exceeds max_bits and that the code is complete when >= 2 symbols are used.
    """
    n = len(freqs)
    used = [s for s in range(n) if freqs[s]]
    lengths = [0] * n
    if not used:
        return lengths
    if len(used) == 1:
        # A one-symbol tree is degenerate; give it a sibling so every decoder
        # (including strict ones) sees a complete code.
        s = used[0]
        lengths[s] = 1
        lengths[0 if s != 0 else 1] = 1
        return lengths
    if (1 << max_bits) < len(used):
        raise ValueError("too many symbols for max_bits")

    # Each item is (weight, leaf-symbols-list). Packages are pairs of items.
    leaves = sorted((freqs[s], [s]) for s in used)
    current = leaves
    for _ in range(max_bits - 1):
        packages = [(current[i][0] + current[i + 1][0], current[i][1] + current[i + 1][1])
                    for i in range(0, len(current) - 1, 2)]
        # merge two sorted lists (stable: leaves first on ties)
        merged, a, b = [], 0, 0
        while a < len(leaves) and b < len(packages):
            if leaves[a][0] <= packages[b][0]:
                merged.append(leaves[a]); a += 1
            else:
                merged.append(packages[b]); b += 1
        merged.extend(leaves[a:]); merged.extend(packages[b:])
        current = merged
    for _, syms in current[: 2 * len(used) - 2]:
        for s in syms:
            lengths[s] += 1
    return lengths


def canonical_codes(lengths: list[int]) -> list[int]:
    """RFC 1951 canonical code assignment (MSB-first code values)."""
    max_len = max(lengths) if lengths else 0
    bl_count = [0] * (max_len + 1)
    for l in lengths:
        if l:
            bl_count[l] += 1
    next_code = [0] * (max_len + 2)
    code = 0
    for bits in range(1, max_len + 1):
        code = (code + bl_count[bits - 1]) << 1
        next_code[bits] = code
    codes = [0] * len(lengths)
    for s, l in enumerate(lengths):
        if l:
            codes[s] = next_code[l]
            next_code[l] += 1
    return codes


def _reverse(v: int, n: int) -> int:
    r = 0
    for _ in range(n):
        r = (r << 1) | (v & 1)
        v >>= 1
    return r


def writer_codes(lengths: list[int]) -> list[int]:
    """Codes pre-reversed so they can be emitted with the LSB-first BitWriter."""
    return [_reverse(c, l) for c, l in zip(canonical_codes(lengths), lengths)]


class HuffmanDecoder:
    """Single-level lookup table: peek max_len bits, one index gives (sym, len)."""

    __slots__ = ("table", "max_len", "mask")

    def __init__(self, lengths: list[int]):
        max_len = max(lengths) if any(lengths) else 0
        if max_len == 0:
            raise DeflateError("empty Huffman code")
        # Kraft check: over-subscribed codes are invalid
        left = 1
        counts = [0] * (max_len + 1)
        for l in lengths:
            counts[l] += 1
        for bits in range(1, max_len + 1):
            left = (left << 1) - counts[bits]
            if left < 0:
                raise DeflateError("over-subscribed Huffman code")
        size = 1 << max_len
        table = [-1] * size
        codes = canonical_codes(lengths)
        for sym, l in enumerate(lengths):
            if not l:
                continue
            rev = _reverse(codes[sym], l)
            entry = (sym << 4) | l
            for fill in range(rev, size, 1 << l):
                table[fill] = entry
        self.table = table
        self.max_len = max_len
        self.mask = size - 1

    def decode(self, br: BitReader) -> int:
        if br.nbits < self.max_len:
            br._fill(self.max_len)
        e = self.table[br.acc & self.mask]
        if e < 0:
            raise DeflateError("invalid Huffman code in stream")
        l = e & 15
        br.acc >>= l
        br.nbits -= l
        if br.pos * 8 - br.nbits > len(br.data) * 8:
            raise DeflateError("unexpected end of compressed stream")
        return e >> 4


_FIXED_LIT_DEC = None
_FIXED_DIST_DEC = None


def _fixed_decoders():
    global _FIXED_LIT_DEC, _FIXED_DIST_DEC
    if _FIXED_LIT_DEC is None:
        _FIXED_LIT_DEC = HuffmanDecoder(FIXED_LIT_LENGTHS)
        _FIXED_DIST_DEC = HuffmanDecoder(FIXED_DIST_LENGTHS)
    return _FIXED_LIT_DEC, _FIXED_DIST_DEC


# --------------------------------------------------------------------------- #
#  LZ77 match finder                                                           #
# --------------------------------------------------------------------------- #

# level -> (max chain length, "good enough" length, lazy threshold)
LEVELS = {
    1: (4, 16, 0),
    2: (8, 32, 0),
    3: (16, 32, 8),
    4: (32, 64, 16),
    5: (64, 128, 32),
    6: (128, 128, 64),
    7: (256, 258, 128),
    8: (1024, 258, 258),
    9: (4096, 258, 258),
}

# A token is an int: 0..255 = literal byte; >= 256 encodes a match as
# 256 + (length << 15 | (distance - 1)).


def lz77_tokens(data: bytes, level: int = 6) -> list[int]:
    n = len(data)
    max_chain, nice_len, lazy_len = LEVELS[level]
    head: dict[int, int] = {}
    prev = [-1] * n
    tokens: list[int] = []
    append = tokens.append

    def insert(i):
        if i + 2 < n:
            key = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
            prev[i] = head.get(key, -1)
            head[key] = i

    def find(i):
        """Longest match for position i among earlier positions (i not yet inserted)."""
        if i + 2 >= n:
            return 0, 0
        cand = head.get((data[i] << 16) | (data[i + 1] << 8) | data[i + 2], -1)
        limit = i - WINDOW
        max_len = min(MAX_MATCH, n - i)
        best_len, best_dist = 0, 0
        chain = max_chain
        while cand > limit and cand >= 0 and chain:
            chain -= 1
            # quick reject: the byte that would extend the current best must match
            if best_len == 0 or data[cand + best_len] == data[i + best_len]:
                # extend in 16-byte strides via slice comparison, then bytewise
                l = 3
                while l + 16 <= max_len and data[cand + l:cand + l + 16] == data[i + l:i + l + 16]:
                    l += 16
                while l < max_len and data[cand + l] == data[i + l]:
                    l += 1
                if l > best_len:
                    best_len, best_dist = l, i - cand
                    if l >= nice_len or l == max_len:
                        break
            cand = prev[cand]
        return best_len, best_dist

    i = 0
    pending = None  # cached find() result for position i, from the lazy check
    while i < n:
        if pending is not None:
            l, d = pending
            pending = None
        else:
            l, d = find(i)
        insert(i)
        if l >= MIN_MATCH and l < lazy_len and i + 1 < n:
            l2, d2 = find(i + 1)
            if l2 > l:
                append(data[i])  # defer: a better match starts one byte later
                pending = (l2, d2)
                i += 1
                continue
        if l >= MIN_MATCH:
            append(256 + ((l << 15) | (d - 1)))
            for j in range(i + 1, i + l):
                insert(j)
            i += l
        else:
            append(data[i])
            i += 1
    return tokens


# --------------------------------------------------------------------------- #
#  Block encoder                                                               #
# --------------------------------------------------------------------------- #

def _rle_code_lengths(lengths: list[int]):
    """Run-length encode code lengths with symbols 16/17/18. Yields (sym, extra)."""
    out = []
    i, n = 0, len(lengths)
    while i < n:
        v = lengths[i]
        run = 1
        while i + run < n and lengths[i + run] == v:
            run += 1
        if v == 0:
            r = run
            while r >= 11:
                k = min(r, 138); out.append((18, k - 11)); r -= k
            if r >= 3:
                out.append((17, r - 3)); r = 0
            out.extend((0, 0) for _ in range(r))
        else:
            out.append((v, 0))
            r = run - 1
            while r >= 3:
                k = min(r, 6); out.append((16, k - 3)); r -= k
            out.extend((v, 0) for _ in range(r))
        i += run
    return out


CL_EXTRA_BITS = {16: 2, 17: 3, 18: 7}


def _token_stats(tokens):
    lit_freq = [0] * 286
    dist_freq = [0] * 30
    extra_bits = 0
    for t in tokens:
        if t < 256:
            lit_freq[t] += 1
        else:
            m = t - 256
            lc, le, _ = _LEN_LOOKUP[m >> 15]
            dc, de, _ = _DIST_LOOKUP[(m & 0x7FFF) + 1]
            lit_freq[257 + lc] += 1
            dist_freq[dc] += 1
            extra_bits += le + de
    lit_freq[256] += 1  # end-of-block
    return lit_freq, dist_freq, extra_bits


def _dynamic_header(lit_lengths, dist_lengths):
    hlit = max(257, max(s for s in range(286) if lit_lengths[s]) + 1)
    used_d = [s for s in range(30) if dist_lengths[s]]
    hdist = max(1, (used_d[-1] + 1) if used_d else 1)
    lens = lit_lengths[:hlit] + (dist_lengths[:hdist] if used_d else [0] * hdist)
    rle = _rle_code_lengths(lens)
    cl_freq = [0] * 19
    for s, _ in rle:
        cl_freq[s] += 1
    cl_lengths = package_merge(cl_freq, 7)
    hclen = 19
    while hclen > 4 and cl_lengths[CL_ORDER[hclen - 1]] == 0:
        hclen -= 1
    bits = 5 + 5 + 4 + 3 * hclen
    for s, _ in rle:
        bits += cl_lengths[s] + CL_EXTRA_BITS.get(s, 0)
    return hlit, hdist, hclen, rle, cl_lengths, bits


def _cost(freq, lengths):
    return sum(f * l for f, l in zip(freq, lengths))


def write_block(bw: BitWriter, tokens, raw: bytes, final: bool, stats: list | None = None):
    lit_freq, dist_freq, extra = _token_stats(tokens)

    lit_lengths = package_merge(lit_freq, 15)
    dist_lengths = package_merge(dist_freq, 15)
    if not any(dist_lengths):  # no matches: emit a dummy one-symbol distance code
        dist_lengths[0] = 1
    hlit, hdist, hclen, rle, cl_lengths, hdr_bits = _dynamic_header(lit_lengths, dist_lengths)

    dyn_bits = 3 + hdr_bits + _cost(lit_freq, lit_lengths) + _cost(dist_freq, dist_lengths) + extra
    fix_bits = 3 + _cost(lit_freq, FIXED_LIT_LENGTHS) + _cost(dist_freq, FIXED_DIST_LENGTHS) + extra
    pad = (8 - ((bw.nbits + 3) & 7)) & 7
    nstored = (len(raw) + 65534) // 65535 or 1
    stored_bits = 3 + pad + nstored * 32 + 8 * len(raw) + (nstored - 1) * 8  # later headers ~1 byte

    choice = min((stored_bits, "stored"), (fix_bits, "fixed"), (dyn_bits, "dynamic"))[1]
    start = bw.bit_length()

    if choice == "stored":
        for k in range(nstored):
            chunk = raw[k * 65535:(k + 1) * 65535]
            last = final and k == nstored - 1
            bw.write(1 if last else 0, 1)
            bw.write(0, 2)
            bw.align()
            bw.out += struct.pack("<HH", len(chunk), len(chunk) ^ 0xFFFF)
            bw.out += chunk
    else:
        bw.write(1 if final else 0, 1)
        if choice == "fixed":
            bw.write(1, 2)
            ll, dl = FIXED_LIT_LENGTHS, FIXED_DIST_LENGTHS
        else:
            bw.write(2, 2)
            ll, dl = lit_lengths, dist_lengths
            bw.write(hlit - 257, 5)
            bw.write(hdist - 1, 5)
            bw.write(hclen - 4, 4)
            for k in range(hclen):
                bw.write(cl_lengths[CL_ORDER[k]], 3)
            cl_codes = writer_codes(cl_lengths)
            for s, x in rle:
                bw.write(cl_codes[s], cl_lengths[s])
                if s >= 16:
                    bw.write(x, CL_EXTRA_BITS[s])
        lc, dc = writer_codes(ll), writer_codes(dl)
        w = bw.write
        for t in tokens:
            if t < 256:
                w(lc[t], ll[t])
            else:
                m = t - 256
                lsym, le, lx = _LEN_LOOKUP[m >> 15]
                dsym, de, dx = _DIST_LOOKUP[(m & 0x7FFF) + 1]
                w(lc[257 + lsym], ll[257 + lsym])
                if le:
                    w(lx, le)
                w(dc[dsym], dl[dsym])
                if de:
                    w(dx, de)
        w(lc[256], ll[256])

    if stats is not None:
        stats.append({"type": choice, "in": len(raw), "bits": bw.bit_length() - start,
                      "tokens": len(tokens),
                      "est": {"stored": stored_bits, "fixed": fix_bits, "dynamic": dyn_bits}})


BLOCK_TOKENS = 1 << 14


def deflate(data: bytes, level: int = 6, stats: list | None = None) -> bytes:
    """Compress to a raw DEFLATE stream."""
    bw = BitWriter()
    if level == 0:
        write_block_stored_only(bw, data)
        return bw.getvalue()
    if not data:
        write_block(bw, [], b"", True, stats)
        return bw.getvalue()
    tokens = lz77_tokens(data, level)
    pos = 0
    for start in range(0, len(tokens), BLOCK_TOKENS):
        chunk = tokens[start:start + BLOCK_TOKENS]
        nbytes = sum(((t - 256) >> 15) if t >= 256 else 1 for t in chunk)
        write_block(bw, chunk, data[pos:pos + nbytes],
                    start + BLOCK_TOKENS >= len(tokens), stats)
        pos += nbytes
    assert pos == len(data)
    return bw.getvalue()


def write_block_stored_only(bw: BitWriter, data: bytes):
    n = max(1, (len(data) + 65534) // 65535)
    for k in range(n):
        chunk = data[k * 65535:(k + 1) * 65535]
        bw.write(1 if k == n - 1 else 0, 1)
        bw.write(0, 2)
        bw.align()
        bw.out += struct.pack("<HH", len(chunk), len(chunk) ^ 0xFFFF)
        bw.out += chunk


# --------------------------------------------------------------------------- #
#  Inflate                                                                     #
# --------------------------------------------------------------------------- #

def _read_dynamic_tables(br: BitReader):
    hlit = br.bits(5) + 257
    hdist = br.bits(5) + 1
    hclen = br.bits(4) + 4
    if hlit > 286 or hdist > 30:
        raise DeflateError("bad dynamic block header counts")
    cl_lengths = [0] * 19
    for k in range(hclen):
        cl_lengths[CL_ORDER[k]] = br.bits(3)
    cl_dec = HuffmanDecoder(cl_lengths)
    lengths = []
    while len(lengths) < hlit + hdist:
        sym = cl_dec.decode(br)
        if sym < 16:
            lengths.append(sym)
        elif sym == 16:
            if not lengths:
                raise DeflateError("repeat code with no previous length")
            lengths.extend([lengths[-1]] * (3 + br.bits(2)))
        elif sym == 17:
            lengths.extend([0] * (3 + br.bits(3)))
        else:
            lengths.extend([0] * (11 + br.bits(7)))
    if len(lengths) > hlit + hdist:
        raise DeflateError("code lengths overflow")
    lit, dist = lengths[:hlit], lengths[hlit:]
    if lit[256] == 0:
        raise DeflateError("no end-of-block code")
    lit_dec = HuffmanDecoder(lit)
    dist_dec = HuffmanDecoder(dist) if any(dist) else None
    return lit_dec, dist_dec


def inflate(data: bytes, pos: int = 0, stats: list | None = None):
    """Decompress a raw DEFLATE stream starting at byte `pos`.

    Returns (output bytes, byte offset just past the stream).
    """
    br = BitReader(data, pos)
    out = bytearray()
    while True:
        start_bit, start_out = br.bit_pos(), len(out)
        final = br.bits(1)
        btype = br.bits(2)
        if btype == 0:
            br.align()
            p = br.byte_pos()
            if p + 4 > len(data):
                raise DeflateError("truncated stored block header")
            ln, nln = struct.unpack_from("<HH", data, p)
            if ln ^ nln != 0xFFFF:
                raise DeflateError("stored block length check failed")
            if p + 4 + ln > len(data):
                raise DeflateError("truncated stored block")
            out += data[p + 4:p + 4 + ln]
            br.pos, br.acc, br.nbits = p + 4 + ln, 0, 0
            kind = "stored"
        elif btype == 3:
            raise DeflateError("reserved block type 3")
        else:
            if btype == 1:
                lit_dec, dist_dec = _fixed_decoders()
                kind = "fixed"
            else:
                lit_dec, dist_dec = _read_dynamic_tables(br)
                kind = "dynamic"
            ldecode = lit_dec.decode
            while True:
                sym = ldecode(br)
                if sym < 256:
                    out.append(sym)
                    continue
                if sym == 256:
                    break
                sym -= 257
                if sym >= 29:
                    raise DeflateError("invalid length symbol")
                length = LEN_BASE[sym] + br.bits(LEN_EXTRA[sym])
                if dist_dec is None:
                    raise DeflateError("match in block with no distance code")
                dsym = dist_dec.decode(br)
                if dsym >= 30:
                    raise DeflateError("invalid distance symbol")
                dist = DIST_BASE[dsym] + br.bits(DIST_EXTRA[dsym])
                if dist > len(out):
                    raise DeflateError("distance reaches before start of output")
                s = len(out) - dist
                if dist >= length:
                    out += out[s:s + length]
                else:  # overlapping copy = repeating the last `dist` bytes
                    chunk = out[s:]
                    out += (chunk * (length // dist + 1))[:length]
        if stats is not None:
            stats.append({"type": kind, "out": len(out) - start_out,
                          "bits": br.bit_pos() - start_bit, "final": bool(final)})
        if final:
            br.align()
            return bytes(out), br.byte_pos()


# --------------------------------------------------------------------------- #
#  gzip container                                                              #
# --------------------------------------------------------------------------- #

FTEXT, FHCRC, FEXTRA, FNAME, FCOMMENT = 1, 2, 4, 8, 16


def gzip_compress(data: bytes, level: int = 6, filename: str | None = None,
                  mtime: int | None = None, stats: list | None = None) -> bytes:
    flags = FNAME if filename else 0
    xfl = 2 if level >= 9 else 4 if level == 1 else 0
    header = struct.pack("<BBBBIBB", 0x1F, 0x8B, 8, flags,
                         int(time.time()) if mtime is None else mtime, xfl, 3)
    if filename:
        header += filename.encode("latin-1", "replace") + b"\0"
    body = deflate(data, level, stats)
    return header + body + struct.pack("<II", crc32(data), len(data) & 0xFFFFFFFF)


def gzip_decompress(data: bytes, stats: list | None = None) -> bytes:
    """Decompress all gzip members in `data` (concatenated members are allowed)."""
    out = bytearray()
    pos = 0
    while pos < len(data):
        if len(data) - pos < 18 or data[pos] != 0x1F or data[pos + 1] != 0x8B:
            if out and not any(data[pos:]):  # tolerate trailing zero padding
                break
            raise DeflateError("not a gzip file (bad magic)")
        cm, flg = data[pos + 2], data[pos + 3]
        if cm != 8:
            raise DeflateError(f"unsupported compression method {cm}")
        p = pos + 10
        if flg & FEXTRA:
            (xlen,) = struct.unpack_from("<H", data, p)
            p += 2 + xlen
        if flg & FNAME:
            p = data.index(b"\0", p) + 1
        if flg & FCOMMENT:
            p = data.index(b"\0", p) + 1
        if flg & FHCRC:
            p += 2
        member, p = inflate(data, p, stats)
        if p + 8 > len(data):
            raise DeflateError("truncated gzip trailer")
        crc, isize = struct.unpack_from("<II", data, p)
        if crc != crc32(member):
            raise DeflateError("CRC-32 mismatch: data is corrupt")
        if isize != len(member) & 0xFFFFFFFF:
            raise DeflateError("ISIZE mismatch: data is corrupt")
        out += member
        pos = p + 8
    return bytes(out)


# --------------------------------------------------------------------------- #
#  CLI                                                                         #
# --------------------------------------------------------------------------- #

def _human(n: float) -> str:
    for unit in ("B", "KiB", "MiB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GiB"


def cmd_compress(args):
    with open(args.file, "rb") as f:
        data = f.read()
    t0 = time.perf_counter()
    stats = []
    gz = gzip_compress(data, args.level, os.path.basename(args.file), stats=stats)
    dt = time.perf_counter() - t0
    out = args.output or args.file + ".gz"
    with open(out, "wb") as f:
        f.write(gz)
    kinds = {}
    for s in stats:
        kinds[s["type"]] = kinds.get(s["type"], 0) + 1
    ratio = len(gz) / len(data) * 100 if data else 100
    print(f"{args.file}: {_human(len(data))} -> {_human(len(gz))} ({ratio:.1f}%) "
          f"in {dt:.2f}s, blocks: " + ", ".join(f"{v} {k}" for k, v in sorted(kinds.items()))
          + f"  => {out}")


def cmd_decompress(args):
    with open(args.file, "rb") as f:
        gz = f.read()
    t0 = time.perf_counter()
    data = gzip_decompress(gz)
    dt = time.perf_counter() - t0
    out = args.output or (args.file[:-3] if args.file.endswith(".gz") else args.file + ".out")
    if args.output == "-":
        sys.stdout.buffer.write(data)
        return
    with open(out, "wb") as f:
        f.write(data)
    print(f"{args.file}: {_human(len(gz))} -> {_human(len(data))} in {dt:.2f}s, CRC ok  => {out}")


def cmd_inspect(args):
    with open(args.file, "rb") as f:
        gz = f.read()
    stats = []
    data = gzip_decompress(gz, stats)
    print(f"{args.file}: {len(gz)} bytes compressed, {len(data)} bytes original, "
          f"{len(stats)} block(s), CRC-32 {crc32(data):08x} ok\n")
    print(f"  {'#':>3}  {'type':<8} {'output':>10} {'compressed':>11}  {'bits/byte':>9}")
    for i, s in enumerate(stats):
        bpb = s["bits"] / s["out"] if s["out"] else 0
        bar = "#" * min(40, round(bpb * 5))
        print(f"  {i:>3}  {s['type']:<8} {s['out']:>10} {s['bits'] // 8:>11}  {bpb:>9.3f}  {bar}")


def _bench_corpus():
    here = os.path.dirname(os.path.abspath(__file__))
    src = open(os.path.join(here, "pydeflate.py"), "rb").read()
    import random
    rng = random.Random(1951)
    words = ("the of and to in is that for it as with was on be by this are from at or "
             "an which have not but they his all were can there been one has more if "
             "their when will would who so no huffman window match literal distance "
             "block tree code length stream byte bits symbol").split()
    weights = [1 / (k + 1) for k in range(len(words))]  # Zipf-ish
    text = []
    for _ in range(12000):
        text.append(rng.choices(words, weights)[0])
        if rng.random() < 0.08:
            text.append(".\n" if rng.random() < 0.3 else ",")
    english = " ".join(text).encode()
    csv = "\n".join(f"{i},{rng.randint(1000, 99999)},{rng.choice(['tbilisi','batumi','kutaisi','rustavi'])},"
                    f"{rng.random():.4f}" for i in range(4000)).encode()
    noise = bytes(rng.getrandbits(8) for _ in range(40000))
    dna = bytes(rng.choice(b"ACGT") for _ in range(60000))
    return [("pydeflate.py (source)", src), ("zipf english", english),
            ("csv table", csv), ("random DNA", dna), ("random bytes", noise),
            ("one byte x 100k", b"z" * 100000)]


def cmd_bench(args):
    try:
        import zlib  # only used for comparison / interop checking
    except ImportError:
        zlib = None
    print(f"pydeflate level {args.level} vs zlib level {args.level} (raw DEFLATE sizes)\n")
    print(f"  {'input':<22} {'size':>9} {'pydeflate':>10} {'zlib':>9} {'diff':>7}  "
          f"{'comp':>7} {'decomp':>7}  interop")
    for name, data in _bench_corpus():
        t0 = time.perf_counter()
        ours = deflate(data, args.level)
        t1 = time.perf_counter()
        back, _ = inflate(ours)
        t2 = time.perf_counter()
        assert back == data, name
        ok = "-"
        zsize = "-"
        diff = ""
        if zlib:
            co = zlib.compressobj(args.level, zlib.DEFLATED, -15)
            theirs = co.compress(data) + co.flush()
            zsize = str(len(theirs))
            diff = f"{(len(ours) / len(theirs) - 1) * 100:+.1f}%"
            ok = "ok" if (zlib.decompress(ours, -15) == data and inflate(theirs)[0] == data) else "FAIL"
        print(f"  {name:<22} {len(data):>9} {len(ours):>10} {zsize:>9} {diff:>7}  "
              f"{t1 - t0:>6.2f}s {t2 - t1:>6.2f}s  {ok}")


def main(argv=None):
    p = argparse.ArgumentParser(prog="pydeflate", description=__doc__.strip().splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compress", help="gzip-compress a file")
    c.add_argument("file")
    c.add_argument("-o", "--output")
    c.add_argument("-l", "--level", type=int, default=6, choices=range(0, 10))
    c.set_defaults(fn=cmd_compress)
    d = sub.add_parser("decompress", help="decompress a .gz file ('-o -' for stdout)")
    d.add_argument("file")
    d.add_argument("-o", "--output")
    d.set_defaults(fn=cmd_decompress)
    i = sub.add_parser("inspect", help="show the DEFLATE blocks inside a .gz file")
    i.add_argument("file")
    i.set_defaults(fn=cmd_inspect)
    b = sub.add_parser("bench", help="compare against zlib on a built-in corpus")
    b.add_argument("-l", "--level", type=int, default=6, choices=range(1, 10))
    b.set_defaults(fn=cmd_bench)
    args = p.parse_args(argv)
    try:
        args.fn(args)
    except DeflateError as e:
        sys.exit(f"pydeflate: {e}")


if __name__ == "__main__":
    main()
