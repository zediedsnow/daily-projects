# ---------------------------------------------------------------------------
# Geometry: turn a description of walls / inlet / outlet / circular obstacles
# into a solid mask plus a list of boundary links.
#
# Index space: node (x, y) sits at continuous position (x, y). The channel
# walls are half-way between nodes, at y = 1/2 and y = ny + 1/2; the inlet
# is at x = 1/2 and the outlet at x = nx + 1/2.
# ---------------------------------------------------------------------------

struct Circle
    cx::Float64
    cy::Float64
    r::Float64
end

inside(c::Circle, x, y) = (x - c.cx)^2 + (y - c.cy)^2 < c.r^2

"""
Fraction q ∈ (0, 1] of the link from fluid node p toward p + d at which it
first meets the circle.
"""
function wall_fraction(c::Circle, px, py, dx, dy)
    ox = px - c.cx; oy = py - c.cy
    a = dx * dx + dy * dy
    b = 2(ox * dx + oy * dy)
    cc = ox * ox + oy * oy - c.r^2
    disc = b * b - 4a * cc
    disc < 0 && error("link does not cut the circle")
    t = (-b - sqrt(disc)) / (2a)
    clamp(t, 1e-9, 1.0)
end

"""
    channel(nx, ny; inflow, circles, walls = true, outlet_rho = 1.0)

A channel with no-slip walls at top/bottom, a velocity inlet with profile
`inflow(yw)` (yw = continuous wall-crossing height), an anti-bounce-back
pressure outlet, and circular obstacles handled with Bouzidi links.
Returns `(solid, links)`.
"""
function channel(nx, ny; inflow, circles = Circle[], walls = true,
                 outlet_rho = 1.0)
    solid = falses(nx, ny)
    for y in 1:ny, x in 1:nx, c in circles
        inside(c, x, y) && (solid[x, y] = true)
    end
    links = Link[]
    for y in 1:ny, x in 1:nx
        solid[x, y] && continue
        for i in 2:9
            sx = x - CX[i]; sy = y - CY[i]
            if walls && (sy < 1 || sy > ny)
                push!(links, Link(x, y, i, BOUNCE))
            elseif sx < 1
                yw = y - CY[i] / 2
                push!(links, Link(x, y, i, VELOCITY; ux = inflow(yw)))
            elseif sx > nx
                push!(links, Link(x, y, i, PRESSURE; ux = outlet_rho,
                                  xp = x - 1, yp = y))
            elseif solid[sx, sy]
                c = circles[findfirst(c -> inside(c, sx, sy), circles)]
                q = wall_fraction(c, x, y, -CX[i], -CY[i])
                fx = x + CX[i]; fy = y + CY[i]
                ok = 1 <= fx <= nx && 1 <= fy <= ny && !solid[fx, fy]
                push!(links, Link(x, y, i, BOUZIDI; q = q,
                                  xf = ok ? fx : 0, yf = ok ? fy : 0,
                                  body = true))
            end
        end
    end
    solid, links
end
