using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Cubist;

public sealed class SolveResult
{
    public List<int> Moves;          // null if nothing was found
    public bool ProvenOptimal;       // the search space below Moves.Count was exhausted
    public double Seconds;
    public long Phase1Nodes, Phase2Nodes, Phase2Starts;
    public string Direction = "";
    public int Length => Moves?.Count ?? -1;
}

/// <summary>
/// Kociemba's two-phase algorithm.
///
/// Phase 1 drives the cube into the subgroup H = &lt;U, D, R2, L2, F2, B2&gt; (all
/// twists/flips fixed and the 4 middle-slice edges in the middle slice).
/// Phase 2 solves within H using only those 10 moves.
///
/// Both phases are IDA* searches guided by pruning tables. Because phase 1 is
/// iterated over increasing depth and every phase-1 leaf is finished by an exact
/// phase-2 search, the procedure is *complete*: if it is allowed to run until the
/// remaining budget is exhausted, the best solution it found is optimal.
/// </summary>
public sealed class TwoPhaseSolver
{
    const int MaxDepth = 40;
    readonly int[] path = new int[MaxDepth];
    CubieCube start;

    int uEdge0, dEdge0;       // U/D edge group coordinates of the start cube
    int limit;                 // only accept solutions with length <= limit
    int target;                // stop as soon as a solution with length <= target is found
    int phase2Cap;
    List<int> best;
    bool done, timedOut;
    long nodes1, nodes2, starts2;
    Stopwatch sw;
    double timeLimit;

    public TwoPhaseSolver() { Tables.Build(); }

    /// <param name="target">Return as soon as a solution of at most this length is found
    /// (use -1 to search for a proven optimum).</param>
    /// <param name="timeLimitSec">Give up improving after this long and return the best so far.</param>
    public SolveResult Solve(CubieCube cube, int target = 20, double timeLimitSec = 10, int maxLength = 30)
    {
        start = cube.Clone();
        this.target = target;
        bool optimal = target < 0;
        phase2Cap = optimal ? MaxDepth : 10;   // capping phase 2 at 10 is fast but gives up completeness
        limit = maxLength;
        best = null; done = false; timedOut = false;
        nodes1 = nodes2 = starts2 = 0;
        timeLimit = timeLimitSec;
        sw = Stopwatch.StartNew();

        int twist = cube.Twist, flip = cube.Flip, slice = cube.Slice, ss = cube.SliceSorted, cp = cube.CornerPerm;
        uEdge0 = cube.GetEdgeGroup(0); dEdge0 = cube.GetEdgeGroup(4);
        int h0 = Math.Max(Math.Max(Tables.PruneTwistSlice[twist * Tables.NSlice + slice], Tables.PruneFlipSlice[flip * Tables.NSlice + slice]),
                          Tables.PruneTwistFlip[twist * Tables.NFlip + flip]);
        for (int depth1 = h0; depth1 <= limit && !done; depth1++)
            Phase1(twist, flip, ss, cp, depth1, 0, -10);

        return new SolveResult
        {
            Moves = best,
            ProvenOptimal = optimal && !timedOut && best != null,
            Seconds = sw.Elapsed.TotalSeconds,
            Phase1Nodes = nodes1, Phase2Nodes = nodes2, Phase2Starts = starts2,
        };
    }

    /// <summary>Set by a sibling search (see <see cref="MultiSolver"/>) to stop this one.</summary>
    public volatile bool Abort;

    void CheckTime()
    {
        if (Abort) { done = true; timedOut = true; return; }
        if (sw.Elapsed.TotalSeconds > timeLimit && best != null) { done = true; timedOut = true; }
        if (sw.Elapsed.TotalSeconds > timeLimit * 10) { done = true; timedOut = true; }
    }

    // Phase 1 tracks twist, flip and the slice edges' positions+order (ss / 24 is the
    // phase-1 slice coordinate), plus the corner permutation, which is irrelevant to
    // phase 1 but lets us reject hopeless phase-2 starts without touching the cube.
    void Phase1(int twist, int flip, int ss, int cp, int togo, int depth, int lastFace)
    {
        if (togo == 0)
        {
            // In H. A phase-2 move as the last phase-1 move would just duplicate work
            // already done with a shorter phase 1.
            if (twist == 0 && flip == 0 && ss < 24 && (depth == 0 || !Moves.IsPhase2[path[depth - 1]])
                && Tables.PruneCPermSlicePerm[cp * 24 + ss] <= Math.Min(limit - depth, phase2Cap))
                Phase2Start(depth, cp, ss);
            return;
        }
        int slice = ss / 24;
        if ((++nodes1 & 8191) == 0) CheckTime();
        for (int m = 0; m < 18 && !done; m++)
        {
            int face = m / 3;
            if (!Moves.Allowed(lastFace, face)) continue;
            int nt = Tables.TwistMove[twist * 18 + m], nf = Tables.FlipMove[flip * 18 + m], nss = Tables.SliceSortedMove[ss * 18 + m], ns = nss / 24;
            int h = Math.Max(Tables.PruneTwistSlice[nt * Tables.NSlice + ns], Tables.PruneFlipSlice[nf * Tables.NSlice + ns]);
            if (h > togo - 1 || Tables.PruneTwistFlip[nt * Tables.NFlip + nf] > togo - 1) continue;
            path[depth] = m;
            Phase1(nt, nf, nss, Tables.CPermMove[cp * 18 + m], togo - 1, depth + 1, face);
        }
    }

    void Phase2Start(int depth1, int cp, int sp)
    {
        int budget = Math.Min(limit - depth1, phase2Cap);
        if (budget < 0) return;
        starts2++;
        // Replay the phase-1 path on just the two 11,880-state edge-group coordinates.
        int u = uEdge0, d = dEdge0;
        for (int i = 0; i < depth1; i++) { u = Tables.UEdgeMove[u * 18 + path[i]]; d = Tables.DEdgeMove[d * 18 + path[i]]; }
        int ue = Tables.MergeUdEdges(u, d);
        int h = Math.Max(Tables.PruneCPermSlicePerm[cp * 24 + sp], Tables.PruneUdEdgeSlicePerm[ue * 24 + sp]);
        int lastFace = depth1 == 0 ? -10 : path[depth1 - 1] / 3;
        for (int d2 = h; d2 <= budget; d2++)
        {
            if (Phase2(cp, ue, sp, d2, depth1, lastFace))
            {
                int len = depth1 + d2;
                best = path.Take(len).ToList();
                limit = len - 1;
                if (len <= target) done = true;
                return;
            }
        }
    }

    bool Phase2(int cp, int ue, int sp, int togo, int depth, int lastFace)
    {
        if (togo == 0) return cp == 0 && ue == 0 && sp == 0;
        nodes2++;
        for (int k = 0; k < 10; k++)
        {
            int m = Moves.Phase2Moves[k], face = m / 3;
            if (!Moves.Allowed(lastFace, face)) continue;
            int ncp = Tables.CPermMove[cp * 18 + m], nue = Tables.UdEdgeMove[ue * 10 + k], nsp = Tables.SlicePermMove[sp * 10 + k];
            int h = Math.Max(Tables.PruneCPermSlicePerm[ncp * 24 + nsp], Tables.PruneUdEdgeSlicePerm[nue * 24 + nsp]);
            if (h > togo - 1) continue;
            path[depth] = m;
            if (Phase2(ncp, nue, nsp, togo - 1, depth + 1, face)) return true;
        }
        return false;
    }
}

/// <summary>
/// Runs six two-phase searches concurrently, as Kociemba's own solver does: the cube
/// seen along each of its three axes, and the inverse cube along each axis. Different
/// directions have very different phase-1 landscapes, so the first to reach the
/// target is often far faster than any single search, which kills the slow tail.
/// </summary>
public static class MultiSolver
{
    // Rotation of the whole cube by 120 degrees around the URF-DBL diagonal (U->R->F->U).
    static readonly CubieCube Urf3 = new(
        new[] { 0, 4, 5, 1, 3, 7, 6, 2 }, new[] { 1, 2, 1, 2, 2, 1, 2, 1 },
        new[] { 1, 8, 5, 9, 3, 11, 7, 10, 0, 4, 6, 2 }, new[] { 1, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1 });

    // Rot[r] = Urf3^r; MoveMap[r][m'] = the original-frame move equal to Rot * move[m'] * Rot^-1.
    static readonly CubieCube[] Rot = new CubieCube[3];
    static readonly int[][] MoveMap = new int[3][];

    static MultiSolver()
    {
        Rot[0] = new CubieCube();
        for (int r = 1; r < 3; r++) { Rot[r] = Rot[r - 1].Clone(); Rot[r].Multiply(Urf3); }
        for (int r = 0; r < 3; r++)
        {
            MoveMap[r] = new int[18];
            var inv = Rot[r].Inverse();
            for (int m = 0; m < 18; m++)
            {
                var x = Rot[r].Clone(); x.Multiply(Moves.Table[m]); x.Multiply(inv);
                int found = Enumerable.Range(0, 18).FirstOrDefault(k => Moves.Table[k].SameAs(x), -1);
                if (found < 0) throw new Exception("URF3 conjugation does not map moves to moves");
                MoveMap[r][m] = found;
            }
        }
    }

    public static SolveResult Solve(CubieCube cube, int target = 20, double timeLimitSec = 10)
    {
        var sw = Stopwatch.StartNew();
        var solvers = new TwoPhaseSolver[6];
        var results = new SolveResult[6];
        var threads = new System.Threading.Thread[6];
        for (int i = 0; i < 6; i++)
        {
            int r = i % 3; bool inverse = i >= 3;
            // c' = Rot^-1 * c * Rot  (cube seen from a rotated viewpoint)
            var c = Rot[r].Inverse(); c.Multiply(cube); c.Multiply(Rot[r]);
            if (inverse) c = c.Inverse();
            solvers[i] = new TwoPhaseSolver();
            int idx = i;
            threads[i] = new System.Threading.Thread(() =>
            {
                var res = solvers[idx].Solve(c, target, timeLimitSec);
                if (res.Moves != null && res.Length <= target)
                    foreach (var s in solvers) s.Abort = true;
                // translate back to the original frame
                if (res.Moves != null)
                {
                    var mv = res.Moves.Select(m => MoveMap[r][m]).ToList();
                    if (inverse) { mv.Reverse(); mv = mv.Select(Moves.Inverse).ToList(); }
                    res.Moves = mv;
                }
                res.Direction = (inverse ? "inverse, " : "") + new[] { "U-D axis", "R-L axis", "F-B axis" }[r];
                results[idx] = res;
            }, 16 << 20);
        }
        foreach (var t in threads) t.Start();
        foreach (var t in threads) t.Join();
        var best = results.Where(x => x.Moves != null).OrderBy(x => x.Length).ThenBy(x => x.Seconds).First();
        return new SolveResult
        {
            Moves = best.Moves, Direction = best.Direction, Seconds = sw.Elapsed.TotalSeconds,
            Phase1Nodes = results.Sum(x => x.Phase1Nodes), Phase2Nodes = results.Sum(x => x.Phase2Nodes),
            Phase2Starts = results.Sum(x => x.Phase2Starts),
        };
    }
}
