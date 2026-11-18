//! Arbitrary-precision integers in base 10^6, with NTT multiplication over
//! the "Goldilocks" prime p = 2^64 - 2^32 + 1.
//!
//! Magnitudes are little-endian slices of u32 limbs, each < 10^6, with no
//! leading zero limbs (zero is the empty slice). Every function returns a
//! freshly allocated result; the caller owns it and frees the inputs.
//! Decimal limbs mean the final digits never need a radix conversion.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error;

pub const BASE: u32 = 1_000_000;
pub const BASE_DIGITS: usize = 6;

/// Below this many limbs in the smaller operand, schoolbook beats the NTT.
pub var ntt_threshold: usize = 48;

// ---------------------------------------------------------------------------
// Arithmetic mod p = 2^64 - 2^32 + 1
// ---------------------------------------------------------------------------

pub const P: u64 = 0xFFFF_FFFF_0000_0001;
const EPS: u64 = 0xFFFF_FFFF; // 2^64 mod p
const GENERATOR: u64 = 7; // generates the full multiplicative group

/// Reduce a 128-bit product mod p using 2^64 = 2^32 - 1 and 2^96 = -1 (mod p).
pub inline fn reduce128(x: u128) u64 {
    const lo: u64 = @truncate(x);
    const hi: u64 = @truncate(x >> 64);
    const hi_hi = hi >> 32;
    const hi_lo = hi & EPS;
    const s = @subWithOverflow(lo, hi_hi);
    var t0 = s[0];
    if (s[1] != 0) t0 -%= EPS;
    const t1 = hi_lo * EPS;
    const a = @addWithOverflow(t0, t1);
    var r = a[0];
    if (a[1] != 0) r +%= EPS;
    if (r >= P) r -= P;
    return r;
}

pub inline fn mulMod(a: u64, b: u64) u64 {
    return reduce128(@as(u128, a) * b);
}

inline fn addMod(a: u64, b: u64) u64 {
    const s = @addWithOverflow(a, b);
    if (s[1] != 0) return s[0] +% EPS;
    return if (s[0] >= P) s[0] - P else s[0];
}

inline fn subMod(a: u64, b: u64) u64 {
    return if (a >= b) a - b else (a -% b) +% P;
}

pub fn powMod(base: u64, exp: u64) u64 {
    var r: u64 = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) r = mulMod(r, b);
        b = mulMod(b, b);
    }
    return r;
}

/// In-place iterative radix-2 NTT. `tw[i] = w^i` for i < n/2, w an n-th root of unity.
fn ntt(a: []u64, tw: []const u64) void {
    const n = a.len;
    // bit reversal permutation
    var j: usize = 0;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std.mem.swap(u64, &a[i], &a[j]);
    }
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len >> 1;
        const step = n / len;
        var s: usize = 0;
        while (s < n) : (s += len) {
            var k: usize = 0;
            while (k < half) : (k += 1) {
                const u = a[s + k];
                const v = mulMod(a[s + k + half], tw[k * step]);
                a[s + k] = addMod(u, v);
                a[s + k + half] = subMod(u, v);
            }
        }
    }
}

fn twiddles(tw: []u64, w: u64) void {
    var x: u64 = 1;
    for (tw) |*t| {
        t.* = x;
        x = mulMod(x, w);
    }
}

// ---------------------------------------------------------------------------
// Magnitudes
// ---------------------------------------------------------------------------

/// Shrink an owned buffer so it has no leading zero limbs.
pub fn trimOwned(alloc: Allocator, buf: []u32) Error![]u32 {
    var n = buf.len;
    while (n > 0 and buf[n - 1] == 0) n -= 1;
    if (n == buf.len) return buf;
    return alloc.realloc(buf, n);
}

pub fn fromU64(alloc: Allocator, v: u64) Error![]u32 {
    var tmp: [4]u32 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (x /= BASE) {
        tmp[n] = @intCast(x % BASE);
        n += 1;
    }
    const r = try alloc.alloc(u32, n);
    @memcpy(r, tmp[0..n]);
    return r;
}

pub fn dup(alloc: Allocator, a: []const u32) Error![]u32 {
    return alloc.dupe(u32, a);
}

pub fn cmpMag(a: []const u32, b: []const u32) std.math.Order {
    if (a.len != b.len) return std.math.order(a.len, b.len);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return std.math.order(a[i], b[i]);
    }
    return .eq;
}

pub fn addMag(alloc: Allocator, a: []const u32, b: []const u32) Error![]u32 {
    const big = if (a.len >= b.len) a else b;
    const small = if (a.len >= b.len) b else a;
    const r = try alloc.alloc(u32, big.len + 1);
    var carry: u32 = 0;
    for (big, 0..) |x, i| {
        var t = x + carry + (if (i < small.len) small[i] else 0);
        carry = 0;
        if (t >= BASE) {
            t -= BASE;
            carry = 1;
        }
        r[i] = t;
    }
    r[big.len] = carry;
    return trimOwned(alloc, r);
}

/// a - b, requires a >= b.
pub fn subMag(alloc: Allocator, a: []const u32, b: []const u32) Error![]u32 {
    std.debug.assert(cmpMag(a, b) != .lt);
    const r = try alloc.alloc(u32, a.len);
    var borrow: u32 = 0;
    for (a, 0..) |x, i| {
        const y = (if (i < b.len) b[i] else 0) + borrow;
        if (x >= y) {
            r[i] = x - y;
            borrow = 0;
        } else {
            r[i] = x + BASE - y;
            borrow = 1;
        }
    }
    return trimOwned(alloc, r);
}

pub fn mulSmallMag(alloc: Allocator, a: []const u32, m: u64) Error![]u32 {
    if (a.len == 0 or m == 0) return alloc.alloc(u32, 0);
    const r = try alloc.alloc(u32, a.len + 4);
    var carry: u128 = 0;
    for (a, 0..) |x, i| {
        const t = @as(u128, x) * m + carry;
        r[i] = @intCast(t % BASE);
        carry = t / BASE;
    }
    var i = a.len;
    while (i < r.len) : (i += 1) {
        r[i] = @intCast(carry % BASE);
        carry /= BASE;
    }
    return trimOwned(alloc, r);
}

/// Prepend k zero limbs (multiply by BASE^k).
pub fn shiftMag(alloc: Allocator, a: []const u32, k: usize) Error![]u32 {
    if (a.len == 0) return alloc.alloc(u32, 0);
    const r = try alloc.alloc(u32, a.len + k);
    @memset(r[0..k], 0);
    @memcpy(r[k..], a);
    return r;
}

pub fn mulSchool(alloc: Allocator, a: []const u32, b: []const u32) Error![]u32 {
    if (a.len == 0 or b.len == 0) return alloc.alloc(u32, 0);
    const r = try alloc.alloc(u64, a.len + b.len);
    defer alloc.free(r);
    @memset(r, 0);
    for (a, 0..) |x, i| {
        if (x == 0) continue;
        var carry: u64 = 0;
        for (b, 0..) |y, j| {
            const t = r[i + j] + @as(u64, x) * y + carry;
            r[i + j] = t % BASE;
            carry = t / BASE;
        }
        r[i + b.len] += carry;
    }
    const out = try alloc.alloc(u32, r.len);
    var carry: u64 = 0;
    for (r, 0..) |x, i| {
        const t = x + carry;
        out[i] = @intCast(t % BASE);
        carry = t / BASE;
    }
    return trimOwned(alloc, out);
}

pub fn mulNtt(alloc: Allocator, a: []const u32, b: []const u32) Error![]u32 {
    if (a.len == 0 or b.len == 0) return alloc.alloc(u32, 0);
    // Each output coefficient is < min(len) * (10^6)^2 and must stay below p.
    std.debug.assert(@min(a.len, b.len) < 18_000_000);
    const rl = a.len + b.len;
    var n: usize = 1;
    while (n < rl) n <<= 1;
    const square = a.ptr == b.ptr and a.len == b.len;

    const fa = try alloc.alloc(u64, n);
    defer alloc.free(fa);
    for (fa, 0..) |*x, i| x.* = if (i < a.len) a[i] else 0;
    const fb = if (square) fa else try alloc.alloc(u64, n);
    defer if (!square) alloc.free(fb);
    if (!square) {
        for (fb, 0..) |*x, i| x.* = if (i < b.len) b[i] else 0;
    }

    const tw = try alloc.alloc(u64, @max(n / 2, 1));
    defer alloc.free(tw);
    const w = powMod(GENERATOR, (P - 1) / n);
    twiddles(tw, w);
    ntt(fa, tw);
    if (!square) ntt(fb, tw);
    for (fa, fb) |*x, y| x.* = mulMod(x.*, y);
    twiddles(tw, powMod(w, P - 2));
    ntt(fa, tw);
    const ninv = powMod(n, P - 2);

    const out = try alloc.alloc(u32, rl);
    var carry: u128 = 0;
    for (out, 0..) |*o, i| {
        const t = @as(u128, mulMod(fa[i], ninv)) + carry;
        o.* = @intCast(t % BASE);
        carry = t / BASE;
    }
    std.debug.assert(carry == 0);
    return trimOwned(alloc, out);
}

pub fn mulMag(alloc: Allocator, a: []const u32, b: []const u32) Error![]u32 {
    if (@min(a.len, b.len) < ntt_threshold) return mulSchool(alloc, a, b);
    return mulNtt(alloc, a, b);
}

// ---------------------------------------------------------------------------
// Signed integers
// ---------------------------------------------------------------------------

pub const Int = struct {
    neg: bool = false,
    mag: []u32,

    pub fn deinit(self: Int, alloc: Allocator) void {
        alloc.free(self.mag);
    }
    pub fn isZero(self: Int) bool {
        return self.mag.len == 0;
    }
    pub fn negated(self: Int) Int {
        return .{ .neg = !self.neg and self.mag.len != 0, .mag = self.mag };
    }
};

fn mk(neg: bool, mag: []u32) Int {
    return .{ .neg = neg and mag.len != 0, .mag = mag };
}

pub fn intFromU64(alloc: Allocator, v: u64) Error!Int {
    return mk(false, try fromU64(alloc, v));
}

pub fn intAdd(alloc: Allocator, a: Int, b: Int) Error!Int {
    if (a.neg == b.neg) return mk(a.neg, try addMag(alloc, a.mag, b.mag));
    if (cmpMag(a.mag, b.mag) != .lt) return mk(a.neg, try subMag(alloc, a.mag, b.mag));
    return mk(b.neg, try subMag(alloc, b.mag, a.mag));
}

pub fn intSub(alloc: Allocator, a: Int, b: Int) Error!Int {
    return intAdd(alloc, a, b.negated());
}

pub fn intMul(alloc: Allocator, a: Int, b: Int) Error!Int {
    return mk(a.neg != b.neg, try mulMag(alloc, a.mag, b.mag));
}

pub fn intMulSmall(alloc: Allocator, a: Int, m: u64) Error!Int {
    return mk(a.neg, try mulSmallMag(alloc, a.mag, m));
}
