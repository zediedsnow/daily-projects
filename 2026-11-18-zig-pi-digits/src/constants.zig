//! The constants: pi (Chudnovsky), e (factorial series), sqrt(2), phi.
//! Series are summed exactly as one huge fraction by binary splitting.

const std = @import("std");
const big = @import("bigint.zig");
const fl = @import("float.zig");
const Allocator = std.mem.Allocator;
const Error = big.Error;
const Int = big.Int;
const Float = fl.Float;

pub const Timings = struct {
    series_ns: u64 = 0,
    root_ns: u64 = 0,
    divide_ns: u64 = 0,
    terms: u64 = 0,
};

/// Limbs of working precision for `digits` decimals (plus guard limbs).
pub fn limbsFor(digits: usize) usize {
    return digits / big.BASE_DIGITS + 4;
}

// ---------------------------------------------------------------------------
// Chudnovsky:  1/pi = 12 * sum_k (-1)^k (6k)! (13591409 + 545140134k)
//                                  / ((3k)! (k!)^3 640320^(3k+3/2))
// Each term adds ~14.18 digits.
// ---------------------------------------------------------------------------

const PQT = struct {
    p: ?Int,
    q: Int,
    t: Int,
    fn deinit(self: PQT, alloc: Allocator) void {
        if (self.p) |p| p.deinit(alloc);
        self.q.deinit(alloc);
        self.t.deinit(alloc);
    }
};

const BsArgs = struct {
    alloc: Allocator,
    a: u64,
    b: u64,
    need_p: bool,
    depth: u32,
    par_depth: u32,
    out: Error!PQT = undefined,
};

fn chudLeaf(alloc: Allocator, a: u64, need_p: bool) Error!PQT {
    var p: Int = undefined;
    var q: Int = undefined;
    if (a == 0) {
        p = try big.intFromU64(alloc, 1);
        q = try big.intFromU64(alloc, 1);
    } else {
        // (6a-5)(2a-1)(6a-1) overflows u64 past ~10M digits, so multiply in bigints
        const p1 = try big.intFromU64(alloc, (6 * a - 5) * (2 * a - 1));
        defer p1.deinit(alloc);
        p = try big.intMulSmall(alloc, p1, 6 * a - 1);
        // q = a^3 * 640320^3 / 24 = a^2 * a * 640320^2 * 26680
        const q1 = try big.intFromU64(alloc, a * a);
        defer q1.deinit(alloc);
        const q2 = try big.intMulSmall(alloc, q1, a);
        defer q2.deinit(alloc);
        const q3 = try big.intMulSmall(alloc, q2, 640320 * 640320);
        defer q3.deinit(alloc);
        q = try big.intMulSmall(alloc, q3, 26680);
    }
    var t = try big.intMulSmall(alloc, p, 13591409 + 545140134 * a);
    if (a & 1 == 1) t = t.negated();
    if (!need_p) {
        p.deinit(alloc);
        return .{ .p = null, .q = q, .t = t };
    }
    return .{ .p = p, .q = q, .t = t };
}

fn chudBs(args: *BsArgs) void {
    args.out = chudBsImpl(args.alloc, args.a, args.b, args.need_p, args.depth, args.par_depth);
}

fn chudBsImpl(alloc: Allocator, a: u64, b: u64, need_p: bool, depth: u32, par_depth: u32) Error!PQT {
    if (b - a == 1) return chudLeaf(alloc, a, need_p);
    const m = (a + b) / 2;
    var left = BsArgs{ .alloc = alloc, .a = a, .b = m, .need_p = true, .depth = depth + 1, .par_depth = par_depth };
    var right = BsArgs{ .alloc = alloc, .a = m, .b = b, .need_p = need_p, .depth = depth + 1, .par_depth = par_depth };
    if (depth < par_depth and b - a > 64) {
        const th = std.Thread.spawn(.{}, chudBs, .{&left}) catch null;
        chudBs(&right);
        if (th) |t| t.join() else chudBs(&left);
    } else {
        chudBs(&left);
        chudBs(&right);
    }
    const l = try left.out;
    defer l.deinit(alloc);
    const r = try right.out;
    defer r.deinit(alloc);
    // T = Q_r * T_l + P_l * T_r ; Q = Q_l * Q_r ; P = P_l * P_r
    const t1 = try big.intMul(alloc, r.q, l.t);
    defer t1.deinit(alloc);
    const t2 = try big.intMul(alloc, l.p.?, r.t);
    defer t2.deinit(alloc);
    const t = try big.intAdd(alloc, t1, t2);
    const q = try big.intMul(alloc, l.q, r.q);
    const p: ?Int = if (need_p) try big.intMul(alloc, l.p.?, r.p.?) else null;
    return .{ .p = p, .q = q, .t = t };
}

fn parDepth(threads: u32) u32 {
    var d: u32 = 0;
    while ((@as(u32, 1) << @intCast(d)) < threads) d += 1;
    return d;
}

pub fn pi(alloc: Allocator, digits: usize, threads: u32, tm: *Timings) Error!Float {
    const p = limbsFor(digits);
    const terms: u64 = @intFromFloat(@as(f64, @floatFromInt(digits)) / 14.181647462725477 + 2);
    tm.terms = terms;
    var timer = std.time.Timer.start() catch unreachable;

    const pqt = try chudBsImpl(alloc, 0, terms, false, 0, parDepth(threads));
    defer pqt.deinit(alloc);
    tm.series_ns = timer.lap();

    // pi = 426880 * sqrt(10005) * Q / T
    const c = try fl.fromU64(alloc, 10005);
    defer c.deinit(alloc);
    const isq = try fl.invSqrt(alloc, c, p);
    defer isq.deinit(alloc);
    const sq = try fl.mulSmall(alloc, isq, 10005 * 426880); // 426880*sqrt(10005)
    defer sq.deinit(alloc);
    tm.root_ns = timer.lap();

    const tf0 = try fl.fromInt(alloc, pqt.t);
    const tf = try fl.trunc(alloc, tf0, p + 2);
    defer tf.deinit(alloc);
    const rt = try fl.recip(alloc, tf, p);
    defer rt.deinit(alloc);
    const qf0 = try fl.fromInt(alloc, pqt.q);
    const qf = try fl.trunc(alloc, qf0, p + 2);
    defer qf.deinit(alloc);
    const qr = try fl.mul(alloc, qf, rt, p + 2);
    defer qr.deinit(alloc);
    const res = try fl.mul(alloc, qr, sq, p + 2);
    tm.divide_ns = timer.lap();
    return res;
}

// ---------------------------------------------------------------------------
// e = sum 1/k!  ->  e = 1 + P(0,N)/Q(0,N) with Q(a,b) = (a+1)...b
// ---------------------------------------------------------------------------

const PQ = struct { p: Int, q: Int };

fn eBs(alloc: Allocator, a: u64, b: u64) Error!PQ {
    if (b - a == 1) return .{ .p = try big.intFromU64(alloc, 1), .q = try big.intFromU64(alloc, b) };
    const m = (a + b) / 2;
    const l = try eBs(alloc, a, m);
    defer l.p.deinit(alloc);
    defer l.q.deinit(alloc);
    const r = try eBs(alloc, m, b);
    defer r.p.deinit(alloc);
    defer r.q.deinit(alloc);
    const pq = try big.intMul(alloc, l.p, r.q);
    defer pq.deinit(alloc);
    return .{ .p = try big.intAdd(alloc, pq, r.p), .q = try big.intMul(alloc, l.q, r.q) };
}

pub fn e(alloc: Allocator, digits: usize, tm: *Timings) Error!Float {
    const p = limbsFor(digits);
    // smallest N with log10(N!) > digits + 20
    var n: u64 = 1;
    var lg: f64 = 0;
    while (lg < @as(f64, @floatFromInt(digits)) + 20) : (n += 1) lg += std.math.log10(@as(f64, @floatFromInt(n + 1)));
    tm.terms = n;
    var timer = std.time.Timer.start() catch unreachable;
    const pq = try eBs(alloc, 0, n);
    defer pq.p.deinit(alloc);
    defer pq.q.deinit(alloc);
    tm.series_ns = timer.lap();
    const qf = try fl.trunc(alloc, try fl.fromInt(alloc, pq.q), p + 2);
    defer qf.deinit(alloc);
    const rq = try fl.recip(alloc, qf, p);
    defer rq.deinit(alloc);
    const pf = try fl.trunc(alloc, try fl.fromInt(alloc, pq.p), p + 2);
    defer pf.deinit(alloc);
    const frac = try fl.mul(alloc, pf, rq, p + 2);
    defer frac.deinit(alloc);
    const one = try fl.fromU64(alloc, 1);
    defer one.deinit(alloc);
    const res = try fl.add(alloc, one, frac);
    tm.divide_ns = timer.lap();
    return res;
}

/// sqrt(n) = n * (1/sqrt(n))
pub fn sqrtInt(alloc: Allocator, n: u64, digits: usize, tm: *Timings) Error!Float {
    var timer = std.time.Timer.start() catch unreachable;
    const x = try fl.fromU64(alloc, n);
    defer x.deinit(alloc);
    const y = try fl.invSqrt(alloc, x, limbsFor(digits));
    defer y.deinit(alloc);
    const r = try fl.mulSmall(alloc, y, n);
    tm.root_ns = timer.lap();
    return r;
}

/// phi = (1 + sqrt 5) / 2
pub fn phi(alloc: Allocator, digits: usize, tm: *Timings) Error!Float {
    const s = try sqrtInt(alloc, 5, digits, tm);
    defer s.deinit(alloc);
    const one = try fl.fromU64(alloc, 1);
    defer one.deinit(alloc);
    const t = try fl.add(alloc, one, s);
    defer t.deinit(alloc);
    return fl.half(alloc, t);
}
