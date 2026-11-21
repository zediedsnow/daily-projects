using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Cubist;

/// <summary>
/// An independent optimal solver used to audit the two-phase solver.
/// It shares no tables or coordinates with it: it works purely on CubieCube
/// permutations and a 67-bit exact state key.
///
/// Every position within <see cref="Radius"/> moves of solved (8.2 million of them at
/// radius 6) is enumerated by breadth-first search and stored in a sorted array.
/// A query then searches outward from the scrambled cube; the first time it touches
/// the stored ball we know an exact distance. Any position up to 2*Radius = 12 moves
/// from solved is solved provably optimally.
/// </summary>
public sealed class MeetInMiddle
{
    public readonly int Radius;
    UInt128[] keys;
    byte[] dist;
    public readonly List<long> CountsPerDepth = new();
    public double BuildSeconds;

    public MeetInMiddle(int radius = 6)
    {
        Radius = radius;
        var sw = Stopwatch.StartNew();
        var levels = new List<UInt128[]> { new[] { new CubieCube().Key } };
        CountsPerDepth.Add(1);
        var c = new CubieCube();
        var n = new CubieCube();
        for (int d = 1; d <= radius; d++)
        {
            var frontier = levels[d - 1];
            var cand = new UInt128[frontier.Length * 18];
            int cnt = 0;
            foreach (var k in frontier)
            {
                Decode(k, c);
                for (int m = 0; m < 18; m++)
                {
                    c.CopyTo(n);
                    n.Move(m);
                    cand[cnt++] = n.Key;
                }
            }
            Array.Sort(cand, 0, cnt);
            var prev = levels[d - 1];
            var prev2 = d >= 2 ? levels[d - 2] : Array.Empty<UInt128>();
            var next = new List<UInt128>(cnt / 8);
            for (int i = 0; i < cnt; i++)
            {
                if (i > 0 && cand[i] == cand[i - 1]) continue;
                if (Array.BinarySearch(prev, cand[i]) >= 0 || Array.BinarySearch(prev2, cand[i]) >= 0) continue;
                next.Add(cand[i]);
            }
            levels.Add(next.ToArray());   // already sorted
            CountsPerDepth.Add(next.Count);
        }
        long total = levels.Sum(l => (long)l.Length);
        int bits = 1; while ((1L << bits) < total * 2) bits++;
        shift = 64 - bits; mask = (1 << bits) - 1;
        keys = new UInt128[1 << bits];
        dist = new byte[1 << bits];
        Array.Fill(keys, Empty);
        for (int d = 0; d < levels.Count; d++)
            foreach (var k in levels[d])
            {
                int i = Slot(k);
                while (keys[i] != Empty) i = (i + 1) & mask;
                keys[i] = k; dist[i] = (byte)d;
            }
        BuildSeconds = sw.Elapsed.TotalSeconds;
    }

    public static void Decode(UInt128 key, CubieCube c)
    {
        ulong lo = (ulong)(key & ((UInt128.One << 40) - 1));
        ulong hi = (ulong)(key >> 40);
        c.CornerPerm = (int)(hi / 2187);
        c.Twist = (int)(hi % 2187);
        c.Flip = (int)(lo & 2047);
        long ep = (long)(lo >> 11);
        // unrank 12-element permutation
        Span<int> digits = stackalloc int[12];
        for (int i = 11; i >= 0; i--) { digits[i] = (int)(ep % (12 - i)); ep /= (12 - i); }
        var pool = new List<int>(Enumerable.Range(0, 12));
        for (int i = 0; i < 12; i++) { c.Ep[i] = (byte)pool[digits[i]]; pool.RemoveAt(digits[i]); }
    }

    // Open-addressing hash table (load factor <= 1/2) of every position in the ball.
    static readonly UInt128 Empty = UInt128.MaxValue;
    int shift, mask;
    int Slot(UInt128 k) => (int)((((ulong)k ^ ((ulong)(k >> 64) * 0x9E3779B97F4A7C15UL)) * 0xD6E8FEB86659FD93UL) >> shift);

    int Lookup(UInt128 key)
    {
        for (int i = Slot(key); ; i = (i + 1) & mask)
        {
            if (keys[i] == key) return dist[i];
            if (keys[i] == Empty) return -1;
        }
    }

    /// <summary>Exact optimal length if it is at most 2*Radius, otherwise -1.</summary>
    public int OptimalLength(CubieCube cube)
    {
        int best = Lookup(cube.Key);
        if (best >= 0) return best;
        best = int.MaxValue;
        // Not in the ball, so the optimum L is > Radius. Along an optimal (canonical) path, the
        // node after k moves is at distance L-k; for L <= 2*Radius some k <= Radius lands in
        // the ball. Search k = 1..Radius in parallel over the first move.
        for (int k = 1; k <= Radius && best > k; k++)
        {
            int kk = k;
            object gate = new();
            System.Threading.Tasks.Parallel.For(0, 18, m =>
            {
                var stack = new CubieCube[Radius + 1];
                for (int i = 0; i <= Radius; i++) stack[i] = new CubieCube();
                cube.CopyTo(stack[0]);
                stack[0].CopyTo(stack[1]); stack[1].Move(m);
                int local = int.MaxValue;
                Dfs(stack, 1, kk, m / 3, ref local);
                lock (gate) best = Math.Min(best, local);
            });
        }
        return best == int.MaxValue ? -1 : best;
    }

    void Dfs(CubieCube[] stack, int depth, int k, int lastFace, ref int best)
    {
        if (depth == k)
        {
            int d = Lookup(stack[depth].Key);
            if (d >= 0 && k + d < best) best = k + d;
            return;
        }
        for (int m = 0; m < 18; m++)
        {
            if (!Moves.Allowed(lastFace, m / 3)) continue;
            stack[depth].CopyTo(stack[depth + 1]);
            stack[depth + 1].Move(m);
            Dfs(stack, depth + 1, k, m / 3, ref best);
        }
    }
}
