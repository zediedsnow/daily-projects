# ---------------------------------------------------------------------------
# D2Q9 lattice, the simulation state, and one time step:
#     1. boundary links: compute the populations that would have to be
#        pulled from outside the fluid (walls, inlet, outlet, obstacles)
#     2. one fused, threaded sweep: pull-stream + substitute link values +
#        TRT collision, writing into the second population array
# Populations are stored "structure of arrays": f[x, y, i].
# ---------------------------------------------------------------------------

const CX  = (0, 1, 0, -1,  0, 1, -1, -1,  1)
const CY  = (0, 0, 1,  0, -1, 1,  1, -1, -1)
const W   = (4/9, 1/9, 1/9, 1/9, 1/9, 1/36, 1/36, 1/36, 1/36)
const OPP = (1, 4, 5, 2, 3, 8, 9, 6, 7)

@enum LinkKind::UInt8 BOUNCE BOUZIDI VELOCITY PRESSURE

"""
A boundary link: population `i` arriving at fluid node `(x, y)` would have
been pulled from `(x - cx_i, y - cy_i)`, which is outside the fluid.
"""
struct Link
    x::Int32
    y::Int32
    i::Int8
    kind::LinkKind
    q::Float64          # BOUZIDI: wall distance along the link, in (0, 1]
    xf::Int32           # BOUZIDI: next fluid node x + c_i (0 = none)
    yf::Int32
    ux::Float64         # VELOCITY: wall velocity; PRESSURE: ux = wall density
    uy::Float64
    xp::Int32           # PRESSURE: inner neighbour used to extrapolate u
    yp::Int32
    body::Bool          # count this link's momentum exchange as body force
end

Link(x, y, i, kind; q = 0.0, xf = 0, yf = 0, ux = 0.0, uy = 0.0,
     xp = 0, yp = 0, body = false) =
    Link(x, y, i, kind, q, xf, yf, ux, uy, xp, yp, body)

mutable struct Sim
    nx::Int
    ny::Int
    f::Array{Float64,3}     # post-collision populations (time t)
    fn::Array{Float64,3}    # work array (time t+1)
    rho::Matrix{Float64}
    ux::Matrix{Float64}
    uy::Matrix{Float64}
    solid::Matrix{Bool}
    links::Vector{Link}     # sorted by node, column-major
    lbuf::Vector{Float64}   # value of each link's population this step
    lstart::Matrix{Int32}   # first link of node (x, y)
    lcount::Matrix{Int8}    # number of links of node (x, y)
    omega_p::Float64        # symmetric relaxation rate   1/tau
    omega_m::Float64        # antisymmetric rate from the magic parameter
    gx::Float64             # uniform body force density
    gy::Float64
    uscale::Float64         # multiplier on VELOCITY links (inflow ramp)
    force::NTuple{2,Float64}  # momentum exchange on `body` links, last step
    t::Int
end

"""
    Sim(nx, ny; nu, magic = 3/16, solid, links, gx, gy)

Two-relaxation-time model: `nu = (tau - 1/2)/3` fixes the symmetric rate,
the "magic" product Λ = (τ⁺ - ½)(τ⁻ - ½) fixes the antisymmetric rate.
Λ = 3/16 puts half-way bounce-back walls exactly mid-link for Poiseuille
flow; Λ = 1/4 is the most stable choice.
"""
function Sim(nx, ny; nu, magic = 3/16, solid = falses(nx, ny),
             links = Link[], gx = 0.0, gy = 0.0, rho0 = 1.0,
             u0 = (x, y) -> (0.0, 0.0))
    taup = 3nu + 0.5
    taum = magic / (taup - 0.5) + 0.5
    f = zeros(nx, ny, 9)
    rho = fill(rho0, nx, ny); ux = zeros(nx, ny); uy = zeros(nx, ny)
    for y in 1:ny, x in 1:nx
        u, v = solid[x, y] ? (0.0, 0.0) : u0(x, y)
        ux[x, y] = u; uy[x, y] = v
        for i in 1:9
            f[x, y, i] = feq(i, rho0, u, v)
        end
    end
    links = sort(links, by = L -> (L.y, L.x, L.i))
    lstart = zeros(Int32, nx, ny); lcount = zeros(Int8, nx, ny)
    for (k, L) in enumerate(links)
        lcount[L.x, L.y] == 0 && (lstart[L.x, L.y] = k)
        lcount[L.x, L.y] += 1
    end
    Sim(nx, ny, f, similar(f), rho, ux, uy, Matrix{Bool}(solid), links,
        zeros(length(links)), lstart, lcount, 1 / taup, 1 / taum, gx, gy, 1.0, (0.0, 0.0), 0)
end

@inline function feq(i, rho, u, v)
    cu = CX[i] * u + CY[i] * v
    W[i] * rho * (1 + 3cu + 4.5cu * cu - 1.5(u * u + v * v))
end

# --- boundary links ---------------------------------------------------------
function apply_links!(s::Sim)
    f, lbuf = s.f, s.lbuf
    Fx = 0.0; Fy = 0.0
    @inbounds for (k, L) in enumerate(s.links)
        x, y, i = L.x, L.y, L.i
        ib = OPP[i]                     # direction pointing into the wall
        val = if L.kind == BOUNCE
            f[x, y, ib]
        elseif L.kind == BOUZIDI
            q = L.q
            if q >= 0.5
                f[x, y, ib] / (2q) + (2q - 1) / (2q) * f[x, y, i]
            elseif L.xf > 0
                2q * f[x, y, ib] + (1 - 2q) * f[L.xf, L.yf, ib]
            else                        # one-cell gap: plain bounce-back
                f[x, y, ib]
            end
        elseif L.kind == VELOCITY
            cu = CX[i] * L.ux + CY[i] * L.uy
            f[x, y, ib] + 6 * W[i] * s.uscale * cu
        else                            # PRESSURE (anti-bounce-back)
            u = 1.5s.ux[x, y] - 0.5s.ux[L.xp, L.yp]
            v = 1.5s.uy[x, y] - 0.5s.uy[L.xp, L.yp]
            cu = CX[i] * u + CY[i] * v
            -f[x, y, ib] + 2W[i] * L.ux * (1 + 4.5cu * cu - 1.5(u * u + v * v))
        end
        lbuf[k] = val
        if L.body       # momentum carried into the wall and back out again
            m = f[x, y, ib] + val
            Fx += CX[ib] * m
            Fy += CY[ib] * m
        end
    end
    s.force = (Fx, Fy)
end

# --- fused pull-streaming + TRT collision (Guo-type body force) ----------
function stream_collide!(s::Sim)
    f, fn, nx, ny = s.f, s.fn, s.nx, s.ny
    wp, wm, gx, gy = s.omega_p, s.omega_m, s.gx, s.gy
    srcfac = 1 - wm / 2
    Threads.@threads for y in 1:ny
        stream_collide_row!(s, f, fn, s.solid, s.rho, s.ux, s.uy, s.lbuf,
                            s.lstart, s.lcount, s.links, nx, ny, y,
                            wp, wm, gx, gy, srcfac)
    end
end

function stream_collide_row!(s, f, fn, solid, R, U, V, lbuf, lstart, lcount,
                             links, nx, ny, y, wp, wm, gx, gy, srcfac)
    yd = y == 1 ? ny : y - 1          # row below (pull for cy = +1)
    yu = y == ny ? 1 : y + 1          # row above (pull for cy = -1)
    @inbounds for x in 1:nx
        solid[x, y] && continue
        xl = x == 1 ? nx : x - 1
        xr = x == nx ? 1 : x + 1
        f1 = f[x,  y,  1]; f2 = f[xl, y,  2]; f3 = f[x,  yd, 3]
        f4 = f[xr, y,  4]; f5 = f[x,  yu, 5]; f6 = f[xl, yd, 6]
        f7 = f[xr, yd, 7]; f8 = f[xr, yu, 8]; f9 = f[xl, yu, 9]
        n = lcount[x, y]
        if n > 0                          # boundary node: substitute links
            fs = (f1, f2, f3, f4, f5, f6, f7, f8, f9)
            k0 = lstart[x, y]
            for k in k0:k0+n-1
                fs = Base.setindex(fs, lbuf[k], Int(links[k].i))
            end
            f1, f2, f3, f4, f5, f6, f7, f8, f9 = fs
        end
        rho = f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9
        jx = f2 - f4 + f6 - f7 - f8 + f9 + 0.5gx
        jy = f3 - f5 + f6 + f7 - f8 - f9 + 0.5gy
        u = jx / rho; v = jy / rho
        R[x, y] = rho; U[x, y] = u; V[x, y] = v
        usq = 1.5(u * u + v * v)
        fn[x, y, 1] = f1 - wp * (f1 - W[1] * rho * (1 - usq))
        trt_pair!(fn, x, y, 2, 4, f2, f4, rho, u, v, usq, wp, wm, srcfac, gx, gy)
        trt_pair!(fn, x, y, 3, 5, f3, f5, rho, u, v, usq, wp, wm, srcfac, gx, gy)
        trt_pair!(fn, x, y, 6, 8, f6, f8, rho, u, v, usq, wp, wm, srcfac, gx, gy)
        trt_pair!(fn, x, y, 7, 9, f7, f9, rho, u, v, usq, wp, wm, srcfac, gx, gy)
    end
end

@inline function trt_pair!(fn, x, y, a, b, fa, fb, rho, u, v, usq, wp, wm,
                           srcfac, gx, gy)
    cu = CX[a] * u + CY[a] * v
    es = W[a] * rho * (1 + 4.5cu * cu - usq)    # symmetric equilibrium
    ea = W[a] * rho * 3cu                        # antisymmetric equilibrium
    sp = 0.5(fa + fb); sm = 0.5(fa - fb)
    src = srcfac * 3W[a] * (CX[a] * gx + CY[a] * gy)
    dp = wp * (sp - es)
    dm = wm * (sm - ea) - src
    @inbounds fn[x, y, a] = fa - dp - dm
    @inbounds fn[x, y, b] = fb - dp + dm
    nothing
end

"One lattice time step."
function step!(s::Sim)
    apply_links!(s)
    stream_collide!(s)
    s.f, s.fn = s.fn, s.f
    s.t += 1
    s
end

function run!(s::Sim, n)
    for _ in 1:n
        step!(s)
    end
    s
end

"Vorticity ∂v/∂x - ∂u/∂y by central differences (zero inside solids)."
function vorticity(s::Sim)
    w = zeros(s.nx, s.ny)
    for y in 2:s.ny-1, x in 2:s.nx-1
        s.solid[x, y] && continue
        w[x, y] = 0.5(s.uy[x+1, y] - s.uy[x-1, y]) - 0.5(s.ux[x, y+1] - s.ux[x, y-1])
    end
    w
end

"Total mass in the fluid (for conservation checks)."
mass(s::Sim) = sum(s.rho[x, y] for y in 1:s.ny, x in 1:s.nx if !s.solid[x, y])
