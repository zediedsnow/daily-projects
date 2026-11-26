#!/usr/bin/env julia
# karman — lattice-Boltzmann flow past a cylinder, checked against the
# DFG benchmark of Schäfer & Turek (1996).
#
#   julia -t auto karman.jl bench2d1 [N ...]   steady Re = 20
#   julia -t auto karman.jl bench2d2 [N ...]   vortex shedding at Re = 100
#   julia -t auto karman.jl render   [N]       animated GIF + screenshot.png
include(joinpath(@__DIR__, "src", "Karman.jl"))
using .Karman, Printf

inrange(v, (lo, hi)) = lo <= v <= hi ? "ok " : "out"

function bench2d1(Ns)
    R = Karman.REF_2D1
    println("DFG 2D-1, Re = 20 (steady). Reference: cD ∈ $(R.cD), cL ∈ $(R.cL), ΔP ∈ $(R.dp)")
    println("    N    cells     steps      cD           cL            ΔP        time    MLUPS")
    for N in Ns
        r = Karman.run_2d1(N = N, verbose = false)
        s = r.case.sim
        @printf("  %3d  %7d  %8d   %.5f %s  %.6f %s  %.5f %s  %6.1fs  %5.1f\n",
                N, s.nx * s.ny, r.steps, r.cD, inrange(r.cD, R.cD),
                r.cL, inrange(r.cL, R.cL), r.dp, inrange(r.dp, R.dp),
                r.secs, r.mlups)
    end
end

function bench2d2(Ns)
    R = Karman.REF_2D2
    println("DFG 2D-2, Re = 100 (periodic). Reference: cDmax ∈ $(R.cDmax), cLmax ∈ $(R.cLmax), St ∈ $(R.St)")
    println("    N    cells     steps    cDmax        cLmax        St          periods   time    MLUPS")
    for N in Ns
        r = Karman.run_2d2(N = N, verbose = false)
        s = r.case.sim
        if isnan(r.cDmax)
            @printf("  %3d  diverged (tau = %.4f is too close to 1/2; use N >= 20)\n",
                    N, 1 / s.omega_p)
            continue
        end
        @printf("  %3d  %7d  %8d   %.4f %s   %.4f %s   %.4f %s    %2d    %6.1fs  %5.1f\n",
                N, s.nx * s.ny, r.steps, r.cDmax, inrange(r.cDmax, R.cDmax),
                r.cLmax, inrange(r.cLmax, R.cLmax), r.St, inrange(r.St, R.St),
                r.periods, r.secs, r.mlups)
    end
end

function render(N)
    scale = max(1, round(Int, 40 / N))
    # one shedding period is ~1/3 time unit (~40 frames)
    c0 = Karman.cylinder(N = N, Re = 100)
    spt = 1 / (c0.dx * c0.ubar)
    every = max(1, round(Int, spt / 120))
    T = 10.0
    println("rendering N = $N (×$scale), frame every $every steps ...")
    r = Karman.run_2d2(N = N, T = T, measure = 2.0, frame_every = every,
                       frame_from = T - 0.5, verbose = true)
    s = r.case.sim
    pal = Karman.vort_palette()
    up(img) = scale == 1 ? img :
        [img[(x - 1) ÷ scale + 1, (y - 1) ÷ scale + 1]
         for x in 1:size(img, 1) * scale, y in 1:size(img, 2) * scale]
    # keep exactly one shedding period so the GIF loops seamlessly
    period = N / (r.St * r.case.ubar)
    k = clamp(round(Int, period / every), 1, length(r.frames))
    frames = [up(f) for f in r.frames[end-k+1:end]]
    Karman.write_gif(joinpath(@__DIR__, "vortex_street.gif"), frames, pal; delay = 4)
    clip = 40 * r.case.ubar * r.case.dx
    shot = Karman.field_indices(Karman.vorticity(s), s.solid, clip; scale = scale)
    Karman.write_png(joinpath(@__DIR__, "screenshot.png"), shot, pal)
    @printf("cDmax %.4f  cLmax %.4f  St %.4f  -> %d GIF frames, screenshot.png\n",
            r.cDmax, r.cLmax, r.St, length(frames))
end

cmd = isempty(ARGS) ? "bench2d2" : ARGS[1]
Ns = length(ARGS) > 1 ? parse.(Int, ARGS[2:end]) : cmd == "bench2d1" ? [10, 20] : [20]
if cmd == "bench2d1"
    bench2d1(Ns)
elseif cmd == "bench2d2"
    bench2d2(Ns)
elseif cmd == "render"
    render(length(ARGS) > 1 ? Ns[1] : 20)
else
    println("usage: julia -t auto karman.jl (bench2d1 | bench2d2 | render) [N ...]")
end
