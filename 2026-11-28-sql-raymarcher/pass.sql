-- pass.sql: one generation of rays (camera rays for pass 0, reflections after).
-- Included by render.sql with :pass set.

\echo == pass :pass: sphere tracing
create temp table if not exists march_log (pass int, id int, t float8, n int, st int);
insert into march_log select :pass, * from trace(:pass);
analyze march_log;

\echo == pass :pass: normals and materials
insert into surf
select r.pass, r.id, m.t, m.n, mt.mat, p.px, p.py, p.pz,
       nn.nx / nn.l, nn.ny / nn.l, nn.nz / nn.l, r.dx, r.dy, r.dz
from march_log m join ray r on r.pass = :pass and r.id = m.id
     cross join lateral (select r.ox + m.t * r.dx as px, r.oy + m.t * r.dy as py,
                                r.oz + m.t * r.dz as pz) p
     -- tetrahedral central differences: 4 SDF samples instead of 6
     cross join lateral (select d from scene(p.px + 0.0008, p.py - 0.0008, p.pz - 0.0008) offset 0) a
     cross join lateral (select d from scene(p.px - 0.0008, p.py - 0.0008, p.pz + 0.0008) offset 0) b
     cross join lateral (select d from scene(p.px - 0.0008, p.py + 0.0008, p.pz - 0.0008) offset 0) c
     cross join lateral (select d from scene(p.px + 0.0008, p.py + 0.0008, p.pz + 0.0008) offset 0) d
     cross join lateral (select a.d - b.d - c.d + d.d as nx, -a.d - b.d + c.d + d.d as ny,
                                -a.d + b.d - c.d + d.d as nz offset 0) n0
     cross join lateral (select n0.nx, n0.ny, n0.nz,
                                greatest(sqrt(n0.nx^2 + n0.ny^2 + n0.nz^2), 1e-12) as l) nn
     cross join lateral material(p.px, p.py, p.pz) mt
where m.pass = :pass and m.st = 1;
analyze surf;

-- rays that escaped see the sky
insert into contrib
select :pass, r.id, r.wr * s.r, r.wg * s.g, r.wb * s.b
from march_log m join ray r on r.pass = :pass and r.id = m.id
     cross join lateral sky(r.dx, r.dy, r.dz) s
where m.pass = :pass and m.st = 2;

\echo == pass :pass: soft shadows
create temp table sh as select * from shadow(:pass);
analyze sh;

\echo == pass :pass: ambient occlusion, lighting, reflections
create temp table lit as
select s.id, s.t, s.mat, s.px, s.py, s.pz, s.nx, s.ny, s.nz, s.dx, s.dy, s.dz,
       r.wr, r.wg, r.wb, ao.ao, coalesce(sh.sha, 0) as sha, l.lx, l.ly, l.lz
from surf s join ray r using (pass, id) left join sh using (id) cross join sun() l
     -- five SDF probes along the normal estimate how enclosed the point is
     cross join lateral scene(s.px + 0.01 * s.nx, s.py + 0.01 * s.ny, s.pz + 0.01 * s.nz) o1
     cross join lateral scene(s.px + 0.04 * s.nx, s.py + 0.04 * s.ny, s.pz + 0.04 * s.nz) o2
     cross join lateral scene(s.px + 0.07 * s.nx, s.py + 0.07 * s.ny, s.pz + 0.07 * s.nz) o3
     cross join lateral scene(s.px + 0.10 * s.nx, s.py + 0.10 * s.ny, s.pz + 0.10 * s.nz) o4
     cross join lateral scene(s.px + 0.13 * s.nx, s.py + 0.13 * s.ny, s.pz + 0.13 * s.nz) o5
     cross join lateral (select greatest(0, least(1, 1 - 3 * (
                (0.01 - o1.d) + 0.95 * (0.04 - o2.d) + 0.9025 * (0.07 - o3.d)
              + 0.857375 * (0.10 - o4.d) + 0.814506 * (0.13 - o5.d)))) * (0.5 + 0.5 * s.ny) as ao) ao
where s.pass = :pass;
analyze lit;

create temp table shaded as
select id, px, py, pz, nx, ny, nz, dx, dy, dz, wr, wg, wb,
       -- light = sun + sky dome + warm bounce from the ground
       ar * (2.6 * dif * 1.00 + 0.45 * ao * 0.45 + 0.35 * bac * 0.55) + sp * 1.00 as lr,
       ag * (2.6 * dif * 0.92 + 0.45 * ao * 0.60 + 0.35 * bac * 0.42) + sp * 0.95 as lg,
       ab * (2.6 * dif * 0.80 + 0.45 * ao * 0.95 + 0.35 * bac * 0.30) + sp * 0.85 as lb,
       k * (1 - fo) as k, tr, tg, tb, fo
from (
  select l.*, f.*, m.*,
         greatest(l.nx * l.lx + l.ny * l.ly + l.nz * l.lz, 0) * l.sha as dif,
         greatest(-(l.nx * l.lx + l.nz * l.lz) / 0.880738, 0) * greatest(least(1 - l.py, 1), 0) * l.ao as bac,
         m.spec * power(greatest((l.nx * hx + l.ny * hy + l.nz * hz) / hl, 1e-3), m.shin)
           * l.sha * greatest(l.nx * l.lx + l.ny * l.ly + l.nz * l.lz, 0) * (0.3 + 0.7 * f.fres) as sp,
         1 - exp(-0.0016 * l.t * l.t) as fo
  from lit l
  cross join lateral (select power(greatest(least(1 + l.dx * l.nx + l.dy * l.ny + l.dz * l.nz, 1), 1e-6), 5) as fres,
                             l.lx - l.dx as hx, l.ly - l.dy as hy, l.lz - l.dz as hz) f
  cross join lateral (select sqrt(f.hx^2 + f.hy^2 + f.hz^2) as hl) hh
  cross join lateral (
    select * from (values
      -- mat, albedo rgb, reflectivity, reflection tint, specular, shininess
      (1, case when mod(floor(l.px)::int + floor(l.pz)::int, 2) = 0 then 0.36 else 0.04 end,
          case when mod(floor(l.px)::int + floor(l.pz)::int, 2) = 0 then 0.34 else 0.04 end,
          case when mod(floor(l.px)::int + floor(l.pz)::int, 2) = 0 then 0.31 else 0.05 end,
          0.03 + 0.45 * f.fres, 1.0, 1.0, 1.0, 0.3, 40.0),
      (2, 0.25, 0.15, 0.04, 0.65 + 0.35 * f.fres, 1.0, 0.74, 0.34, 1.2, 90.0),
      (3, 0.60, 0.06, 0.04, 0.04 + 0.40 * f.fres, 1.0, 1.0, 1.0, 0.7, 32.0),
      (4, 0.04, 0.36, 0.33, 0.04 + 0.40 * f.fres, 1.0, 1.0, 1.0, 0.6, 32.0),
      (5, 0.62, 0.60, 0.55, 0.0, 1.0, 1.0, 1.0, 0.15, 12.0)
    ) v(mat, ar, ag, ab, k, tr, tg, tb, spec, shin) where v.mat = l.mat) m
) x;

-- the fog colour matches the sky at the horizon
insert into contrib
select :pass, id,
       wr * (1 - kk) * (lr * (1 - fo) + 0.74 * fo),
       wg * (1 - kk) * (lg * (1 - fo) + 0.80 * fo),
       wb * (1 - kk) * (lb * (1 - fo) + 0.90 * fo)
from shaded, lateral (select case when :pass < :bounces then k else 0 end as kk) q;

-- reflective hits spawn the next generation of rays
insert into ray
select :pass + 1, id, px + 0.003 * nx, py + 0.003 * ny, pz + 0.003 * nz,
       dx - 2 * dn * nx, dy - 2 * dn * ny, dz - 2 * dn * nz,
       wr * k * tr, wg * k * tg, wb * k * tb
from shaded, lateral (select dx * nx + dy * ny + dz * nz as dn) q
where :pass < :bounces and k * greatest(wr, wg, wb) > 0.01;
analyze ray;

drop table sh, lit, shaded;
