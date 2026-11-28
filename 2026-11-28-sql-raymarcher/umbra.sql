-- umbra.sql: a ray marcher and PNG encoder written in plain SQL (PostgreSQL 14+).
--
-- There is no PL/pgSQL, no extension and no host language here. Everything is a
-- LANGUAGE sql function, a recursive CTE, a window function or an aggregate.
-- The scene functions are written so that the planner inlines them: in
-- EXPLAIN they disappear into plain arithmetic on the ray rows.
--
-- Load it with:  psql -f umbra.sql      (render.sql does this for you)

set client_min_messages = warning;
drop schema if exists umbra cascade;
create schema umbra;
set search_path = umbra, public;

------------------------------------------------------------------------------
-- 1. The scene, as a signed distance field
------------------------------------------------------------------------------
-- parts(p) returns the distance from p to every object at once. scene(p) is
-- their union, and material(p) picks the closest one. All three are
-- single-row set-returning SQL functions with FROM-less LATERAL chains, which
-- is the shape PostgreSQL can inline and flatten.

create function parts(x float8, y float8, z float8)
returns table(d_floor float8, d_blob float8, d_torus float8, d_box float8, d_col float8)
language sql immutable parallel safe rows 1 as $$
  select
    y,                                                   -- ground plane y = 0
    least(s1, s2) - greatest(0.35 - abs(s1 - s2), 0)^2 / 1.4,   -- smooth union, k = 0.35
    sqrt((sqrt((x + 2.3)^2 + (z - 0.4)^2) - 0.75)^2 + (y - 0.3)^2) - 0.3,
    sqrt(greatest(qx, 0)^2 + greatest(qy, 0)^2 + greatest(qz, 0)^2)
      + least(greatest(qx, qy, qz), 0) - 0.1,            -- rounded box
    least(greatest(cr, cv), 0) + sqrt(greatest(cr, 0)^2 + greatest(cv, 0)^2)  -- columns
  from
    (select sqrt(x^2 + (y - 1)^2 + z^2) - 1 as s1,                        -- big sphere
            sqrt((x - 1.05)^2 + (y - 0.55)^2 + (z - 0.75)^2) - 0.55 as s2  -- small sphere
    ) blob,
    -- box: translate to (2.5, 0.55, -0.6), rotate 35 degrees about y, fold to one octant
    lateral (select abs( 0.81915 * (x - 2.5) - 0.57358 * (z + 0.6)) - 0.35 as qx,
                    abs(y - 0.55) - 0.35 as qy,
                    abs( 0.57358 * (x - 2.5) + 0.81915 * (z + 0.6)) - 0.35 as qz) box,
    -- colonnade: one capped cylinder, repeated forever along x by domain folding
    lateral (select sqrt((x - 2.2 * round(x / 2.2))^2 + (z + 4.5)^2) - 0.28 as cr,
                    abs(y - 1.6) - 1.6 as cv) col
$$;

create function scene(x float8, y float8, z float8) returns table(d float8)
language sql immutable parallel safe rows 1 as $$
  select least(d_floor, d_blob, d_torus, d_box, d_col) from umbra.parts(x, y, z)
$$;

-- material id: 1 floor, 2 gold blob, 3 torus, 4 box, 5 columns
create function material(x float8, y float8, z float8) returns table(mat int)
language sql immutable parallel safe rows 1 as $$
  select case least(d_floor, d_blob, d_torus, d_box, d_col)
           when d_floor then 1 when d_blob then 2 when d_torus then 3
           when d_box then 4 else 5 end
  from (select * from umbra.parts(x, y, z) offset 0) p
$$;

-- direction towards the sun (normalised (-0.60, 0.42, 0.50)): a low, late-afternoon sun
create function sun() returns table(lx float8, ly float8, lz float8)
language sql immutable rows 1 as $$ select -0.676598, 0.473619, 0.563832 $$;

-- sky colour seen along direction d
create function sky(dx float8, dy float8, dz float8) returns table(r float8, g float8, b float8)
language sql immutable parallel safe rows 1 as $$
  select 0.80 + (0.22 - 0.80) * h + 1.00 * glow + 6.0 * disc,
         0.86 + (0.42 - 0.86) * h + 0.75 * glow + 5.4 * disc,
         0.96 + (0.86 - 0.96) * h + 0.45 * glow + 4.2 * disc
  from umbra.sun() l,
       lateral (select greatest(dx * l.lx + dy * l.ly + dz * l.lz, 0) as c,
                       power(least(greatest(dy, 0), 1), 0.55) as h) s,
       lateral (select 0.35 * c^8 as glow, case when c > 0.95 then power(c, 900) else 0 end as disc) g
$$;

------------------------------------------------------------------------------
-- 2. Lock-step sphere tracing
------------------------------------------------------------------------------
-- Every ray of a pass is one row. Each iteration of the recursive CTE advances
-- ALL live rays by one safe step, so a 960x540 image is marched as ~150
-- relational "wavefronts" rather than half a million separate loops.
--   st = 0 still marching, 1 hit a surface, 2 escaped / ran out of steps

create unlogged table ray (
  pass int, id int,
  ox float8, oy float8, oz float8,       -- origin
  dx float8, dy float8, dz float8,       -- unit direction
  wr float8, wg float8, wb float8,       -- how much this ray contributes to its pixel
  primary key (pass, id));

create function trace(p int, tmax float8 default 40, maxn int default 200, eps float8 default 0.0004)
returns table(id int, t float8, n int, st int)
language sql stable as $$
  with recursive m(id, ox, oy, oz, dx, dy, dz, t, n, st) as (
    select r.id, r.ox, r.oy, r.oz, r.dx, r.dy, r.dz, 0.0::float8, 0, 0
    from umbra.ray r where r.pass = p
    union all
    select m.id, m.ox, m.oy, m.oz, m.dx, m.dy, m.dz,
           case when s.d < eps * (1 + m.t) then m.t else m.t + s.d end,
           m.n + 1,
           case when s.d < eps * (1 + m.t) then 1
                when m.t + s.d > tmax or m.n + 1 >= maxn then 2
                else 0 end
    from m cross join lateral (
           -- OFFSET 0 is an optimisation fence: without it the planner pastes the
           -- whole inlined SDF expression into each of the four places s.d is used
           select d from umbra.scene(m.ox + m.t * m.dx, m.oy + m.t * m.dy, m.oz + m.t * m.dz) offset 0) s
    where m.st = 0
  )
  select id, t, n, st from m where st <> 0
$$;

-- Soft shadows (Inigo Quilez's penumbra estimate): march from each surface
-- point towards the sun and remember how narrowly the ray missed things.
create unlogged table surf (
  pass int, id int, t float8, steps int, mat int,
  px float8, py float8, pz float8,       -- hit point
  nx float8, ny float8, nz float8,       -- surface normal
  dx float8, dy float8, dz float8,       -- incoming direction
  primary key (pass, id));

create function shadow(p int, k float8 default 10, tmax float8 default 14, maxn int default 96)
returns table(id int, sha float8)
language sql stable as $$
  with recursive m(id, ox, oy, oz, t, res, n, st) as (
    select s.id, s.px + 0.004 * s.nx, s.py + 0.004 * s.ny, s.pz + 0.004 * s.nz,
           0.01::float8, 1.0::float8, 0, 0
    from umbra.surf s where s.pass = p
    union all
    select m.id, m.ox, m.oy, m.oz,
           m.t + least(greatest(h.d, 0.004), 0.5),
           least(m.res, k * h.d / m.t),
           m.n + 1,
           case when h.d < 0.0002 or m.res < 0.003 then 1
                when m.t > tmax or m.n + 1 >= maxn then 2 else 0 end
    from m, umbra.sun() l,
         lateral (select d from umbra.scene(m.ox + m.t * l.lx, m.oy + m.t * l.ly, m.oz + m.t * l.lz)
                  offset 0) h
    where m.st = 0
  )
  select id, case when st = 1 and res < 0.003 then 0
                  else greatest(least(res, 1), 0) end
  from m where st <> 0
$$;

------------------------------------------------------------------------------
-- 3. Tone mapping helper
------------------------------------------------------------------------------
-- ACES filmic curve (Narkowicz fit) then sRGB-ish gamma, to an 8-bit value.
create function to8(c float8) returns int
language sql immutable parallel safe as $$
  select least(255, greatest(0, round(255 * power(
           greatest(least((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14), 1), 0),
           1 / 2.2))))::int
$$;

------------------------------------------------------------------------------
-- 4. PNG encoder: CRC-32, Adler-32 and a DEFLATE compressor, set-based
------------------------------------------------------------------------------

-- the 256-entry CRC-32 table, built by an 8-round recursive CTE per entry
create function crc_table() returns bigint[]
language sql immutable as $$
  with recursive c(n, k, v) as (
    select n, 0, n::bigint from generate_series(0, 255) n
    union all
    select n, k + 1, case when v & 1 = 1 then 3988292384 # (v >> 1) else v >> 1 end
    from c where k < 8)
  select array_agg(v order by n) from c where k = 8
$$;

-- CRC-32 is inherently sequential, so it is a recursive CTE that carries the
-- 32-bit register from byte to byte (about 4 microseconds per byte).
create function crc32(data bytea) returns bigint
language sql immutable strict parallel safe as $$
  with recursive d as materialized (     -- detoast the input and build the table once
    select data || ''::bytea as d, length(data) as n, umbra.crc_table() as tab
  ), c(i, r) as (
    select 0, 4294967295::bigint
    union all
    select i + 1, tab[((r # get_byte(d, i)) & 255) + 1] # (r >> 8) from c, d where i < n
  )
  select r # 4294967295 from c, d where i = n
$$;

-- Adler-32 needs no loop at all:  A = 1 + sum(v),  B = n + sum((n - i) * v_i)
create function adler32(data bytea) returns bigint
language sql immutable strict parallel safe as $$
  with d as materialized (select data || ''::bytea as d, length(data) as n)
  select ((coalesce(sum((n - i)::bigint * get_byte(d, i)), 0) + n) % 65521) * 65536
         + (1 + coalesce(sum(get_byte(d, i)), 0)) % 65521
  from d left join lateral generate_series(0, n - 1) i on true
  group by n
$$;

create function be32(v bigint) returns bytea
language sql immutable strict parallel safe as $$ select substring(int8send(v) from 5) $$;

create function png_chunk(typ text, data bytea) returns bytea
language sql immutable strict parallel safe as $$
  select umbra.be32(length(data)) || convert_to(typ, 'UTF8') || data
         || umbra.be32(umbra.crc32(convert_to(typ, 'UTF8') || data))
$$;

-- The 288 fixed-Huffman literal/length codes (RFC 1951 3.2.6), stored
-- bit-reversed so that they can be emitted LSB-first like everything else.
create function fixed_lit() returns table(sym int, rcode bigint, nbits int)
language sql immutable as $$
  select s, (select coalesce(sum(((code >> k) & 1) << (len - 1 - k)), 0)::bigint
             from generate_series(0, len - 1) k), len
  from generate_series(0, 287) s,
       lateral (select case when s <= 143 then 48 + s       when s <= 255 then 400 + s - 144
                            when s <= 279 then s - 256      else 192 + s - 280 end as code,
                       case when s <= 143 then 8 when s <= 255 then 9
                            when s <= 279 then 7 else 8 end as len) c
$$;

-- match length 3..258 -> length symbol, number of extra bits, extra value
create function length_codes() returns table(len int, sym int, ebits int, eval int)
language sql immutable as $$
  select l, b.sym, b.ebits, l - b.base
  from generate_series(3, 258) l
  join (values (257,3,0),(258,4,0),(259,5,0),(260,6,0),(261,7,0),(262,8,0),(263,9,0),(264,10,0),
               (265,11,1),(266,13,1),(267,15,1),(268,17,1),(269,19,2),(270,23,2),(271,27,2),(272,31,2),
               (273,35,3),(274,43,3),(275,51,3),(276,59,3),(277,67,4),(278,83,4),(279,99,4),(280,115,4),
               (281,131,5),(282,163,5),(283,195,5),(284,227,5),(285,258,0)) b(sym, base, ebits)
    on l >= b.base and l < b.base + (1 << b.ebits) and (l < 258 or b.sym = 285)
$$;

-- deflate(raw): one fixed-Huffman block. The compressor
--   * finds every run of equal bytes with the "gaps and islands" trick,
--   * turns each run into a literal plus distance-1 back-references (<= 258),
--   * assigns bit offsets with a running sum, explodes tokens into single
--     bits and regroups them into bytes with GROUP BY offset / 8.
create function deflate(raw bytea) returns bytea
language sql immutable strict set jit = off as $$
  with d as materialized (select raw || ''::bytea as d
  ), lit as materialized (select * from umbra.fixed_lit()
  ), lc as materialized (select * from umbra.length_codes()
  ), b as materialized (
    select i, get_byte(d, i) as v from d, generate_series(0, length(d) - 1) i
  ), runs as (
    select min(i) as start, count(*)::int as len, v
    from (select i, v, i - row_number() over (partition by v order by i) as grp from b) t
    group by v, grp
  ), tok as (                                     -- (key1, key2) orders the token stream
    select -1 as k1, 0 as k2, 3::bigint as bits, 3 as n       -- BFINAL = 1, BTYPE = 01
    union all
    select r.start, 0, f.rcode, f.nbits                       -- first byte of every run
    from runs r join lit f on f.sym = r.v
    union all                                                 -- back-references, dist = 1
    select r.start, m.k, f.rcode | (lc.eval::bigint << f.nbits), f.nbits + lc.ebits + 5
    from runs r,
         lateral (select k, case when k <= (r.len - 1) / 258 then 258
                                 else (r.len - 1) % 258 end as ml
                  from generate_series(1, (r.len - 1) / 258 + 1) k) m
         join lc on lc.len = m.ml
         join lit f on f.sym = lc.sym
    union all                                                 -- a 1-2 byte tail: literals
    select r.start, 100000 + j, f.rcode, f.nbits
    from runs r
         cross join lateral generate_series(1, (r.len - 1) % 258) j
         join lit f on f.sym = r.v
    where (r.len - 1) % 258 between 1 and 2
    union all
    select 2147483647, 0, 0, 7                                -- end-of-block, symbol 256
  ), placed as (
    select bits, n, sum(n) over (order by k1, k2) - n as off from tok
  ), bytes as (
    select (off + k) / 8 as pos, sum(((bits >> k) & 1) << ((off + k) % 8)::int) as v
    from placed, lateral generate_series(0, n - 1) k
    group by 1
  )
  select decode(string_agg(lpad(to_hex(v::int), 2, '0'), '' order by pos), 'hex') from bytes
$$;

-- png_encode(w, h, rgb): 8-bit RGB pixels, row-major, no padding.
-- Each scanline gets the PNG filter (None/Sub/Up/Average/Paeth) with the
-- smallest sum of absolute signed residuals, the libpng heuristic.
create function png_encode(w int, h int, rgb bytea) returns bytea
language sql immutable strict set jit = off as $$
  with d as materialized (select rgb || ''::bytea as d
  ), px as materialized (   -- materialise, or every sort row would drag the whole bytea along
    select i / (3 * w) as y, i % (3 * w) as x, get_byte(d, i) as v
    from d, generate_series(0, 3 * w * h - 1) i
  ), nb as (                                       -- a = left, b = up, c = up-left
    select y, x, v, a, coalesce(lag(v) over u, 0) as b, coalesce(lag(a) over u, 0) as c
    from (select y, x, v, coalesce(lag(v, 3) over (partition by y order by x), 0) as a
          from px) t
    window u as (partition by x order by y)
  ), f as (
    select y, x, ft, fv from nb,
      lateral (select a + b - c as pp) p,
      lateral (values (0, v),
                      (1, (v - a) & 255),
                      (2, (v - b) & 255),
                      (3, (v - (a + b) / 2) & 255),
                      (4, (v - case when abs(pp - a) <= abs(pp - b) and abs(pp - a) <= abs(pp - c) then a
                                    when abs(pp - b) <= abs(pp - c) then b else c end) & 255)
              ) fl(ft, fv)
  ), pick as (
    select distinct on (y) y, ft from f
    group by y, ft order by y, sum(least(fv, 256 - fv)), ft
  ), stream as (
    select y * (3 * w + 1) as pos, ft as v from pick
    union all
    select f.y * (3 * w + 1) + 1 + f.x, f.fv from f join pick using (y, ft)
  ), raw as (
    select decode(string_agg(lpad(to_hex(v), 2, '0'), '' order by pos), 'hex') as r from stream
  )
  select '\x89504e470d0a1a0a'::bytea
         || umbra.png_chunk('IHDR', umbra.be32(w) || umbra.be32(h) || '\x0802000000'::bytea)
         || umbra.png_chunk('IDAT', '\x7801'::bytea || umbra.deflate(r) || umbra.be32(umbra.adler32(r)))
         || umbra.png_chunk('IEND', ''::bytea)
  from raw
$$;
