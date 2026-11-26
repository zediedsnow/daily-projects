# ---------------------------------------------------------------------------
# The DFG benchmark "flow around a cylinder" (Schäfer & Turek, 1996):
# channel 2.2 x 0.41, cylinder D = 0.1 centred at (0.2, 0.2), ν = 1e-3,
# parabolic inflow with mean speed Ū.  Test 2D-1: Re = 20 (steady),
# test 2D-2: Re = 100 (periodic vortex shedding).
# ---------------------------------------------------------------------------

const L_CH = 2.2
const H_CH = 0.41
const D_CYL = 0.1
const XC = 0.2
const YC = 0.2

"Reference intervals published with the benchmark."
const REF_2D1 = (cD = (5.57, 5.59), cL = (0.0104, 0.0110), dp = (0.1172, 0.1176))
const REF_2D2 = (cDmax = (3.22, 3.24), cLmax = (0.99, 1.01), St = (0.295, 0.305))

struct Cylinder
    sim::Sim
    N::Int          # lattice cells per diameter
    ubar::Float64   # mean inflow speed in lattice units
    Re::Float64
    dx::Float64     # physical length of one cell
end

"Build the benchmark at `N` cells per diameter, mean lattice inflow `ubar`."
function cylinder(; N = 20, Re = 100, ubar = 0.05, magic = 1/4)
    dx = D_CYL / N
    nx = round(Int, L_CH / dx)
    ny = round(Int, H_CH / dx)
    H = ny                               # walls at 1/2 and ny + 1/2
    umax = 1.5ubar
    inflow(yw) = 4umax * (yw - 0.5) * (H - (yw - 0.5)) / H^2
    circ = Circle(XC / dx + 0.5, YC / dx + 0.5, N / 2)
    solid, links = channel(nx, ny; inflow = inflow, circles = [circ])
    nu = ubar * N / Re
    s = Sim(nx, ny; nu = nu, magic = magic, solid = solid, links = links)
    Cylinder(s, N, ubar, Re, dx)
end

"Drag / lift coefficients from the last step's momentum exchange."
function coefficients(c::Cylinder)
    Fx, Fy = c.sim.force
    k = 2 / (c.ubar^2 * c.N)
    Fx * k, Fy * k
end

"Linear interpolation of a node field in y at column x."
ycol(field, x, y) = (y0 = floor(Int, y); a = y - y0;
                     (1 - a) * field[x, y0] + a * field[x, y0+1])

"""
Value of `field` at the cylinder surface point (xs, y), extrapolated
linearly from the two nearest fluid columns on side `dir` (-1 front, +1 back).
"""
function surface_value(field, xs, y, dir)
    x1 = dir < 0 ? floor(Int, xs) : ceil(Int, xs)
    x2 = x1 + dir
    v1 = ycol(field, x1, y); v2 = ycol(field, x2, y)
    d1 = abs(xs - x1)
    v1 + (v1 - v2) * d1
end

"Pressure drop between front (0.15, 0.2) and back (0.25, 0.2), physical units."
function pressure_drop(c::Cylinder)
    s = c.sim
    xa = 0.15 / c.dx + 0.5; xb = 0.25 / c.dx + 0.5; y = YC / c.dx + 0.5
    drho = surface_value(s.rho, xa, y, -1) - surface_value(s.rho, xb, y, +1)
    drho / 3 * (Re_to_ubar(c.Re) / c.ubar)^2
end

Re_to_ubar(Re) = Re * 1e-3 / D_CYL

"""
Steady test 2D-1: iterate until the drag coefficient stops changing.
Returns a named tuple of results.
"""
function run_2d1(; N = 20, ubar = 0.05, tol = 1e-9, maxsteps = 400_000,
                 verbose = true)
    c = cylinder(N = N, Re = 20, ubar = ubar, magic = 3/16)
    s = c.sim
    cd_old = Inf; t0 = time()
    chunk = 1000
    while s.t < maxsteps
        run!(s, chunk)
        cd, cl = coefficients(c)
        verbose && s.t % 20_000 == 0 &&
            @printf("    step %7d  cD = %.6f  cL = %.6f\n", s.t, cd, cl)
        abs(cd - cd_old) < tol * chunk && break
        cd_old = cd
    end
    secs = time() - t0
    cd, cl = coefficients(c)
    (cD = cd, cL = cl, dp = pressure_drop(c), steps = s.t, secs = secs,
     mlups = count(!, s.solid) * s.t / secs / 1e6, case = c)
end

"""
Periodic test 2D-2: ramp the inflow, let the vortex street develop, then
record cD, cL over the final `measure` time units. The Strouhal number
comes from the period of the lift signal (zero crossings, interpolated).
`frame_every` > 0 collects vorticity frames for an animation.
"""
function run_2d2(; N = 20, ubar = 0.05, T = 12.0, measure = 3.0,
                 frame_every = 0, frame_from = 0.0, verbose = true)
    c = cylinder(N = N, Re = 100, ubar = ubar, magic = 1/4)
    s = c.sim
    spt = 1 / (c.dx * c.ubar)           # steps per physical time (Ū = 1)
    nsteps = round(Int, T * spt)
    nmeas = round(Int, measure * spt)
    ramp = round(Int, 0.5 * spt)
    cds = Float64[]; cls = Float64[]
    frames = Matrix{UInt8}[]
    t0 = time()
    for n in 1:nsteps
        s.uscale = n < ramp ? sin(pi / 2 * n / ramp)^2 : 1.0
        step!(s)
        if n > nsteps - nmeas
            cd, cl = coefficients(c)
            push!(cds, cd); push!(cls, cl)
        end
        if frame_every > 0 && n % frame_every == 0 && n >= frame_from * spt
            push!(frames, field_indices(vorticity(s), s.solid, 40c.ubar * c.dx))
        end
        if verbose && n % round(Int, spt) == 0
            cd, cl = coefficients(c)
            @printf("    t = %5.2f  cD = %.4f  cL = %+.4f\n", n / spt, cd, cl)
        end
    end
    secs = time() - t0
    # period from upward zero crossings of the lift
    ups = Float64[]
    m = sum(cls) / length(cls)
    for k in 2:length(cls)
        a = cls[k-1] - m; b = cls[k] - m
        a < 0 <= b && push!(ups, k - 1 + a / (a - b))
    end
    St = if length(ups) >= 2
        period = (ups[end] - ups[1]) / (length(ups) - 1)  # in lattice steps
        c.N / (period * c.ubar)
    else
        NaN                                               # no shedding
    end
    (cDmax = maximum(cds), cLmax = maximum(cls), cLmin = minimum(cls),
     St = St, periods = max(length(ups) - 1, 0), steps = s.t, secs = secs,
     mlups = count(!, s.solid) * s.t / secs / 1e6, case = c, frames = frames,
     cd = cds, cl = cls)
end
