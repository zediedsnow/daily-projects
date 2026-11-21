using System;
using System.Diagnostics;

namespace Cubist;

/// <summary>
/// Move tables (coordinate x move -> coordinate) and pruning tables (exact distance
/// to the goal in a projection of the cube, found by breadth-first search).
/// </summary>
public static class Tables
{
    public const int NTwist = 2187, NFlip = 2048, NSlice = 495, NCPerm = 40320, NUdEdge = 40320, NSlicePerm = 24;

    public static ushort[] TwistMove, FlipMove, SliceMove, CPermMove, SliceSortedMove, UEdgeMove, DEdgeMove;
    public static byte[] GroupPos, GroupPiece; // [coord*4 + k]: where the k-th group edge sits / which one it is  // [coord*18 + move]
    public static ushort[] UdEdgeMove, SlicePermMove;                    // [coord*10 + phase-2 move index]
    public static byte[] PruneTwistSlice, PruneFlipSlice, PruneTwistFlip;               // phase 1: distance to subgroup H
    public static byte[] PruneCPermSlicePerm, PruneUdEdgeSlicePerm;     // phase 2: distance to solved within H

    public static double BuildSeconds;
    static bool built;

    public static void Build()
    {
        if (built) return;
        var sw = Stopwatch.StartNew();
        var a = new CubieCube();

        TwistMove = new ushort[NTwist * 18];
        for (int i = 0; i < NTwist; i++)
            for (int m = 0; m < 18; m++) { a.Twist = i; a.CornerMultiply(Moves.Table[m]); TwistMove[i * 18 + m] = (ushort)a.Twist; }

        FlipMove = new ushort[NFlip * 18];
        for (int i = 0; i < NFlip; i++)
            for (int m = 0; m < 18; m++) { a.Flip = i; a.EdgeMultiply(Moves.Table[m]); FlipMove[i * 18 + m] = (ushort)a.Flip; }

        SliceMove = new ushort[NSlice * 18];
        for (int i = 0; i < NSlice; i++)
            for (int m = 0; m < 18; m++) { a.SetSlice(i); a.EdgeMultiply(Moves.Table[m]); SliceMove[i * 18 + m] = (ushort)a.Slice; }

        SliceSortedMove = new ushort[11880 * 18];
        for (int i = 0; i < 11880; i++)
            for (int m = 0; m < 18; m++) { a.SliceSorted = i; a.EdgeMultiply(Moves.Table[m]); SliceSortedMove[i * 18 + m] = (ushort)a.SliceSorted; }

        UEdgeMove = new ushort[11880 * 18]; DEdgeMove = new ushort[11880 * 18];
        GroupPos = new byte[11880 * 4]; GroupPiece = new byte[11880 * 4];
        for (int i = 0; i < 11880; i++)
        {
            a.SetEdgeGroup(0, i);
            for (int j = 0, n = 0; j < 12; j++) if (a.Ep[j] < 4) { GroupPos[i * 4 + n] = (byte)j; GroupPiece[i * 4 + n] = a.Ep[j]; n++; }
            for (int m = 0; m < 18; m++)
            {
                a.SetEdgeGroup(0, i); a.EdgeMultiply(Moves.Table[m]); UEdgeMove[i * 18 + m] = (ushort)a.GetEdgeGroup(0);
                a.SetEdgeGroup(4, i); a.EdgeMultiply(Moves.Table[m]); DEdgeMove[i * 18 + m] = (ushort)a.GetEdgeGroup(4);
            }
        }

        CPermMove = new ushort[NCPerm * 18];
        for (int i = 0; i < NCPerm; i++)
            for (int m = 0; m < 18; m++) { a.CornerPerm = i; a.CornerMultiply(Moves.Table[m]); CPermMove[i * 18 + m] = (ushort)a.CornerPerm; }

        UdEdgeMove = new ushort[NUdEdge * 10];
        for (int i = 0; i < NUdEdge; i++)
            for (int k = 0; k < 10; k++) { a.UdEdgePerm = i; a.EdgeMultiply(Moves.Table[Moves.Phase2Moves[k]]); UdEdgeMove[i * 10 + k] = (ushort)a.UdEdgePerm; }

        SlicePermMove = new ushort[NSlicePerm * 10];
        for (int i = 0; i < NSlicePerm; i++)
            for (int k = 0; k < 10; k++) { a.SlicePerm = i; a.EdgeMultiply(Moves.Table[Moves.Phase2Moves[k]]); SlicePermMove[i * 10 + k] = (ushort)a.SlicePerm; }

        PruneTwistSlice = Bfs(NTwist, NSlice, TwistMove, 18, SliceMove, 18, null);
        PruneFlipSlice = Bfs(NFlip, NSlice, FlipMove, 18, SliceMove, 18, null);
        PruneTwistFlip = Bfs(NTwist, NFlip, TwistMove, 18, FlipMove, 18, null);
        PruneCPermSlicePerm = Bfs(NCPerm, NSlicePerm, CPermMove, 18, SlicePermMove, 10, Moves.Phase2Moves);
        PruneUdEdgeSlicePerm = Bfs(NUdEdge, NSlicePerm, UdEdgeMove, 10, SlicePermMove, 10, null);

        BuildSeconds = sw.Elapsed.TotalSeconds;
        built = true;
    }

    /// <summary>Combines the U-edge and D-edge group coordinates (both inside the top 8
    /// positions) into the phase-2 U/D edge permutation coordinate.</summary>
    public static int MergeUdEdges(int u, int d)
    {
        Span<byte> ep = stackalloc byte[8];
        for (int k = 0; k < 4; k++)
        {
            ep[GroupPos[u * 4 + k]] = GroupPiece[u * 4 + k];
            ep[GroupPos[d * 4 + k]] = (byte)(GroupPiece[d * 4 + k] + 4);
        }
        int r = 0;
        for (int i = 0; i < 8; i++) { int k = 0; for (int j = i + 1; j < 8; j++) if (ep[j] < ep[i]) k++; r = r * (8 - i) + k; }
        return r;
    }

    /// <summary>
    /// Breadth-first search over the product coordinate (a, b) starting at (0,0).
    /// <paramref name="aMoveIdx"/> maps the k-th searched move to a column of table A
    /// (needed when A is indexed by all 18 moves but we only search the 10 phase-2 moves).
    /// </summary>
    static byte[] Bfs(int na, int nb, ushort[] ta, int strideA, ushort[] tb, int strideB, int[] aMoveIdx)
    {
        int nMoves = Math.Min(strideA, strideB);
        int size = na * nb;
        var d = new byte[size];
        Array.Fill(d, (byte)255);
        d[0] = 0;
        int filled = 1;
        for (byte depth = 0; filled < size; depth++)
        {
            int before = filled;
            for (int i = 0; i < size; i++)
            {
                if (d[i] != depth) continue;
                int a = i / nb, b = i % nb;
                for (int k = 0; k < nMoves; k++)
                {
                    int ma = aMoveIdx == null ? k : aMoveIdx[k];
                    int j = ta[a * strideA + ma] * nb + tb[b * strideB + k];
                    if (d[j] == 255) { d[j] = (byte)(depth + 1); filled++; }
                }
            }
            if (filled == before) throw new Exception("BFS stalled: coordinate space not connected");
        }
        return d;
    }
}
