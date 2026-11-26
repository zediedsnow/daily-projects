"""
    Karman

A D2Q9 lattice-Boltzmann flow solver written from scratch in plain Julia
(no packages): two-relaxation-time collision, Bouzidi interpolated
bounce-back for curved walls, momentum-exchange forces, velocity and
pressure boundaries, and dependency-free PNG / animated-GIF writers.
"""
module Karman

using Printf

export Sim, step!, run!, macros!, vorticity, Link,
       BOUNCE, BOUZIDI, VELOCITY, PRESSURE,
       CX, CY, W, OPP

include("lattice.jl")
include("images.jl")
include("geometry.jl")
include("benchmark.jl")

end
