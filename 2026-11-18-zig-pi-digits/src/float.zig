//! Big floating point: value = m * BASE^e with a signed big-integer mantissa.
//! Division and square roots are done by Newton iteration with precision
//! doubling, so they cost a small constant times one full multiplication.

const std = @import("std");
const big = @import("bigint.zig");
const Allocator = std.mem.Allocator;
const Error = big.Error;
const Int = big.Int;
const BASE = big.BASE;

pub const Float = struct {
    m: Int,
    e: i64,

    pub fn deinit(self: Float, alloc: Allocator) void {
        self.m.deinit(alloc);
    }
};

pub fn fromInt(alloc: Allocator, a: Int) Error!Float {
    return .{ .m = .{ .neg = a.neg, .mag = try big.dup(alloc, a.mag) }, .e = 0 };
}

pub fn fromU64(alloc: Allocator, v: u64) Error!Float {
    return .{ .m = try big.intFromU64(alloc, v), .e = 0 };
}

/// Keep only the top p limbs of the mantissa (truncation toward zero). Consumes x.
pub fn trunc(alloc: Allocator, x: Float, p: usize) Error!Float {
    if (x.m.mag.len <= p) return x;
    const drop = x.m.mag.len - p;
    const nm = try alloc.dupe(u32, x.m.mag[drop..]);
    const neg = x.m.neg;
    x.deinit(alloc);
    return .{ .m = .{ .neg = neg, .mag = try big.trimOwned(alloc, nm) }, .e = x.e + @as(i64, @intCast(drop)) };
}

pub fn truncCopy(alloc: Allocator, x: Float, p: usize) Error!Float {
    const c = Float{ .m = .{ .neg = x.m.neg, .mag = try big.dup(alloc, x.m.mag) }, .e = x.e };
    return trunc(alloc, c, p);
}

pub fn mul(alloc: Allocator, x: Float, y: Float, p: usize) Error!Float {
    const m = try big.intMul(alloc, x.m, y.m);
    return trunc(alloc, .{ .m = m, .e = x.e + y.e }, p);
}

pub fn mulSmall(alloc: Allocator, x: Float, k: u64) Error!Float {
    return .{ .m = try big.intMulSmall(alloc, x.m, k), .e = x.e };
}

pub fn add(alloc: Allocator, x: Float, y: Float) Error!Float {
    if (x.m.isZero()) return .{ .m = .{ .neg = y.m.neg, .mag = try big.dup(alloc, y.m.mag) }, .e = y.e };
    if (y.m.isZero()) return .{ .m = .{ .neg = x.m.neg, .mag = try big.dup(alloc, x.m.mag) }, .e = x.e };
    // align to the smaller exponent
    const hi = if (x.e >= y.e) x else y;
    const lo = if (x.e >= y.e) y else x;
    const shift: usize = @intCast(hi.e - lo.e);
    const hm = try big.shiftMag(alloc, hi.m.mag, shift);
    defer alloc.free(hm);
    const s = try big.intAdd(alloc, .{ .neg = hi.m.neg, .mag = hm }, lo.m);
    return .{ .m = s, .e = lo.e };
}

pub fn sub(alloc: Allocator, x: Float, y: Float) Error!Float {
    return add(alloc, x, .{ .m = y.m.negated(), .e = y.e });
}

/// x / 2, exactly: multiply the mantissa by 500000 and divide by BASE.
pub fn half(alloc: Allocator, x: Float) Error!Float {
    return .{ .m = try big.intMulSmall(alloc, x.m, BASE / 2), .e = x.e - 1 };
}

/// Approximate |x| as t * BASE^E with t an f64 built from the top 3 limbs.
fn topF64(x: Float) struct { t: f64, E: i64 } {
    const mg = x.m.mag;
    const k = @min(mg.len, 3);
    var t: f64 = 0;
    var i: usize = 0;
    while (i < k) : (i += 1) t = t * @as(f64, BASE) + @as(f64, @floatFromInt(mg[mg.len - 1 - i]));
    return .{ .t = t, .E = x.e + @as(i64, @intCast(mg.len - k)) };
}

/// A Float approximating v * BASE^E to ~12 significant digits.
fn seed(alloc: Allocator, v0: f64, E: i64) Error!Float {
    var v = v0;
    var k: i64 = 0;
    while (v < 1e12) : (k += 1) v *= @as(f64, BASE);
    while (v >= 1e18) : (k -= 1) v /= @as(f64, BASE);
    const m: u64 = @intFromFloat(v);
    return .{ .m = try big.intFromU64(alloc, m), .e = E - k };
}

/// Precision schedule for Newton: ..., p/4, p/2, p (in limbs), ascending.
fn schedule(buf: []usize, p: usize) []usize {
    var n: usize = 0;
    var q = p;
    while (true) {
        buf[n] = q;
        n += 1;
        if (q <= 3) break;
        q = q / 2 + 1;
    }
    std.mem.reverse(usize, buf[0..n]);
    return buf[0..n];
}

/// 1/x to about p limbs of relative precision. x must be positive.
/// Newton: y <- y + y(1 - xy). Each step doubles the number of correct limbs.
pub fn recip(alloc: Allocator, x: Float, p: usize) Error!Float {
    std.debug.assert(!x.m.neg and !x.m.isZero());
    const tp = topF64(x);
    var y = try seed(alloc, 1.0 / tp.t, -tp.E);
    var one = try fromU64(alloc, 1);
    defer one.deinit(alloc);
    var buf: [80]usize = undefined;
    for (schedule(&buf, p)) |q| {
        const qq = q + 2;
        const xt = try truncCopy(alloc, x, qq);
        defer xt.deinit(alloc);
        const xy = try mul(alloc, xt, y, qq);
        defer xy.deinit(alloc);
        const r = try sub(alloc, one, xy); // tiny: the residual error
        defer r.deinit(alloc);
        const corr = try mul(alloc, y, r, qq);
        defer corr.deinit(alloc);
        const ny = try add(alloc, y, corr);
        y.deinit(alloc);
        y = try trunc(alloc, ny, qq);
    }
    return y;
}

/// 1/sqrt(x) to about p limbs. Newton: y <- y + y(1 - x y^2)/2.
pub fn invSqrt(alloc: Allocator, x: Float, p: usize) Error!Float {
    std.debug.assert(!x.m.neg and !x.m.isZero());
    var tp = topF64(x);
    if (@mod(tp.E, 2) != 0) {
        tp.t *= @as(f64, BASE);
        tp.E -= 1;
    }
    var y = try seed(alloc, 1.0 / @sqrt(tp.t), -@divExact(tp.E, 2));
    var one = try fromU64(alloc, 1);
    defer one.deinit(alloc);
    var buf: [80]usize = undefined;
    for (schedule(&buf, p)) |q| {
        const qq = q + 2;
        const xt = try truncCopy(alloc, x, qq);
        defer xt.deinit(alloc);
        const yy = try mul(alloc, y, y, qq);
        defer yy.deinit(alloc);
        const xyy = try mul(alloc, xt, yy, qq);
        defer xyy.deinit(alloc);
        const r = try sub(alloc, one, xyy);
        defer r.deinit(alloc);
        const h = try half(alloc, r);
        defer h.deinit(alloc);
        const corr = try mul(alloc, y, h, qq);
        defer corr.deinit(alloc);
        const ny = try add(alloc, y, corr);
        y.deinit(alloc);
        y = try trunc(alloc, ny, qq);
    }
    return y;
}

/// Decimal string of a positive Float, truncated to `decimals` fraction digits.
pub fn toDecimal(alloc: Allocator, x: Float, decimals: usize) Error![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();
    const mg = x.m.mag;
    const len: i64 = @intCast(mg.len);
    // integer part: limbs with position e + i >= 0
    var wrote_int = false;
    var i: i64 = len - 1;
    while (i >= 0 and x.e + i >= 0) : (i -= 1) {
        const limb = if (x.e + i >= 0 and i < len) mg[@intCast(i)] else 0;
        if (!wrote_int) {
            if (limb == 0 and x.e + i > 0) continue;
            try out.writer().print("{d}", .{limb});
            wrote_int = true;
        } else try out.writer().print("{d:0>6}", .{limb});
    }
    // trailing zero limbs when e > 0
    var z: i64 = 0;
    while (z < x.e) : (z += 1) try out.appendSlice("000000");
    if (!wrote_int) try out.append('0');
    try out.append('.');
    const start = out.items.len;
    var k: i64 = 1;
    while (out.items.len - start < decimals) : (k += 1) {
        const idx = -x.e - k;
        const limb: u32 = if (idx >= 0 and idx < len) mg[@intCast(idx)] else 0;
        try out.writer().print("{d:0>6}", .{limb});
    }
    out.shrinkRetainingCapacity(start + decimals);
    return out.toOwnedSlice();
}
