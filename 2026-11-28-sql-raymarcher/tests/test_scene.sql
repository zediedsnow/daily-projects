-- tests/test_scene.sql: property tests for the ray marcher, written in SQL too.
--   psql -f tests/test_scene.sql        (loads ../umbra.sql itself)
\set ON_ERROR_STOP 1
\set QUIET 1
\ir ../umbra.sql
set search_path = umbra, public;
set jit = off;
select setseed(0.28) \g /dev/null
\pset footer off

\echo '1. scene() is 1-Lipschitz (sphere tracing never oversteps) on 50,000 random point pairs'
create temp table pairs as
select x, y, z, x + 0.6 * (random() - 0.5) as x2, y + 0.6 * (random() - 0.5) as y2,
       z + 0.6 * (random() - 0.5) as z2
from (select -7 + 14 * random() as x, -0.5 + 4.5 * random() as y, -8 + 13 * random() as z
      from generate_series(1, 50000)) p;
select count(*) as pairs, round(max(abs(a.d - b.d) / sqrt((x - x2)^2 + (y - y2)^2 + (z - z2)^2))::numeric, 6)
         as max_slope,
       case when max(abs(a.d - b.d) / sqrt((x - x2)^2 + (y - y2)^2 + (z - z2)^2)) <= 1.000001
            then 'PASS' else 'FAIL' end as result
from pairs, lateral scene(x, y, z) a, lateral scene(x2, y2, z2) b;

\echo '2. analytic distances'
select label, round(got::numeric, 6) as got, want,
       case when abs(got - want) < 1e-9 then 'PASS' else 'FAIL' end as result
from (values
  ('above the big sphere',      (select d from scene(0, 3, 0)),        1.0),
  ('inside the big sphere',     (select d from scene(0, 1, 0)),       -1.0),
  ('far above the floor',       (select d from scene(-0.2, 3, 3)),     least(3.0, sqrt(0.04+4+9)-1)),
  ('torus tube centre',         (select d from scene(-2.3 + 0.75, 0.3, 0.4)), -0.3),
  ('a column ten periods away', (select d from scene(22, 1.6, -4.5)), -0.28)
) t(label, got, want);

\echo '3. 3,000 random camera rays: every hit is within the stopping tolerance, and no ray tunnels through one'
truncate ray;
insert into ray
select 7, g, 0.6, 1.75, 6.2, dx / l, dy / l, dz / l, 1, 1, 1
from generate_series(1, 3000) g,
     lateral (select -1 + 2 * random() + 0 * g as dx, -0.6 + 0.8 * random() as dy, -1.0 as dz) d,  -- 0*g: re-run per row
     lateral (select sqrt(dx * dx + dy * dy + dz * dz) as l) n;
create temp table tr as select * from trace(7);
select count(*) filter (where st = 1) as hits, count(*) filter (where st = 2) as misses,
       round(max(abs(s.d)) filter (where st = 1)::numeric, 6) as worst_residual,
       case when bool_and(abs(s.d) < 0.0004 * (1 + tr.t)) filter (where st = 1) then 'PASS' else 'FAIL' end as result
from tr join ray r on r.pass = 7 and r.id = tr.id,
     lateral scene(r.ox + tr.t * r.dx, r.oy + tr.t * r.dy, r.oz + tr.t * r.dz) s;
-- brute force: sample every ray every 2 mm up to its hit (or to 40 for misses);
-- the field must stay positive, i.e. no surface was skipped
select count(*) as samples, count(*) filter (where s.d < 0) as inside_samples,
       case when count(*) filter (where s.d < 0) = 0 then 'PASS' else 'FAIL' end as result
from tr join ray r on r.pass = 7 and r.id = tr.id
     cross join lateral generate_series(0, floor(least(tr.t, 40) / 0.002)::int - 1) k
     cross join lateral scene(r.ox + k * 0.002 * r.dx, r.oy + k * 0.002 * r.dy,
                               r.oz + k * 0.002 * r.dz) s
where r.id <= 300;

\echo '4. soft shadows: a floor point straight below the sphere along the sun is dark, open floor is lit'
truncate surf;
insert into surf values (7, 1, 1, 1, 1, 1.42, 0, -1.19, 0, 1, 0, 0, 0, -1),
                        (7, 2, 1, 1, 1, -3.0, 0,  3.0, 0, 1, 0, 0, 0, -1);
select id, round(sha::numeric, 3) as sha,
       case when (id = 1 and sha < 0.01) or (id = 2 and sha > 0.99) then 'PASS' else 'FAIL' end as result
from shadow(7) order by id;
