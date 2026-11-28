-- render.sql: renders the umbra scene to a PNG, entirely inside PostgreSQL.
--
--   psql -f render.sql                                  # 960x540 -> umbra.png
--   psql -v w=480 -v h=270 -v out=small.png -f render.sql
--   psql -v bounces=0 -f render.sql                     # no reflections
--
-- The only thing that leaves the database is the finished PNG, which psql
-- pipes through `base64 -d` into the output file.

\set ON_ERROR_STOP 1
\if :{?w}       \else \set w 960        \endif
\if :{?h}       \else \set h 540        \endif
\if :{?out}     \else \set out umbra.png \endif
\if :{?bounces} \else \set bounces 2    \endif
\set QUIET 1
\ir umbra.sql
set search_path = umbra, public;
set jit = off;              -- JIT compile time dwarfs any gain for these plans
set work_mem = '1GB';
\pset footer off
\timing on

\echo == camera rays (:w x :h)
create temp table contrib (pass int, id int, r float8, g float8, b float8);
-- look-at camera at (0.6, 1.75, 6.2) aimed at (0.1, 0.75, 0), focal length 2.2
insert into ray
select 0, j * :w + i, c.ox, c.oy, c.oz, d.dx / d.l, d.dy / d.l, d.dz / d.l, 1, 1, 1
from generate_series(0, :h - 1) j, generate_series(0, :w - 1) i,
     lateral (select 0.6::float8 as ox, 1.75::float8 as oy, 6.2::float8 as oz,
                     (2 * (i + 0.5) - :w) / :h::float8 as u,
                     (:h - 2 * (j + 0.5)) / :h::float8 as v) c,
     -- forward = (-0.0794, -0.1587, -0.9841), right = (0.9968, 0, -0.0804), up = cross
     lateral (select 0.996772 * c.u - 0.012759 * c.v - 0.079365 * 2.2 as dx,
                                      0.987326 * c.v - 0.158730 * 2.2 as dy,
                    -0.080385 * c.u - 0.158204 * c.v - 0.984127 * 2.2 as dz) d0,
     lateral (select d0.dx, d0.dy, d0.dz, sqrt(d0.dx^2 + d0.dy^2 + d0.dz^2) as l) d;
analyze ray;

-- psql has no loops, so the generations are unrolled (up to 2 bounces)
select :bounces > 0 as bounce1, :bounces > 1 as bounce2 \gset
\set pass 0
\ir pass.sql
\if :bounce1
  \set pass 1
  \ir pass.sql
\endif
\if :bounce2
  \set pass 2
  \ir pass.sql
\endif

\echo == compose, tone-map and encode PNG
create temp table img as
select id, to8(sum(r)) as r, to8(sum(g)) as g, to8(sum(b)) as b
from contrib group by id;

create temp table png as
select png_encode(:w, :h, decode(string_agg(lpad(to_hex(r), 2, '0') || lpad(to_hex(g), 2, '0')
                                             || lpad(to_hex(b), 2, '0'), '' order by id), 'hex')) as png
from img;

-- psql cannot write raw bytes, so the PNG leaves as base64 and is decoded on the way out
\pset format unaligned
\pset tuples_only on
\set pipe '| base64 -d > ' :out
\o :pipe
select translate(encode(png, 'base64'), E'\n', '') from png;
\o
\pset format aligned
\pset tuples_only off

\echo == statistics
select s.pass, count(*) filter (where s.st = 1) as hits, count(*) filter (where s.st = 2) as misses,
       max(s.n) as wavefronts, sum(s.n) as sdf_steps
from march_log s group by s.pass order by s.pass;
select length(png) as png_bytes, 3 * :w * :h as raw_bytes,
       round(100.0 * length(png) / (3 * :w * :h), 1) as pct from png;
\echo wrote :out
