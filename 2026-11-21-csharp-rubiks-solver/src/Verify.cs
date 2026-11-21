using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Cubist;

public static class Verify
{
    static int pass, fail;

    static void Check(bool ok, string what)
    {
        if (ok) { pass++; Console.WriteLine($"  ok    {what}"); }
        else { fail++; Console.WriteLine($"  FAIL  {what}"); }
    }

    static int Order(IList<int> seq)
    {
        var c = new CubieCube();
        for (int k = 1; k <= 10000; k++) { c.Apply(seq); if (c.IsSolved()) return k; }
        return -1;
    }

    public static int Run()
    {
        var total = Stopwatch.StartNew();
        var rng = new Random(2026);

        Console.WriteLine("group structure");
        Check(Enumerable.Range(0, 6).All(f => Order(new[] { 3 * f }) == 4), "every face turn has order 4");
        Check(Order(Moves.Parse("R U")) == 105, "R U has order 105");
        Check(Order(Moves.Parse("R U R' U'")) == 6, "the sexy move R U R' U' has order 6");
        Check(Order(Moves.Parse("R U2 D' B D'")) == 1260, "R U2 D' B D' has order 1260 (the maximum element order)");
        bool invOk = true;
        for (int t = 0; t < 2000; t++)
        {
            var c = CubieCube.Random(rng);
            var p = c.Clone(); p.Multiply(c.Inverse());
            if (!p.IsSolved() || c.Validate() != null) invOk = false;
        }
        Check(invOk, "c * c^-1 = identity and random states are legal (2,000 cubes)");

        Console.WriteLine("famous positions");
        var sf = new CubieCube(); sf.Apply(Moves.Parse("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"));
        Check(Enumerable.Range(0, 8).All(i => sf.Cp[i] == i && sf.Co[i] == 0) && Enumerable.Range(0, 12).All(i => sf.Ep[i] == i && sf.Eo[i] == 1),
            "Reid's 20-move sequence produces the superflip (every edge flipped in place)");
        Check(sf.ToFaceletString() == "UBULURUFURURFRBRDRFUFLFRFDFDFDLDRDBDLULBLFLDLBUBRBLBDB", "superflip facelet string matches Kociemba's reference");
        var checker = new CubieCube(); checker.Apply(Moves.Parse("U2 D2 F2 B2 L2 R2"));
        string cf = checker.ToFaceletString();
        Check(Enumerable.Range(0, 6).All(f => Enumerable.Range(0, 9).All(i => (cf[9 * f + i] == cf[9 * f + 4]) == (i % 2 == 0))), "U2 D2 F2 B2 L2 R2 gives the checkerboard pattern");

        Console.WriteLine("facelets");
        bool rt = true;
        for (int t = 0; t < 10000; t++)
        {
            var c = CubieCube.Random(rng);
            var back = CubieCube.FromFacelets(c.ToFaceletString(), out _);
            if (back == null || !back.SameAs(c)) rt = false;
        }
        Check(rt, "cubie -> facelets -> cubie round-trips for 10,000 random cubes");
        var solved = new CubieCube().ToFaceletString();
        Check(solved == "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB", "solved cube has the expected facelet string");
        var twisted = new CubieCube(); twisted.Co[0] = 1;
        CubieCube.FromFacelets(twisted.ToFaceletString(), out var e1);
        var flipped = new CubieCube(); flipped.Eo[3] = 1;
        CubieCube.FromFacelets(flipped.ToFaceletString(), out var e2);
        var swapped = new CubieCube(); (swapped.Ep[0], swapped.Ep[1]) = (swapped.Ep[1], swapped.Ep[0]);
        CubieCube.FromFacelets(swapped.ToFaceletString(), out var e3);
        Check(e1 != null && e1.Contains("twisted") && e2 != null && e2.Contains("flipped") && e3 != null && e3.Contains("parity"),
            "unsolvable cubes are rejected with the right reason (twisted corner / flipped edge / swapped pair)");
        Check(CubieCube.FromFacelets("WWWWWWWWWRRRRRRRRRGGGGGGGGGYYYYYYYYYOOOOOOOOOBBBBBBBBB", out _)?.IsSolved() == true, "arbitrary colour letters are accepted (mapped by centres)");

        Console.WriteLine("coordinates");
        var a = new CubieCube();
        Check(Enumerable.Range(0, 2187).All(i => { a.Twist = i; return a.Twist == i; }), "twist set/get bijection (2,187)");
        Check(Enumerable.Range(0, 2048).All(i => { a.Flip = i; return a.Flip == i; }), "flip set/get bijection (2,048)");
        Check(Enumerable.Range(0, 495).All(i => { a.SetSlice(i); return a.Slice == i; }), "UD-slice set/get bijection (495)");
        Check(Enumerable.Range(0, 40320).All(i => { a.CornerPerm = i; return a.CornerPerm == i; }), "corner permutation set/get bijection (40,320)");
        Check(Enumerable.Range(0, 40320).All(i => { a.UdEdgePerm = i; return a.UdEdgePerm == i; }), "U/D edge permutation set/get bijection (40,320)");
        Check(Enumerable.Range(0, 24).All(i => { a.SlicePerm = i; return a.SlicePerm == i; }), "slice permutation set/get bijection (24)");
        Check(Enumerable.Range(0, 11880).All(i => { a.SliceSorted = i; return a.SliceSorted == i && a.Slice == i / 24; }) &&
              Enumerable.Range(0, 24).All(i => { a.SlicePerm = i; return a.SliceSorted == i; }), "sorted-slice set/get bijection (11,880), equal to slice perm inside H");
        Check(Enumerable.Range(0, 11880).All(i => { a.SetEdgeGroup(0, i); bool ok = a.GetEdgeGroup(0) == i; a.SetEdgeGroup(4, i); return ok && a.GetEdgeGroup(4) == i; }),
              "U-edge and D-edge group set/get bijections (11,880 each)");
        bool keyOk = true;
        var dec = new CubieCube();
        for (int t = 0; t < 5000; t++) { var c = CubieCube.Random(rng); MeetInMiddle.Decode(c.Key, dec); if (!dec.SameAs(c)) keyOk = false; }
        Check(keyOk, "67-bit state key decodes back to the same cube (5,000 cubes)");

        Console.WriteLine("tables");
        Tables.Build();
        Console.WriteLine($"        built move + pruning tables in {Tables.BuildSeconds:F2}s");
        void Hist(string name, byte[] t)
        {
            var h = t.GroupBy(x => x).OrderBy(g => g.Key).Select(g => $"{g.Key}:{g.Count()}");
            Console.WriteLine($"        {name,-22} max depth {t.Max()}  [{string.Join(" ", h)}]");
        }
        Hist("twist x slice", Tables.PruneTwistSlice);
        Hist("flip x slice", Tables.PruneFlipSlice);
        Hist("corner perm x slice", Tables.PruneCPermSlicePerm);
        Hist("U/D edge perm x slice", Tables.PruneUdEdgeSlicePerm);
        Check(Tables.PruneTwistSlice.All(x => x != 255) && Tables.PruneFlipSlice.All(x => x != 255) &&
              Tables.PruneCPermSlicePerm.All(x => x != 255) && Tables.PruneUdEdgeSlicePerm.All(x => x != 255), "all pruning-table entries reachable");
        bool movesOk = true;
        for (int t = 0; t < 20000 && movesOk; t++)
        {
            var c = CubieCube.Random(rng); int m = rng.Next(18);
            var d = c.Clone(); d.Move(m);
            movesOk = Tables.TwistMove[c.Twist * 18 + m] == d.Twist && Tables.FlipMove[c.Flip * 18 + m] == d.Flip &&
                      Tables.SliceMove[c.Slice * 18 + m] == d.Slice && Tables.SliceSortedMove[c.SliceSorted * 18 + m] == d.SliceSorted && Tables.CPermMove[c.CornerPerm * 18 + m] == d.CornerPerm &&
                      Tables.UEdgeMove[c.GetEdgeGroup(0) * 18 + m] == d.GetEdgeGroup(0) && Tables.DEdgeMove[c.GetEdgeGroup(4) * 18 + m] == d.GetEdgeGroup(4);
        }
        Check(movesOk, "coordinate move tables agree with cubie-level moves (20,000 random checks)");
        bool mergeOk = true;
        for (int t = 0; t < 20000; t++)
        {
            var c = new CubieCube(); c.CornerPerm = rng.Next(40320); c.UdEdgePerm = rng.Next(40320); c.SlicePerm = 0;
            var hc = c.Clone(); hc.UdEdgePerm = rng.Next(40320); // random element of H's edge part
            if (Tables.MergeUdEdges(hc.GetEdgeGroup(0), hc.GetEdgeGroup(4)) != hc.UdEdgePerm) mergeOk = false;
        }
        Check(mergeOk, "U-edge + D-edge groups merge into the phase-2 edge permutation (20,000 checks)");

        Console.WriteLine("meet-in-the-middle ball (independent of the two-phase tables)");
        var mitm = new MeetInMiddle(6);
        long[] known = { 1, 18, 243, 3240, 43239, 574908, 7618438 };
        Console.WriteLine($"        enumerated {mitm.CountsPerDepth.Sum():N0} positions in {mitm.BuildSeconds:F1}s: {string.Join(", ", mitm.CountsPerDepth)}");
        Check(mitm.CountsPerDepth.SequenceEqual(known), "positions at distance 0..6 match the known counts (OEIS A080601)");

        Console.WriteLine("two-phase solver");
        var solver = new TwoPhaseSolver();
        var r = MultiSolver.Solve(sf, 20, 30);
        var chk = sf.Clone(); chk.Apply(r.Moves);
        Check(chk.IsSolved() && r.Length == 20, $"superflip solved in {r.Length} moves ({r.Seconds * 1000:F0} ms) - superflip is known to need exactly 20");
        bool allOk = true; int maxLen = 0; double tsum = 0;
        for (int t = 0; t < 500; t++)
        {
            var c = CubieCube.Random(rng);
            var res = MultiSolver.Solve(c, 20, 5);
            var k = c.Clone(); k.Apply(res.Moves);
            if (!k.IsSolved()) allOk = false;
            maxLen = Math.Max(maxLen, res.Length); tsum += res.Seconds;
        }
        Check(allOk && maxLen <= 20, $"500 uniformly random cubes all solved in <= 20 moves (longest {maxLen}, mean {tsum / 500 * 1000:F1} ms)");

        bool okOpt = AuditOptimal(60, 99, mitm);
        Check(okOpt, "optimal two-phase agrees with meet-in-the-middle on 60 scrambles");

        Console.WriteLine($"\n{pass} passed, {fail} failed in {total.Elapsed.TotalSeconds:F1}s");
        return fail == 0 ? 0 : 1;
    }

    /// <summary>
    /// For random scrambles of up to 12 moves, compute the true optimum twice with
    /// unrelated algorithms and demand they agree.
    /// </summary>
    public static bool AuditOptimal(int n, int seed, MeetInMiddle mitm = null)
    {
        var rng = new Random(seed);
        if (mitm == null)
        {
            Console.WriteLine("building meet-in-the-middle ball of radius 6...");
            mitm = new MeetInMiddle(6);
            Console.WriteLine($"  {mitm.CountsPerDepth.Sum():N0} positions in {mitm.BuildSeconds:F1}s");
        }
        var solver = new TwoPhaseSolver();
        int agree = 0, beatsScramble = 0;
        double tTwo = 0, tMitm = 0;
        var byLen = new SortedDictionary<int, int>();
        for (int i = 0; i < n; i++)
        {
            int len = i < n / 4 ? rng.Next(1, 10) : rng.Next(10, 13);
            var scr = Moves.RandomScramble(rng, len);
            var c = new CubieCube(); c.Apply(scr);
            var sw = Stopwatch.StartNew();
            int opt = mitm.OptimalLength(c);
            tMitm += sw.Elapsed.TotalSeconds;
            var r = solver.Solve(c, -1, 600);
            tTwo += r.Seconds;
            var k = c.Clone(); k.Apply(r.Moves);
            bool ok = k.IsSolved() && r.ProvenOptimal && r.Length == opt;
            if (ok) agree++;
            if (opt < len) beatsScramble++;
            byLen[opt] = byLen.GetValueOrDefault(opt) + 1;
            if (!ok) Console.WriteLine($"  MISMATCH: {Moves.Format(scr)}  mitm={opt} two-phase={r.Length} proven={r.ProvenOptimal}");
        }
        Console.WriteLine($"        {agree}/{n} agree; optimum distribution {string.Join(" ", byLen.Select(kv => $"{kv.Key}:{kv.Value}"))}; " +
                          $"{beatsScramble} scrambles had a shorter solution than the scramble itself");
        Console.WriteLine($"        mean time: two-phase (optimal mode) {tTwo / n * 1000:F0} ms, meet-in-the-middle {tMitm / n * 1000:F0} ms");
        return agree == n;
    }
}
