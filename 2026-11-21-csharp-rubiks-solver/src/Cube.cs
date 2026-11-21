using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace Cubist;

/// <summary>
/// A Rubik's cube at the "cubie" level: where each of the 8 corners and 12 edges
/// went (permutation) and how it is twisted/flipped (orientation).
/// Move composition is permutation multiplication, so the cube is a group element.
/// </summary>
public sealed class CubieCube
{
    // Corner names, in Kociemba's standard order.
    public const int URF = 0, UFL = 1, ULB = 2, UBR = 3, DFR = 4, DLF = 5, DBL = 6, DRB = 7;
    // Edge names.
    public const int UR = 0, UF = 1, UL = 2, UB = 3, DR = 4, DF = 5, DL = 6, DB = 7, FR = 8, FL = 9, BL = 10, BR = 11;

    public readonly byte[] Cp = new byte[8];   // corner permutation: Cp[pos] = which corner sits there
    public readonly byte[] Co = new byte[8];   // corner twist 0..2
    public readonly byte[] Ep = new byte[12];  // edge permutation
    public readonly byte[] Eo = new byte[12];  // edge flip 0..1

    public CubieCube()
    {
        for (byte i = 0; i < 8; i++) Cp[i] = i;
        for (byte i = 0; i < 12; i++) Ep[i] = i;
    }

    public CubieCube(int[] cp, int[] co, int[] ep, int[] eo)
    {
        for (int i = 0; i < 8; i++) { Cp[i] = (byte)cp[i]; Co[i] = (byte)co[i]; }
        for (int i = 0; i < 12; i++) { Ep[i] = (byte)ep[i]; Eo[i] = (byte)eo[i]; }
    }

    public CubieCube Clone()
    {
        var c = new CubieCube();
        CopyTo(c);
        return c;
    }

    public void CopyTo(CubieCube c)
    {
        Buffer.BlockCopy(Cp, 0, c.Cp, 0, 8); Buffer.BlockCopy(Co, 0, c.Co, 0, 8);
        Buffer.BlockCopy(Ep, 0, c.Ep, 0, 12); Buffer.BlockCopy(Eo, 0, c.Eo, 0, 12);
    }

    /// <summary>this := this * b, i.e. first do this, then b.</summary>
    public void CornerMultiply(CubieCube b)
    {
        Span<byte> cp = stackalloc byte[8], co = stackalloc byte[8];
        for (int i = 0; i < 8; i++)
        {
            cp[i] = Cp[b.Cp[i]];
            co[i] = (byte)((Co[b.Cp[i]] + b.Co[i]) % 3);
        }
        cp.CopyTo(Cp); co.CopyTo(Co);
    }

    public void EdgeMultiply(CubieCube b)
    {
        Span<byte> ep = stackalloc byte[12], eo = stackalloc byte[12];
        for (int i = 0; i < 12; i++)
        {
            ep[i] = Ep[b.Ep[i]];
            eo[i] = (byte)((Eo[b.Ep[i]] + b.Eo[i]) & 1);
        }
        ep.CopyTo(Ep); eo.CopyTo(Eo);
    }

    public void Multiply(CubieCube b) { CornerMultiply(b); EdgeMultiply(b); }

    public void Move(int m) => Multiply(Moves.Table[m]);

    public void Apply(IEnumerable<int> moves) { foreach (var m in moves) Move(m); }

    public CubieCube Inverse()
    {
        var r = new CubieCube();
        for (int i = 0; i < 8; i++) r.Cp[Cp[i]] = (byte)i;
        for (int i = 0; i < 8; i++) r.Co[i] = (byte)((3 - Co[r.Cp[i]]) % 3);
        for (int i = 0; i < 12; i++) r.Ep[Ep[i]] = (byte)i;
        for (int i = 0; i < 12; i++) r.Eo[i] = Eo[r.Ep[i]];
        return r;
    }

    public bool IsSolved()
    {
        for (int i = 0; i < 8; i++) if (Cp[i] != i || Co[i] != 0) return false;
        for (int i = 0; i < 12; i++) if (Ep[i] != i || Eo[i] != 0) return false;
        return true;
    }

    public bool SameAs(CubieCube o) =>
        Cp.AsSpan().SequenceEqual(o.Cp) && Co.AsSpan().SequenceEqual(o.Co) &&
        Ep.AsSpan().SequenceEqual(o.Ep) && Eo.AsSpan().SequenceEqual(o.Eo);

    // ---------- coordinates ----------

    public int Twist { get { int t = 0; for (int i = 0; i < 7; i++) t = 3 * t + Co[i]; return t; }
        set { int s = 0; for (int i = 6; i >= 0; i--) { Co[i] = (byte)(value % 3); s += Co[i]; value /= 3; } Co[7] = (byte)((3 - s % 3) % 3); } }

    public int Flip { get { int f = 0; for (int i = 0; i < 11; i++) f = 2 * f + Eo[i]; return f; }
        set { int s = 0; for (int i = 10; i >= 0; i--) { Eo[i] = (byte)(value & 1); s += Eo[i]; value >>= 1; } Eo[11] = (byte)(s & 1); } }

    /// <summary>Which 4 of the 12 positions hold the UD-slice edges (FR,FL,BL,BR), 0..494, solved = 0.</summary>
    public int Slice
    {
        get
        {
            int a = 0, x = 0;
            for (int j = 11; j >= 0; j--)
                if (Ep[j] >= 8) { a += Comb.C(11 - j, x + 1); x++; }
            return a;
        }
    }

    /// <summary>Places the slice edges at the positions encoded by <paramref name="slice"/> (others: any order).</summary>
    public void SetSlice(int slice)
    {
        int mask = Comb.SliceMask[slice];
        int s = 8, o = 0;
        for (int j = 0; j < 12; j++) Ep[j] = (byte)(((mask >> j) & 1) != 0 ? s++ : o++);
    }

    /// <summary>Slice positions and the order of the slice edges in them (0..11879); &lt; 24 exactly inside H,
    /// where it equals <see cref="SlicePerm"/>.</summary>
    public int SliceSorted
    {
        get
        {
            Span<byte> e = stackalloc byte[4]; int n = 0;
            for (int j = 0; j < 12; j++) if (Ep[j] >= 8) e[n++] = (byte)(Ep[j] - 8);
            int r = 0;
            for (int i = 0; i < 4; i++) { int k = 0; for (int j = i + 1; j < 4; j++) if (e[j] < e[i]) k++; r = r * (4 - i) + k; }
            return Slice * 24 + r;
        }
        set
        {
            SetSlice(value / 24);
            var tmp = new byte[4];
            Perm.Unrank(value % 24, tmp, 0, 4, 8);
            int n = 0;
            for (int j = 0; j < 12; j++) if (Ep[j] >= 8) Ep[j] = tmp[n++];
        }
    }

    /// <summary>Positions and order of the four edges lo..lo+3 (0..11879). Used with lo = 0
    /// (the U-layer edges) and lo = 4 (D-layer edges) to recover the phase-2 edge
    /// permutation at the end of phase 1 without replaying moves on the cube.</summary>
    public int GetEdgeGroup(int lo)
    {
        Span<byte> e = stackalloc byte[4]; int n = 0, a = 0, x = 0;
        for (int j = 11; j >= 0; j--)
            if (Ep[j] >= lo && Ep[j] < lo + 4) { a += Comb.C(11 - j, x + 1); x++; }
        for (int j = 0; j < 12; j++) if (Ep[j] >= lo && Ep[j] < lo + 4) e[n++] = (byte)(Ep[j] - lo);
        int r = 0;
        for (int i = 0; i < 4; i++) { int k = 0; for (int j = i + 1; j < 4; j++) if (e[j] < e[i]) k++; r = r * (4 - i) + k; }
        return a * 24 + r;
    }

    public void SetEdgeGroup(int lo, int value)
    {
        int mask = Comb.SliceMask[value / 24];
        var tmp = new byte[4];
        Perm.Unrank(value % 24, tmp, 0, 4, lo);
        int n = 0, o = 0;
        var others = Enumerable.Range(0, 12).Where(e => e < lo || e >= lo + 4).ToArray();
        for (int j = 0; j < 12; j++) Ep[j] = ((mask >> j) & 1) != 0 ? tmp[n++] : (byte)others[o++];
    }

    public int CornerPerm { get => Perm.Rank(Cp, 0, 8); set => Perm.Unrank(value, Cp, 0, 8, 0); }
    /// <summary>Permutation of the 8 U/D edges; only meaningful inside the phase-2 subgroup.</summary>
    public int UdEdgePerm { get => Perm.Rank(Ep, 0, 8); set { Perm.Unrank(value, Ep, 0, 8, 0); for (int i = 8; i < 12; i++) Ep[i] = (byte)i; } }
    /// <summary>Permutation of the 4 slice edges among themselves (0..23).</summary>
    public int SlicePerm { get => Perm.Rank(Ep, 8, 4, 8); set { Perm.Unrank(value, Ep, 8, 4, 8); for (int i = 0; i < 8; i++) Ep[i] = (byte)i; } }
    public long EdgePerm => Perm.RankLong(Ep, 0, 12);

    public int CornerParity => Perm.Parity(Cp);
    public int EdgeParity => Perm.Parity(Ep);

    /// <summary>A 67-bit fingerprint that identifies the state exactly.</summary>
    public UInt128 Key =>
        ((UInt128)(ulong)(CornerPerm * 2187 + Twist) << 40) | ((ulong)EdgePerm << 11) | (ulong)Flip;

    /// <summary>Checks the three laws of the cube group; returns null if legal, else the reason.</summary>
    public string Validate()
    {
        if (!Cp.OrderBy(x => x).SequenceEqual(Enumerable.Range(0, 8).Select(x => (byte)x))) return "corner set is not a permutation (a corner is missing or duplicated)";
        if (!Ep.OrderBy(x => x).SequenceEqual(Enumerable.Range(0, 12).Select(x => (byte)x))) return "edge set is not a permutation (an edge is missing or duplicated)";
        if (Co.Sum(x => x) % 3 != 0) return "a corner is twisted (total twist is not 0 mod 3)";
        if (Eo.Sum(x => x) % 2 != 0) return "an edge is flipped (total flip is odd)";
        if (CornerParity != EdgeParity) return "parity error: two pieces are swapped";
        return null;
    }

    public static CubieCube Random(Random rng)
    {
        var c = new CubieCube();
        c.CornerPerm = rng.Next(40320);
        c.Twist = rng.Next(2187);
        var ep = Enumerable.Range(0, 12).ToArray();
        for (int i = 11; i > 0; i--) { int j = rng.Next(i + 1); (ep[i], ep[j]) = (ep[j], ep[i]); }
        for (int i = 0; i < 12; i++) c.Ep[i] = (byte)ep[i];
        c.Flip = rng.Next(2048);
        if (c.CornerParity != c.EdgeParity) (c.Ep[0], c.Ep[1]) = (c.Ep[1], c.Ep[0]);
        return c;
    }

    // ---------- facelets ----------

    // Facelet indices: U1..U9 = 0..8, R 9..17, F 18..26, D 27..35, L 36..44, B 45..53 (Kociemba layout).
    public static readonly int[][] CornerFacelet = {
        new[]{8, 9, 20}, new[]{6, 18, 38}, new[]{0, 36, 47}, new[]{2, 45, 11},
        new[]{29, 26, 15}, new[]{27, 44, 24}, new[]{33, 53, 42}, new[]{35, 17, 51} };
    public static readonly int[][] EdgeFacelet = {
        new[]{5, 10}, new[]{7, 19}, new[]{3, 37}, new[]{1, 46}, new[]{32, 16}, new[]{28, 25},
        new[]{30, 43}, new[]{34, 52}, new[]{23, 12}, new[]{21, 41}, new[]{50, 39}, new[]{48, 14} };
    const int cU = 0, cR = 1, cF = 2, cD = 3, cL = 4, cB = 5;
    public static readonly int[][] CornerColor = {
        new[]{cU,cR,cF}, new[]{cU,cF,cL}, new[]{cU,cL,cB}, new[]{cU,cB,cR},
        new[]{cD,cF,cR}, new[]{cD,cL,cF}, new[]{cD,cB,cL}, new[]{cD,cR,cB} };
    public static readonly int[][] EdgeColor = {
        new[]{cU,cR}, new[]{cU,cF}, new[]{cU,cL}, new[]{cU,cB}, new[]{cD,cR}, new[]{cD,cF},
        new[]{cD,cL}, new[]{cD,cB}, new[]{cF,cR}, new[]{cF,cL}, new[]{cB,cL}, new[]{cB,cR} };
    public const string FaceNames = "URFDLB";

    public int[] ToFacelets()
    {
        var f = new int[54];
        for (int i = 0; i < 6; i++) f[9 * i + 4] = i;
        for (int i = 0; i < 8; i++)
            for (int n = 0; n < 3; n++)
                f[CornerFacelet[i][(n + Co[i]) % 3]] = CornerColor[Cp[i]][n];
        for (int i = 0; i < 12; i++)
            for (int n = 0; n < 2; n++)
                f[EdgeFacelet[i][(n + Eo[i]) % 2]] = EdgeColor[Ep[i]][n];
        return f;
    }

    public string ToFaceletString() => new string(ToFacelets().Select(c => FaceNames[c]).ToArray());

    /// <summary>Parses a 54-char facelet string (URFDLB order, colours named by their centre face).</summary>
    public static CubieCube FromFacelets(string s, out string error)
    {
        error = null;
        s = new string(s.Where(ch => !char.IsWhiteSpace(ch)).ToArray()).ToUpperInvariant();
        if (s.Length != 54) { error = $"expected 54 facelets, got {s.Length}"; return null; }
        // Allow any 6 symbols: map each centre's symbol to its face.
        var map = new Dictionary<char, int>();
        for (int i = 0; i < 6; i++)
        {
            if (map.ContainsKey(s[9 * i + 4])) { error = "two centres have the same colour"; return null; }
            map[s[9 * i + 4]] = i;
        }
        var f = new int[54];
        for (int i = 0; i < 54; i++)
        {
            if (!map.TryGetValue(s[i], out f[i])) { error = $"unknown colour '{s[i]}' at position {i}"; return null; }
        }
        for (int c = 0; c < 6; c++)
            if (f.Count(x => x == c) != 9) { error = $"colour {FaceNames[c]} appears {f.Count(x => x == c)} times, expected 9"; return null; }

        var cc = new CubieCube();
        for (int i = 0; i < 8; i++)
        {
            int ori = 0;
            while (ori < 3 && f[CornerFacelet[i][ori]] != cU && f[CornerFacelet[i][ori]] != cD) ori++;
            if (ori == 3) { error = $"corner at {CornerName(i)} has no U/D sticker"; return null; }
            int c1 = f[CornerFacelet[i][(ori + 1) % 3]], c2 = f[CornerFacelet[i][(ori + 2) % 3]];
            int j = Array.FindIndex(CornerColor, cc2 => cc2[1] == c1 && cc2[2] == c2 && (cc2[0] == f[CornerFacelet[i][ori]]));
            if (j < 0) { error = $"impossible corner colours at {CornerName(i)}"; return null; }
            cc.Cp[i] = (byte)j; cc.Co[i] = (byte)(ori % 3);
        }
        for (int i = 0; i < 12; i++)
        {
            int a = f[EdgeFacelet[i][0]], b = f[EdgeFacelet[i][1]];
            int j = Array.FindIndex(EdgeColor, e => e[0] == a && e[1] == b);
            if (j >= 0) { cc.Ep[i] = (byte)j; cc.Eo[i] = 0; continue; }
            j = Array.FindIndex(EdgeColor, e => e[0] == b && e[1] == a);
            if (j < 0) { error = $"impossible edge colours at {EdgeName(i)}"; return null; }
            cc.Ep[i] = (byte)j; cc.Eo[i] = 1;
        }
        error = cc.Validate();
        return error == null ? cc : null;
    }

    public static string CornerName(int i) => new[] { "URF", "UFL", "ULB", "UBR", "DFR", "DLF", "DBL", "DRB" }[i];
    public static string EdgeName(int i) => new[] { "UR", "UF", "UL", "UB", "DR", "DF", "DL", "DB", "FR", "FL", "BL", "BR" }[i];
}

/// <summary>The 18 face turns. Move index m = 3*face + (quarterTurns-1), faces in URFDLB order.</summary>
public static class Moves
{
    public static readonly CubieCube[] Basic = {
        // U
        new(new[]{3,0,1,2,4,5,6,7}, new int[8], new[]{3,0,1,2,4,5,6,7,8,9,10,11}, new int[12]),
        // R
        new(new[]{4,1,2,0,7,5,6,3}, new[]{2,0,0,1,1,0,0,2}, new[]{8,1,2,3,11,5,6,7,4,9,10,0}, new int[12]),
        // F
        new(new[]{1,5,2,3,0,4,6,7}, new[]{1,2,0,0,2,1,0,0}, new[]{0,9,2,3,4,8,6,7,1,5,10,11}, new[]{0,1,0,0,0,1,0,0,1,1,0,0}),
        // D
        new(new[]{0,1,2,3,5,6,7,4}, new int[8], new[]{0,1,2,3,5,6,7,4,8,9,10,11}, new int[12]),
        // L
        new(new[]{0,2,6,3,4,1,5,7}, new[]{0,1,2,0,0,2,1,0}, new[]{0,1,10,3,4,5,9,7,8,2,6,11}, new int[12]),
        // B
        new(new[]{0,1,3,7,4,5,2,6}, new[]{0,0,1,2,0,0,2,1}, new[]{0,1,2,11,4,5,6,10,8,9,3,7}, new[]{0,0,0,1,0,0,0,1,0,0,1,1}),
    };

    public static readonly CubieCube[] Table = BuildTable();

    static CubieCube[] BuildTable()
    {
        var t = new CubieCube[18];
        for (int f = 0; f < 6; f++)
        {
            var c = new CubieCube();
            for (int k = 0; k < 3; k++) { c.Multiply(Basic[f]); t[3 * f + k] = c.Clone(); }
        }
        return t;
    }

    public static readonly int[] Phase2Moves = { 0, 1, 2, 9, 10, 11, 4, 7, 13, 16 }; // U U2 U' D D2 D' R2 F2 L2 B2
    public static readonly bool[] IsPhase2 = Enumerable.Range(0, 18).Select(m => Phase2Moves.Contains(m)).ToArray();

    public static string Name(int m) => CubieCube.FaceNames[m / 3] + new[] { "", "2", "'" }[m % 3];
    public static string Format(IEnumerable<int> ms) => string.Join(" ", ms.Select(Name));

    public static int Inverse(int m) => 3 * (m / 3) + (2 - m % 3);

    public static List<int> Parse(string s)
    {
        var r = new List<int>();
        foreach (var tok in s.Split(new[] { ' ', '\t', ',' }, StringSplitOptions.RemoveEmptyEntries))
        {
            int f = CubieCube.FaceNames.IndexOf(char.ToUpperInvariant(tok[0]));
            if (f < 0) throw new FormatException($"bad move '{tok}'");
            string suf = tok.Substring(1).Replace("’", "'");
            int q = suf switch { "" or "1" => 1, "2" or "2'" => 2, "'" or "3" or "-" => 3, _ => throw new FormatException($"bad move '{tok}'") };
            r.Add(3 * f + q - 1);
        }
        return r;
    }

    /// <summary>Canonical-sequence rule: no two turns of the same face in a row, and
    /// opposite faces only in one order (U before D, R before L, F before B).</summary>
    public static bool Allowed(int lastFace, int face) => face != lastFace && face != lastFace - 3;

    public static List<int> RandomScramble(Random rng, int len)
    {
        var r = new List<int>(); int last = -10;
        while (r.Count < len)
        {
            int m = rng.Next(18);
            if (!Allowed(last, m / 3)) continue;
            r.Add(m); last = m / 3;
        }
        return r;
    }
}

public static class Comb
{
    static readonly int[,] c = BuildC();
    static int[,] BuildC()
    {
        var t = new int[13, 13];
        for (int n = 0; n <= 12; n++) { t[n, 0] = 1; for (int k = 1; k <= n; k++) t[n, k] = t[n - 1, k - 1] + (k <= n - 1 ? t[n - 1, k] : 0); }
        return t;
    }
    public static int C(int n, int k) => k > n ? 0 : c[n, k];

    public static readonly int[] SliceMask = BuildSliceMask();
    static int[] BuildSliceMask()
    {
        var res = new int[495]; var seen = new bool[495];
        for (int mask = 0; mask < 4096; mask++)
        {
            if (System.Numerics.BitOperations.PopCount((uint)mask) != 4) continue;
            int a = 0, x = 0;
            for (int j = 11; j >= 0; j--) if (((mask >> j) & 1) != 0) { a += C(11 - j, x + 1); x++; }
            if (seen[a]) throw new Exception("slice coordinate not a bijection");
            seen[a] = true; res[a] = mask;
        }
        return res;
    }
}

public static class Perm
{
    /// <summary>Lehmer-code rank of a[off..off+n) (values base..base+n-1).</summary>
    public static int Rank(byte[] a, int off, int n, int @base = 0)
    {
        long r = RankL(a, off, n, @base);
        return (int)r;
    }

    public static long RankLong(byte[] a, int off, int n) => RankL(a, off, n, 0);

    static long RankL(byte[] a, int off, int n, int b)
    {
        long r = 0;
        for (int i = 0; i < n; i++)
        {
            int k = 0;
            for (int j = i + 1; j < n; j++) if (a[off + j] < a[off + i]) k++;
            r = r * (n - i) + k;
        }
        return r;
    }

    public static void Unrank(int rank, byte[] a, int off, int n, int @base)
    {
        Span<int> digits = stackalloc int[n];
        for (int i = n - 1; i >= 0; i--) { digits[i] = rank % (n - i); rank /= (n - i); }
        Span<int> pool = stackalloc int[n];
        for (int i = 0; i < n; i++) pool[i] = i;
        int len = n;
        for (int i = 0; i < n; i++)
        {
            int d = digits[i];
            a[off + i] = (byte)(pool[d] + @base);
            for (int j = d; j < len - 1; j++) pool[j] = pool[j + 1];
            len--;
        }
    }

    public static int Parity(byte[] p)
    {
        int s = 0;
        for (int i = 0; i < p.Length; i++) for (int j = i + 1; j < p.Length; j++) if (p[j] < p[i]) s++;
        return s & 1;
    }
}
