# Test suite: analytic solutions, conservation laws, geometry, and the
# image encoders.  Run with:  julia -t auto test/runtests.jl
using Test, Printf
include(joinpath(@__DIR__, "..", "src", "Karman.jl"))
using .Karman

"Half-way bounce-back on the top and bottom rows only (periodic in x)."
function wall_links(nx, ny)
    links = Link[]
    for y in (1, ny), x in 1:nx, i in 2:9
        sy = y - CY[i]
        (sy < 1 || sy > ny) && push!(links, Link(x, y, i, BOUNCE))
    end
    links
end

@testset "Karman" begin

@testset "checksums" begin
    @test Karman.crc32(Vector{UInt8}("123456789")) ⊻ 0xffffffff == 0xcbf43926
    @test Karman.adler32(Vector{UInt8}("Wikipedia")) == 0x11e60398
end

@testset "lattice isotropy" begin
    @test sum(W) ≈ 1
    @test all(CX[OPP[i]] == -CX[i] && CY[OPP[i]] == -CY[i] for i in 1:9)
    for (a, b) in ((1, 1), (2, 2), (1, 2))
        c = (CX, CY)
        m = sum(W[i] * c[a][i] * c[b][i] for i in 1:9)
        @test m ≈ (a == b ? 1 / 3 : 0) atol = 1e-15
    end
end

@testset "Poiseuille: TRT with Λ = 3/16 is exact" begin
    # periodic channel, body force g, walls half-way between nodes
    for (ny, nu) in ((9, 0.1), (17, 0.02), (24, 0.5))
        nx = 4; g = 1e-6
        s = Sim(nx, ny; nu = nu, magic = 3/16, links = wall_links(nx, ny), gx = g)
        run!(s, round(Int, 20 * ny^2 / nu))
        H = ny
        exact = [g / (2nu) * (y - 0.5) * (H + 0.5 - y) for y in 1:ny]
        err = maximum(abs.(s.ux[2, :] .- exact)) / maximum(exact)
        @printf("    ny = %2d  nu = %.2f   max rel. error %.2e\n", ny, nu, err)
        @test err < 1e-10
    end
end

@testset "Taylor-Green vortex: second-order convergence" begin
    errs = Float64[]
    Ns = (16, 32, 64)
    for N in Ns
        k = 2pi / N; U = 0.04 * 16 / N; nu = 0.02         # diffusive scaling
        u0(x, y) = (-U * cos(k * (x - 1)) * sin(k * (y - 1)),
                     U * sin(k * (x - 1)) * cos(k * (y - 1)))
        s = Sim(N, N; nu = nu, magic = 1/4, u0 = u0)
        # equilibrium initialisation with the correct pressure field
        for y in 1:N, x in 1:N
            r = 1 - 3 * U^2 / 4 * (cos(2k * (x - 1)) + cos(2k * (y - 1)))
            u, v = u0(x, y)
            for i in 1:9
                s.f[x, y, i] = Karman.feq(i, r, u, v)
            end
        end
        T = round(Int, log(2) / (2nu * k^2))            # amplitude halves
        run!(s, T)
        decay = exp(-2nu * k^2 * T)
        num = 0.0; den = 0.0
        for y in 1:N, x in 1:N
            u, v = u0(x, y)
            num += (s.ux[x, y] - u * decay)^2 + (s.uy[x, y] - v * decay)^2
            den += (u * decay)^2 + (v * decay)^2
        end
        push!(errs, sqrt(num / den))
    end
    orders = [log2(errs[j] / errs[j+1]) for j in 1:length(errs)-1]
    for (N, e) in zip(Ns, errs)
        @printf("    N = %3d   L2 error %.3e\n", N, e)
    end
    @printf("    observed orders: %s\n", join((@sprintf("%.2f", o) for o in orders), ", "))
    @test all(o -> 1.8 < o < 2.3, orders)
end

@testset "conservation in a periodic box" begin
    N = 40
    s = Sim(N, N; nu = 0.01, magic = 1/4,
            u0 = (x, y) -> (0.05sin(2pi * y / N + 0.3x), 0.05cos(2pi * x / N)))
    step!(s)
    m0 = Karman.mass(s)
    px0 = sum(s.rho .* s.ux); py0 = sum(s.rho .* s.uy)
    run!(s, 2000)
    @test abs(Karman.mass(s) - m0) / m0 < 1e-12
    @test abs(sum(s.rho .* s.ux) - px0) < 1e-11
    @test abs(sum(s.rho .* s.uy) - py0) < 1e-11
end

@testset "closed box with an obstacle conserves mass" begin
    # all-bounce-back walls plus a Bouzidi cylinder: links must not leak
    nx, ny = 60, 40
    c = Karman.Circle(25.3, 20.7, 7.4)
    solid, links = Karman.channel(nx, ny; inflow = y -> 0.0, circles = [c])
    # turn the inlet/outlet into walls
    links = [L.kind in (VELOCITY, PRESSURE) ? Link(L.x, L.y, L.i, BOUNCE) : L
             for L in links]
    s = Sim(nx, ny; nu = 0.05, magic = 1/4, solid = solid, links = links,
            u0 = (x, y) -> (0.03, 0.01))
    step!(s); m0 = Karman.mass(s)
    run!(s, 3000)
    # Bouzidi interpolation is not exactly mass conserving, but close
    @test abs(Karman.mass(s) - m0) / m0 < 1e-3
    @test maximum(abs.(s.ux)) < 0.03                # flow decays in a box
end

@testset "cylinder wall distances" begin
    c = Karman.Circle(10.5, 10.5, 4.0)
    solid, links = Karman.channel(21, 21; inflow = y -> 0.0, circles = [c])
    bz = filter(L -> L.kind == BOUZIDI, links)
    @test all(L -> 0 < L.q <= 1, bz)
    for L in bz     # the wall point really lies on the circle
        px = L.x - L.q * CX[L.i]; py = L.y - L.q * CY[L.i]
        @test hypot(px - c.cx, py - c.cy) ≈ c.r atol = 1e-9
    end
    # symmetric geometry -> symmetric link set
    @test length(bz) % 4 == 0
end

@testset "GIF LZW round trip" begin
    # minimal GIF LZW decoder to check the encoder
    function lzw_decode(data)
        acc = UInt32(0); nb = 0; pos = 1; width = 9
        read() = begin
            while nb < width
                acc |= UInt32(data[pos]) << nb; pos += 1; nb += 8
            end
            c = Int(acc & ((1 << width) - 1)); acc >>= width; nb -= width; c
        end
        dict = Vector{Vector{UInt8}}(); out = UInt8[]; prev = nothing
        reset() = (dict = [[UInt8(i)] for i in 0:255]; push!(dict, UInt8[], UInt8[]))
        reset()
        while true
            code = read()
            if code == 256
                reset(); width = 9; prev = nothing; continue
            elseif code == 257
                break
            end
            entry = code < length(dict) ? dict[code+1] :
                    vcat(prev, prev[1])
            append!(out, entry)
            if prev !== nothing && length(dict) < 4096
                push!(dict, vcat(prev, entry[1]))
                length(dict) == (1 << width) && width < 12 && (width += 1)
            end
            prev = entry
        end
        out
    end
    for data in (rand(UInt8, 100_000), rand(UInt8[1, 2, 3], 200_000),
                 fill(0x07, 50_000), UInt8[5])
        @test lzw_decode(Karman.gif_lzw(data)) == data
    end
end

@testset "DFG benchmark 2D-1 (Re = 20), coarse grid" begin
    r = Karman.run_2d1(N = 10, verbose = false)
    @printf("    N = 10: cD = %.4f  cL = %.5f  ΔP = %.4f\n", r.cD, r.cL, r.dp)
    @test abs(r.cD - 5.5795) / 5.5795 < 0.01
    @test abs(r.cL - 0.010619) / 0.010619 < 0.05
    @test abs(r.dp - 0.11752) / 0.11752 < 0.05
end

end
