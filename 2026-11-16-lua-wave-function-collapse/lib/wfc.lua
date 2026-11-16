-- Wave Function Collapse, overlapping model.
--
-- 1. Slide an N x N window over the sample (optionally with its 8
--    rotations/reflections) and count every distinct pattern.
-- 2. Two patterns may sit next to each other at offset (dx, dy) iff
--    their overlapping (N - |dx|) x (N - |dy|) regions are identical.
--    Precompute that relation once: the "propagator".
-- 3. The output starts as a "wave": every cell may still be any pattern.
--    Repeatedly pick the cell with the lowest Shannon entropy, collapse
--    it to one pattern (weighted by frequency), and propagate: any
--    pattern that lost its last supporter in some direction is banned,
--    which may starve its neighbours in turn (AC-4 style counting).
-- 4. Stop when every cell is decided (success) or a cell has no
--    options left (contradiction -> restart with a new seed).
local Rng = require("rng")

local M = {}
M.__index = M

local DX = { -1, 0, 1, 0 }
local DY = { 0, 1, 0, -1 }
local OPP = { 3, 4, 1, 2 }

local function key_of(p)
  return string.char(table.unpack(p))
end

-- build the model from a loaded sample
function M.new(s)
  local N, W, H = s.N, s.w, s.h
  local self = setmetatable({ N = N, sample = s, palette = s.palette }, M)

  local function rotate(p)
    local q = {}
    for y = 0, N - 1 do for x = 0, N - 1 do q[1 + x + y * N] = p[1 + (N - 1 - y) + x * N] end end
    return q
  end
  local function reflect(p)
    local q = {}
    for y = 0, N - 1 do for x = 0, N - 1 do q[1 + x + y * N] = p[1 + (N - 1 - x) + y * N] end end
    return q
  end

  local patterns, weights, index = {}, {}, {}
  local function add(p)
    local k = key_of(p)
    local t = index[k]
    if t then
      weights[t] = weights[t] + 1
    else
      patterns[#patterns + 1] = p
      weights[#patterns] = 1
      index[k] = #patterns
    end
  end

  local xmax = s.periodic_input and W or W - N + 1
  local ymax = s.periodic_input and H or H - N + 1
  for y = 0, ymax - 1 do
    for x = 0, xmax - 1 do
      local p = {}
      for dy = 0, N - 1 do
        for dx = 0, N - 1 do
          p[1 + dx + dy * N] = s.pixels[(x + dx) % W + ((y + dy) % H) * W]
        end
      end
      local ps = { p }
      ps[2] = reflect(ps[1]); ps[3] = rotate(ps[1]); ps[4] = reflect(ps[3])
      ps[5] = rotate(ps[3]); ps[6] = reflect(ps[5]); ps[7] = rotate(ps[5]); ps[8] = reflect(ps[7])
      for k = 1, s.symmetry do add(ps[k]) end
    end
  end

  if s.ground then
    -- the bottom-left N x N window of the sample is the "ground" pattern
    local p = {}
    for dy = 0, N - 1 do
      for dx = 0, N - 1 do p[1 + dx + dy * N] = s.pixels[dx + (H - N + dy) * W] end
    end
    self.groundPattern = assert(index[key_of(p)], "ground pattern missing")
  end

  local T = #patterns
  self.T, self.patterns, self.weights, self.index = T, patterns, weights, index
  self.logw = {}
  for t = 1, T do self.logw[t] = weights[t] * math.log(weights[t]) end

  local function agrees(p1, p2, dx, dy)
    local xmin, xmax2 = dx < 0 and 0 or dx, dx < 0 and dx + N or N
    local ymin, ymax2 = dy < 0 and 0 or dy, dy < 0 and dy + N or N
    for y = ymin, ymax2 - 1 do
      for x = xmin, xmax2 - 1 do
        if p1[1 + x + N * y] ~= p2[1 + x - dx + N * (y - dy)] then return false end
      end
    end
    return true
  end

  local prop = {}
  for d = 1, 4 do
    prop[d] = {}
    for t = 1, T do
      local list = {}
      for t2 = 1, T do
        if agrees(patterns[t], patterns[t2], DX[d], DY[d]) then list[#list + 1] = t2 end
      end
      prop[d][t] = list
    end
  end
  self.prop = prop
  return self
end

-- Run one attempt. Returns true on success, false on contradiction.
-- opts: width, height, periodic, seed, on_step(model, decided)
function M:attempt(opts)
  local N, T, prop, weights, logw = self.N, self.T, self.prop, self.weights, self.logw
  local MX, MY, periodic = opts.width, opts.height, opts.periodic
  local rng = Rng.new(opts.seed)
  local cells = MX * MY
  self.MX, self.MY, self.periodic = MX, MY, periodic

  local pal, pats = self.palette, self.patterns
  -- colour (r,g,b) of each pattern's top-left pixel, pre-weighted
  local cr, cg, cb = {}, {}, {}
  for t = 1, T do
    local c = pal[pats[t][1]]
    cr[t], cg[t], cb[t] = c[1] * weights[t], c[2] * weights[t], c[3] * weights[t]
  end

  local wave = {}          -- wave[i*T + t]
  local compat = {}        -- compat[(i*T + t - 1)*4 + d]
  local ones, sw, swl, ent = {}, {}, {}, {}
  local sr, sg, sb = {}, {}, {}
  local sumw, sumwl = 0, 0
  local r0, g0, b0 = 0, 0, 0
  for t = 1, T do
    sumw = sumw + weights[t]; sumwl = sumwl + logw[t]
    r0, g0, b0 = r0 + cr[t], g0 + cg[t], b0 + cb[t]
  end
  local ent0 = math.log(sumw) - sumwl / sumw
  local initc = {}
  for t = 1, T do
    initc[t] = { #prop[OPP[1]][t], #prop[OPP[2]][t], #prop[OPP[3]][t], #prop[OPP[4]][t] }
  end
  for i = 0, cells - 1 do
    local base = i * T
    for t = 1, T do
      wave[base + t] = true
      local c, ic = (base + t - 1) * 4, initc[t]
      compat[c + 1], compat[c + 2], compat[c + 3], compat[c + 4] = ic[1], ic[2], ic[3], ic[4]
    end
    ones[i], sw[i], swl[i], ent[i] = T, sumw, sumwl, ent0
    sr[i], sg[i], sb[i] = r0, g0, b0
  end
  self.wave, self.ones, self.sw, self.sr, self.sg, self.sb = wave, ones, sw, sr, sg, sb
  self.decided_cache = {}

  local stack_i, stack_t, sp = {}, {}, 0

  local function ban(i, t)
    local base = i * T
    wave[base + t] = false
    local c = (base + t - 1) * 4
    compat[c + 1], compat[c + 2], compat[c + 3], compat[c + 4] = 0, 0, 0, 0
    sp = sp + 1; stack_i[sp] = i; stack_t[sp] = t
    ones[i] = ones[i] - 1
    local w = sw[i] - weights[t]
    sw[i] = w
    swl[i] = swl[i] - logw[t]
    ent[i] = w > 0 and (math.log(w) - swl[i] / w) or 0
    sr[i], sg[i], sb[i] = sr[i] - cr[t], sg[i] - cg[t], sb[i] - cb[t]
  end

  local function propagate()
    while sp > 0 do
      local i1, t1 = stack_i[sp], stack_t[sp]
      sp = sp - 1
      local x1, y1 = i1 % MX, i1 // MX
      for d = 1, 4 do
        local x2, y2 = x1 + DX[d], y1 + DY[d]
        local ok = true
        if periodic then
          x2, y2 = x2 % MX, y2 % MY
        elseif x2 < 0 or y2 < 0 or x2 + N > MX or y2 + N > MY then
          ok = false
        end
        if ok then
          local i2 = x2 + y2 * MX
          local list = prop[d][t1]
          local base = i2 * T - 1
          for k = 1, #list do
            local t2 = list[k]
            local idx = (base + t2) * 4 + d
            local c = compat[idx] - 1
            compat[idx] = c
            if c == 0 then ban(i2, t2) end
          end
        end
      end
    end
  end

  -- cells whose N x N window would stick out of a bounded output are
  -- never observed; their pixels come from the cells above/left
  local live, nlive = {}, 0
  for i = 0, cells - 1 do
    local x, y = i % MX, i // MX
    if periodic or (x + N <= MX and y + N <= MY) then nlive = nlive + 1; live[nlive] = i end
  end
  local function boundary(i)
    if periodic then return false end
    local x, y = i % MX, i // MX
    return x + N > MX or y + N > MY
  end

  if self.groundPattern then
    local g = self.groundPattern
    local gy = periodic and MY - 1 or MY - N
    local xs = periodic and MX or MX - N + 1
    for x = 0, xs - 1 do
      for t = 1, T do
        if t ~= g then ban(x + gy * MX, t) end
      end
      for y = 0, gy - 1 do ban(x + y * MX, g) end
    end
    propagate()
  end

  local decided = 0
  local on_step, step_every = opts.on_step, opts.step_every or 1
  while true do
    -- find the undecided cell with minimum entropy (tiny noise breaks ties)
    local best, min = -1, math.huge
    for k = 1, nlive do
      local i = live[k]
      local o = ones[i]
      if o > 1 then
        local e = ent[i]
        if e <= min then
          local noisy = e + 1e-6 * rng:float()
          if noisy < min then min, best = noisy, i end
        end
      elseif o == 0 then
        self.contradiction = i
        return false
      end
    end
    if best < 0 then break end

    -- collapse it: choose one surviving pattern by weight
    local base = best * T
    local r = rng:float() * sw[best]
    local chosen
    for t = 1, T do
      if wave[base + t] then
        r = r - weights[t]
        chosen = t
        if r <= 0 then break end
      end
    end
    for t = 1, T do
      if t ~= chosen and wave[base + t] then ban(best, t) end
    end
    propagate()
    decided = decided + 1
    if on_step and decided % step_every == 0 then on_step(self, decided) end
  end

  -- read the result off
  local observed = {}
  for i = 0, cells - 1 do
    if not boundary(i) then
      local base = i * T
      for t = 1, T do
        if wave[base + t] then observed[i] = t; break end
      end
    end
  end
  self.observed = observed
  return true
end

-- Try seeds seed, seed+1, ... until one succeeds.
function M:run(opts)
  local tries = opts.tries or 50
  local seed = opts.seed or 1
  for a = 1, tries do
    local o = setmetatable({ seed = seed + (a - 1) * 7919 }, { __index = opts })
    if opts.on_attempt then opts.on_attempt(a) end
    if self:attempt(o) then
      self.attempts, self.used_seed = a, o.seed
      return true
    end
  end
  return false
end

-- colour index of output pixel (x, y) after a successful run
function M:pixel(x, y)
  local N, MX, MY = self.N, self.MX, self.MY
  local dx, dy = 0, 0
  if not self.periodic then
    if x >= MX - N + 1 then dx = x - (MX - N) end
    if y >= MY - N + 1 then dy = y - (MY - N) end
  end
  local t = self.observed[(x - dx) + (y - dy) * MX]
  return self.patterns[t][1 + dx + dy * N]
end

-- partial-state colour of cell i (average over surviving patterns)
function M:blend(x, y)
  local N, MX, MY = self.N, self.MX, self.MY
  local ox, oy = 0, 0
  if not self.periodic then
    -- boundary pixels are drawn from the last real cell's pattern
    if x > MX - N then ox = x - (MX - N); x = MX - N end
    if y > MY - N then oy = y - (MY - N); y = MY - N end
  end
  local i = x + y * MX
  local w = self.sw[i]
  if w <= 0 then return 255, 0, 255, false end
  if self.ones[i] == 1 then
    -- decided: show the exact pixel (cached, a cell never un-decides)
    local cache = self.decided_cache
    local t = cache[i]
    if not t then
      local base, T = i * self.T, self.T
      for k = 1, T do if self.wave[base + k] then t = k; break end end
      cache[i] = t
    end
    local c = self.palette[self.patterns[t][1 + ox + oy * N]]
    return c[1], c[2], c[3], true
  end
  return self.sr[i] / w, self.sg[i] / w, self.sb[i] / w, false
end

-- Verify the result: every N x N window of the output must be a pattern
-- that occurs in the sample. Returns ok, number_of_windows_checked.
function M:validate()
  local N, MX, MY = self.N, self.MX, self.MY
  local xs = self.periodic and MX or MX - N + 1
  local ys = self.periodic and MY or MY - N + 1
  local checked = 0
  for y = 0, ys - 1 do
    for x = 0, xs - 1 do
      local p = {}
      for dy = 0, N - 1 do
        for dx = 0, N - 1 do
          p[1 + dx + dy * N] = self:pixel((x + dx) % MX, (y + dy) % MY)
        end
      end
      if not self.index[key_of(p)] then return false, checked, x, y end
      checked = checked + 1
    end
  end
  return true, checked
end

return M
