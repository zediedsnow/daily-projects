#!/usr/bin/env lua5.4
-- Property tests: for every sample and many seeds, the output must
-- (a) only contain N x N windows that occur in the sample,
-- (b) be identical when re-run with the same seed,
-- and the propagator must be symmetric (A fits left of B <=> B fits right of A).
local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/lib/?.lua;" .. package.path
local Sample, WFC = require("sample"), require("wfc")

local OPP = { 3, 4, 1, 2 }
local seeds = tonumber(arg[1]) or 12
local failures, runs, windows, attempts = 0, 0, 0, 0

local function fingerprint(m)
  local t = {}
  for y = 0, m.MY - 1 do for x = 0, m.MX - 1 do t[#t + 1] = string.char(m:pixel(x, y)) end end
  return table.concat(t)
end

local t0 = os.clock()
for _, name in ipairs { "flowers", "islands", "dungeon", "maze" } do
  local s = Sample.load(here .. "/samples/" .. name .. ".txt")
  local m = WFC.new(s)

  local asym = 0
  for d = 1, 4 do
    for t = 1, m.T do
      for _, t2 in ipairs(m.prop[d][t]) do
        local back = false
        for _, u in ipairs(m.prop[OPP[d]][t2]) do if u == t then back = true; break end end
        if not back then asym = asym + 1 end
      end
    end
  end
  if asym > 0 then failures = failures + 1 end

  local ok_all = true
  for seed = 1, seeds do
    -- a grounded sample has a floor, so it cannot wrap vertically
    for _, periodic in ipairs(s.ground and { false } or { true, false }) do
      local opts = { width = 32, height = 24, periodic = periodic, seed = seed, tries = 100 }
      assert(m:run(opts), name .. ": no solution in 100 attempts")
      attempts = attempts + m.attempts
      local ok, n = m:validate()
      local fp = fingerprint(m)
      assert(m:run(opts))
      local same = fingerprint(m) == fp
      runs, windows = runs + 1, windows + n
      if not (ok and same) then
        ok_all = false; failures = failures + 1
        print(("  FAIL %s seed=%d periodic=%s valid=%s deterministic=%s"):format(
          name, seed, tostring(periodic), tostring(ok), tostring(same)))
      end
    end
  end
  print(("%-8s %4d patterns  propagator %s  %d seeds x %-18s %s"):format(
    name, m.T, asym == 0 and "symmetric" or ("ASYMMETRIC(" .. asym .. ")"), seeds,
    s.ground and "{bounded}:" or "{periodic, bounded}:", ok_all and "ok" or "FAIL"))
end
print(("%d generations, %d windows checked, %d contradiction restart(s), %.1fs"):format(
  runs, windows, attempts - runs, os.clock() - t0))
print(failures == 0 and "ALL TESTS PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
