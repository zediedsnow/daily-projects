using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace Cubist;

public static class Program
{
    const string Usage = @"cubist - Rubik's cube solver (Kociemba two-phase) with an independent optimality auditor

usage:
  cubist solve <moves...>              solve the cube scrambled by these moves, e.g. cubist solve R U R' F2 D
  cubist solve --facelets <54 chars>   solve a cube given as a facelet string (URFDLB order)
         [--optimal]                   keep searching until the solution is proven optimal
         [--target N] [--time S]       stop at the first solution <= N moves (default 20) / after S seconds
         [--svg file.svg]              write a film strip of the solution
  cubist scramble [N]                  print a random-state cube (or an N-move scramble) and solve it
  cubist bench [N] [--seed S]          solve N uniformly random cubes and print statistics
  cubist audit [N] [--seed S]          cross-check optimal two-phase against the meet-in-the-middle solver
  cubist verify                        run the full self-test suite";

    public static int Main(string[] args)
    {
        if (args.Length == 0) { Console.WriteLine(Usage); return 0; }
        try
        {
            return args[0] switch
            {
                "solve" => SolveCmd(args.Skip(1).ToList()),
                "scramble" => ScrambleCmd(args.Skip(1).ToList()),
                "bench" => Bench(args.Skip(1).ToList()),
                "audit" => Audit(args.Skip(1).ToList()),
                "verify" => Verify.Run(),
                _ => Fail(Usage),
            };
        }
        catch (FormatException e) { return Fail("error: " + e.Message); }
    }

    static int Fail(string msg) { Console.Error.WriteLine(msg); return 2; }

    static string Opt(List<string> a, string name, string def = null)
    {
        int i = a.IndexOf(name);
        if (i < 0) return def;
        if (i + 1 >= a.Count) throw new FormatException($"{name} needs a value");
        string v = a[i + 1]; a.RemoveRange(i, 2); return v;
    }
    static bool Flag(List<string> a, string name) => a.Remove(name);

    static bool UseColor => !Console.IsOutputRedirected && Environment.GetEnvironmentVariable("NO_COLOR") == null;

    static int SolveCmd(List<string> a)
    {
        bool optimal = Flag(a, "--optimal");
        int target = int.Parse(Opt(a, "--target", "20"));
        double time = double.Parse(Opt(a, "--time", optimal ? "600" : "30"), System.Globalization.CultureInfo.InvariantCulture);
        string svg = Opt(a, "--svg");
        string facelets = Opt(a, "--facelets");
        CubieCube cube;
        string desc;
        if (facelets != null)
        {
            cube = CubieCube.FromFacelets(facelets, out var err);
            if (cube == null) return Fail("invalid cube: " + err);
            desc = "facelets " + cube.ToFaceletString();
        }
        else
        {
            var moves = Moves.Parse(string.Join(" ", a));
            cube = new CubieCube(); cube.Apply(moves);
            desc = "scramble " + Moves.Format(moves);
        }
        return SolveAndPrint(cube, desc, optimal ? -1 : target, time, svg);
    }

    static int SolveAndPrint(CubieCube cube, string desc, int target, double time, string svg)
    {
        var sw = Stopwatch.StartNew();
        var solver = new TwoPhaseSolver();
        Console.WriteLine($"tables built in {Tables.BuildSeconds:F2}s");
        Console.WriteLine(desc);
        Console.Write(Render.Net(cube, UseColor));
        var r = target < 0 ? solver.Solve(cube, target, time) : MultiSolver.Solve(cube, target, time);
        if (r.Moves == null) { Console.WriteLine("no solution found within the time limit"); return 1; }
        var check = cube.Clone(); check.Apply(r.Moves);
        Console.WriteLine($"solution ({r.Length} moves{(r.ProvenOptimal ? ", proven optimal" : "")}): {Moves.Format(r.Moves)}");
        Console.WriteLine($"search: {r.Seconds * 1000:F1} ms{(r.Direction != "" ? " (won by the " + r.Direction + " search)" : "")}, {r.Phase1Nodes:N0} phase-1 nodes, {r.Phase2Starts:N0} phase-2 searches, {r.Phase2Nodes:N0} phase-2 nodes");
        Console.WriteLine(check.IsSolved() ? "verified: applying the solution leaves the cube solved" : "BUG: solution does not solve the cube!");
        if (svg != null)
        {
            File.WriteAllText(svg, Render.Filmstrip(cube, r.Moves, $"cubist: {r.Length}-move solution{(r.ProvenOptimal ? " (optimal)" : "")}",
                desc.Length > 110 ? desc[..110] + "..." : desc));
            Console.WriteLine($"wrote {svg}");
        }
        return check.IsSolved() ? 0 : 1;
    }

    static int ScrambleCmd(List<string> a)
    {
        var rng = new Random();
        CubieCube cube; string desc;
        if (a.Count > 0)
        {
            var mv = Moves.RandomScramble(rng, int.Parse(a[0]));
            cube = new CubieCube(); cube.Apply(mv); desc = "scramble " + Moves.Format(mv);
        }
        else { cube = CubieCube.Random(rng); desc = "random state " + cube.ToFaceletString(); }
        return SolveAndPrint(cube, desc, 20, 10, null);
    }

    static int Bench(List<string> a)
    {
        int seed = int.Parse(Opt(a, "--seed", "1"));
        int n = a.Count > 0 ? int.Parse(a[0]) : 1000;
        int target = 20;
        var solver = new TwoPhaseSolver();
        Console.WriteLine($"tables built in {Tables.BuildSeconds:F2}s; solving {n} uniformly random cubes (target <= {target} moves)");
        var rng = new Random(seed);
        var hist = new SortedDictionary<int, int>();
        var times = new List<double>();
        int bad = 0;
        for (int i = 0; i < n; i++)
        {
            var c = CubieCube.Random(rng);
            var r = MultiSolver.Solve(c, target, 5);
            var check = c.Clone(); check.Apply(r.Moves);
            if (!check.IsSolved()) bad++;
            hist[r.Length] = hist.GetValueOrDefault(r.Length) + 1;
            times.Add(r.Seconds * 1000);
        }
        times.Sort();
        Console.WriteLine($"verified: {n - bad}/{n} solutions solve their cube");
        Console.WriteLine("length distribution:");
        foreach (var (len, cnt) in hist) Console.WriteLine($"  {len,2} moves: {cnt,5}  {new string('#', Math.Max(1, cnt * 60 / n))}");
        Console.WriteLine($"mean length {hist.Sum(kv => (double)kv.Key * kv.Value) / n:F2} moves");
        Console.WriteLine($"time per cube: median {times[n / 2]:F2} ms, mean {times.Average():F2} ms, p99 {times[(int)(n * 0.99)]:F2} ms, max {times[^1]:F2} ms");
        return bad == 0 ? 0 : 1;
    }

    static int Audit(List<string> a)
    {
        int seed = int.Parse(Opt(a, "--seed", "7"));
        int n = a.Count > 0 ? int.Parse(a[0]) : 100;
        return Verify.AuditOptimal(n, seed) ? 0 : 1;
    }
}
