//! ludolph - compute millions of digits of pi, e, sqrt(2) and phi.
//!
//!   ludolph pi 1000000 -o pi.txt     Chudnovsky + binary splitting + NTT
//!   ludolph e 1000000
//!   ludolph sqrt2 1000000
//!   ludolph phi 1000000
//!   ludolph test                     self-tests of every layer
//!   ludolph bench                    pi at 10^3 .. 10^6 digits

const std = @import("std");
const big = @import("bigint.zig");
const fl = @import("float.zig");
const consts = @import("constants.zig");
const Allocator = std.mem.Allocator;

const PI_100 = "3.1415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679";
const E_100 = "2.7182818284590452353602874713526624977572470936999595749669676277240766303535475945713821785251664274";
const SQRT2_100 = "1.4142135623730950488016887242096980785696718753769480731766797379907324784621070388503875343276415727";
const PHI_100 = "1.6180339887498948482045868343656381177203091798057628621354486227052604628189024497072072041893911374";

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn usage() void {
    std.debug.print(
        \\usage: ludolph <pi|e|sqrt2|phi> <digits> [-o FILE] [-t THREADS]
        \\       ludolph test
        \\       ludolph bench
        \\
    , .{});
}

const Which = enum { pi, e, sqrt2, phi };

fn compute(alloc: Allocator, which: Which, digits: usize, threads: u32, tm: *consts.Timings) ![]u8 {
    const x = switch (which) {
        .pi => try consts.pi(alloc, digits, threads, tm),
        .e => try consts.e(alloc, digits, tm),
        .sqrt2 => try consts.sqrtInt(alloc, 2, digits, tm),
        .phi => try consts.phi(alloc, digits, tm),
    };
    defer x.deinit(alloc);
    return fl.toDecimal(alloc, x, digits);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) return usage();

    if (std.mem.eql(u8, args[1], "test")) return selfTest(alloc);
    if (std.mem.eql(u8, args[1], "bench")) return bench(alloc);

    const which = std.meta.stringToEnum(Which, args[1]) orelse return usage();
    if (args.len < 3) return usage();
    const digits = try std.fmt.parseInt(usize, args[2], 10);
    var out_path: ?[]const u8 = null;
    var threads: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, 64));
    var i: usize = 3;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "-o")) out_path = args[i + 1] else if (std.mem.eql(u8, args[i], "-t")) threads = try std.fmt.parseInt(u32, args[i + 1], 10) else return usage();
    }

    var tm = consts.Timings{};
    var timer = try std.time.Timer.start();
    const s = try compute(alloc, which, digits, threads, &tm);
    defer alloc.free(s);
    const total = timer.read();

    const stdout = std.io.getStdOut().writer();
    if (out_path) |path| {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(s);
        try f.writeAll("\n");
    }
    const dot = std.mem.indexOfScalar(u8, s, '.').?;
    const head = s[0..@min(s.len, dot + 51)];
    try stdout.print("{s} to {d} digits", .{ @tagName(which), digits });
    if (which == .pi) try stdout.print(" ({d} threads)", .{threads});
    try stdout.print("\n", .{});
    try stdout.print("  first: {s}...\n", .{head});
    if (s.len > dot + 51) {
        const tail = s[s.len - @min(50, s.len - dot - 1) ..];
        try stdout.print("  last:  ...{s}\n", .{tail});
    }
    if (tm.terms > 0) try stdout.print("  series terms   {d:>12}\n", .{tm.terms});
    if (tm.series_ns > 0) try stdout.print("  binary split   {d:>10.1} ms\n", .{ms(tm.series_ns)});
    if (tm.root_ns > 0) try stdout.print("  square root    {d:>10.1} ms\n", .{ms(tm.root_ns)});
    if (tm.divide_ns > 0) try stdout.print("  division       {d:>10.1} ms\n", .{ms(tm.divide_ns)});
    try stdout.print("  total          {d:>10.1} ms\n", .{ms(total)});
    if (out_path) |path| try stdout.print("  wrote {s}\n", .{path});
}

fn bench(alloc: Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    const threads: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, 64));
    try stdout.print("{s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "digits", "series", "sqrt", "divide", "total" });
    var d: usize = 1000;
    while (d <= 1_000_000) : (d *= 10) {
        var tm = consts.Timings{};
        var timer = try std.time.Timer.start();
        const s = try compute(alloc, .pi, d, threads, &tm);
        alloc.free(s);
        const total = timer.read();
        try stdout.print("{d:>10} {d:>8.1}ms {d:>8.1}ms {d:>8.1}ms {d:>8.1}ms\n", .{ d, ms(tm.series_ns), ms(tm.root_ns), ms(tm.divide_ns), ms(total) });
    }
}

// ---------------------------------------------------------------------------
// Self tests
// ---------------------------------------------------------------------------

fn randMag(alloc: Allocator, r: std.Random, n: usize) ![]u32 {
    const m = try alloc.alloc(u32, n);
    for (m) |*x| x.* = r.uintLessThan(u32, big.BASE);
    if (n > 0) m[n - 1] = 1 + r.uintLessThan(u32, big.BASE - 1);
    // sometimes extreme limbs to stress carries
    if (r.boolean()) {
        for (m[0 .. n / 2]) |*x| x.* = big.BASE - 1;
    }
    return m;
}

fn check(ok: bool, comptime fmt: []const u8, args: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("  [{s}] " ++ fmt ++ "\n", .{if (ok) "ok" else "FAIL"} ++ args);
    if (!ok) return error.TestFailed;
}

fn selfTest(alloc: Allocator) !void {
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const r = prng.random();

    // 1. Goldilocks reduction agrees with u128 % p
    {
        var bad: usize = 0;
        for (0..1_000_000) |_| {
            const a = r.int(u64) % big.P;
            const b = r.int(u64) % big.P;
            const want: u64 = @intCast((@as(u128, a) * b) % big.P);
            if (big.mulMod(a, b) != want) bad += 1;
        }
        try check(bad == 0, "Goldilocks mulmod == u128 % p on 1,000,000 random pairs", .{});
    }

    // 2. NTT multiplication agrees with schoolbook
    {
        var bad: usize = 0;
        const cases = 400;
        for (0..cases) |ci| {
            const la = 1 + r.uintLessThan(usize, if (ci < 300) 300 else 3000);
            const lb = 1 + r.uintLessThan(usize, if (ci < 300) 300 else 3000);
            const a = try randMag(alloc, r, la);
            defer alloc.free(a);
            const b = if (ci % 7 == 0) a else try randMag(alloc, r, lb);
            defer if (ci % 7 != 0) alloc.free(b);
            const x = try big.mulSchool(alloc, a, b);
            defer alloc.free(x);
            const y = try big.mulNtt(alloc, a, b);
            defer alloc.free(y);
            if (big.cmpMag(x, y) != .eq) bad += 1;
        }
        try check(bad == 0, "NTT product == schoolbook product on {d} random pairs (up to 3000 limbs)", .{cases});
    }

    // 3. (a*b + c) / ... : add/sub/mul ring identities on signed ints
    {
        var bad: usize = 0;
        for (0..300) |_| {
            const a = big.Int{ .neg = r.boolean(), .mag = try randMag(alloc, r, 1 + r.uintLessThan(usize, 200)) };
            defer a.deinit(alloc);
            const b = big.Int{ .neg = r.boolean(), .mag = try randMag(alloc, r, 1 + r.uintLessThan(usize, 200)) };
            defer b.deinit(alloc);
            const s = try big.intAdd(alloc, a, b);
            defer s.deinit(alloc);
            const back = try big.intSub(alloc, s, b);
            defer back.deinit(alloc);
            // (a+b)(a-b) == a^2 - b^2
            const d = try big.intSub(alloc, a, b);
            defer d.deinit(alloc);
            const lhs = try big.intMul(alloc, s, d);
            defer lhs.deinit(alloc);
            const a2 = try big.intMul(alloc, a, a);
            defer a2.deinit(alloc);
            const b2 = try big.intMul(alloc, b, b);
            defer b2.deinit(alloc);
            const rhs = try big.intSub(alloc, a2, b2);
            defer rhs.deinit(alloc);
            if (back.neg != a.neg or big.cmpMag(back.mag, a.mag) != .eq) bad += 1;
            if (lhs.neg != rhs.neg or big.cmpMag(lhs.mag, rhs.mag) != .eq) bad += 1;
        }
        try check(bad == 0, "signed identities (a+b)-b == a, (a+b)(a-b) == a^2-b^2 on 300 cases", .{});
    }

    // 4. Newton reciprocal and inverse square root: residuals ~ BASE^-p
    {
        var worst_r: i64 = 0;
        var worst_s: i64 = 0;
        for (0..60) |ci| {
            const p = 5 + r.uintLessThan(usize, if (ci < 50) 200 else 3000);
            const xm = try randMag(alloc, r, 1 + r.uintLessThan(usize, 2 * p));
            const x = fl.Float{ .m = .{ .mag = xm }, .e = r.intRangeAtMost(i64, -500, 500) };
            defer x.deinit(alloc);
            const one = try fl.fromU64(alloc, 1);
            defer one.deinit(alloc);

            const y = try fl.recip(alloc, x, p);
            defer y.deinit(alloc);
            const xy = try fl.mul(alloc, x, y, 1 << 30);
            defer xy.deinit(alloc);
            const res = try fl.sub(alloc, one, xy);
            defer res.deinit(alloc);
            // exponent of the residual's top limb, relative to p
            const rexp = if (res.m.isZero()) -@as(i64, 1 << 40) else res.e + @as(i64, @intCast(res.m.mag.len)) - 1;
            worst_r = @max(worst_r, rexp + @as(i64, @intCast(p)));

            const s = try fl.invSqrt(alloc, x, p);
            defer s.deinit(alloc);
            const ss = try fl.mul(alloc, s, s, 1 << 30);
            defer ss.deinit(alloc);
            const xss = try fl.mul(alloc, x, ss, 1 << 30);
            defer xss.deinit(alloc);
            const res2 = try fl.sub(alloc, one, xss);
            defer res2.deinit(alloc);
            const rexp2 = if (res2.m.isZero()) -@as(i64, 1 << 40) else res2.e + @as(i64, @intCast(res2.m.mag.len)) - 1;
            worst_s = @max(worst_s, rexp2 + @as(i64, @intCast(p)));
        }
        try check(worst_r <= 0, "1 - x*recip(x) < 10^(-6p) for 60 random x, p up to 3000 limbs", .{});
        try check(worst_s <= 0, "1 - x*invsqrt(x)^2 < 10^(-6p) for the same x", .{});
    }

    // 5. Known digits of each constant
    {
        var tm = consts.Timings{};
        const cases = [_]struct { w: Which, s: []const u8 }{
            .{ .w = .pi, .s = PI_100 },
            .{ .w = .e, .s = E_100 },
            .{ .w = .sqrt2, .s = SQRT2_100 },
            .{ .w = .phi, .s = PHI_100 },
        };
        for (cases) |c| {
            const got = try compute(alloc, c.w, 100, 1, &tm);
            defer alloc.free(got);
            try check(std.mem.eql(u8, got, c.s), "{s} matches reference to 100 digits", .{@tagName(c.w)});
        }
    }

    // 6. Self-consistency: N digits is a prefix of N+k digits, at many sizes
    {
        var bad: usize = 0;
        var n_tests: usize = 0;
        var tm = consts.Timings{};
        for ([_]usize{ 1, 7, 13, 50, 99, 500, 1001, 4096, 20000 }) |d| {
            for ([_]Which{ .pi, .e, .sqrt2, .phi }) |w| {
                const a = try compute(alloc, w, d, 2, &tm);
                defer alloc.free(a);
                const b = try compute(alloc, w, d + 37, 1, &tm);
                defer alloc.free(b);
                if (!std.mem.startsWith(u8, b, a)) bad += 1;
                n_tests += 1;
            }
        }
        try check(bad == 0, "{d} prefix-consistency checks (d digits vs d+37, 1 vs 2 threads)", .{n_tests});
    }

    // 7. The 1,000,000th decimal of pi region (well-known: ...5779458151)
    {
        var tm = consts.Timings{};
        const got = try compute(alloc, .pi, 1_000_000, 2, &tm);
        defer alloc.free(got);
        try check(std.mem.endsWith(u8, got, "5779458151"), "pi to 1,000,000 digits ends ...{s}", .{got[got.len - 10 ..]});
    }
    try std.io.getStdOut().writer().print("all tests passed\n", .{});
}
