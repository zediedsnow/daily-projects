#!/usr/bin/env lua5.4
-- loom: Wave Function Collapse texture synthesis in pure Lua 5.4.
local here = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = here .. "/lib/?.lua;" .. package.path

local Sample = require("sample")
local WFC = require("wfc")
local png = require("png")
local gif = require("gif")
local font = require("font")

local USAGE = [[
usage: lua loom.lua <sample.txt> [options]
       lua loom.lua --gallery [file.png] [--seed N]

options:
  --size WxH      output size in pixels (default: from the sample header)
  --seed N        random seed (default 1)
  --out FILE      write the result as PNG (default: <name>.png)
  --scale K       pixel scale for PNG/GIF output (default 6)
  --gif FILE      also write an animated GIF of the collapse
  --frames N      approximate number of GIF frames (default 80)
  --periodic B    override periodic-output (true/false)
  --term          print the result to the terminal in 24-bit colour
  --quiet         no progress output
]]

local function parse(argv)
  local o = { seed = 1, scale = 6, frames = 80 }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local function val() i = i + 1; return (assert(argv[i], a .. " needs a value")) end
    if a == "--size" then
      local w, h = val():match("^(%d+)[xX](%d+)$")
      o.width, o.height = assert(tonumber(w), "bad --size"), tonumber(h)
    elseif a == "--seed" then o.seed = assert(math.tointeger(tonumber(val())), "bad --seed")
    elseif a == "--out" then o.out = val()
    elseif a == "--scale" then o.scale = assert(tonumber(val()))
    elseif a == "--gif" then o.gif = val()
    elseif a == "--frames" then o.frames = assert(tonumber(val()))
    elseif a == "--periodic" then o.periodic = val() == "true"
    elseif a == "--term" then o.term = true
    elseif a == "--quiet" then o.quiet = true
    elseif a == "--gallery" then
      o.gallery = (argv[i + 1] and not argv[i + 1]:match("^%-%-")) and val() or "gallery.png"
    elseif a == "-h" or a == "--help" then io.write(USAGE); os.exit(0)
    elseif a:match("^%-") then error("unknown option " .. a)
    else o.sample = a end
    i = i + 1
  end
  return o
end

local function log(o, ...) if not o.quiet then io.stderr:write(string.format(...)) end end

-- Build model + run; returns the model (solved) and stats.
local function solve(sample, o, hooks)
  local t0 = os.clock()
  local model = WFC.new(sample)
  local t1 = os.clock()
  local periodic = sample.periodic_output
  if o.periodic ~= nil then periodic = o.periodic end
  if sample.ground then periodic = false end -- a floor cannot wrap
  local ok = model:run {
    width = o.width or sample.width, height = o.height or sample.height,
    periodic = periodic, seed = o.seed, tries = 100,
    on_step = hooks and hooks.on_step, step_every = hooks and hooks.step_every,
    on_attempt = hooks and hooks.on_attempt,
  }
  local t2 = os.clock()
  if not ok then error("gave up after 100 contradictions") end
  local nonzero = 0
  for d = 1, 4 do for t = 1, model.T do nonzero = nonzero + #model.prop[d][t] end end
  return model, {
    patterns = model.T, build = t1 - t0, solve = t2 - t1,
    attempts = model.attempts, density = nonzero / (4 * model.T * model.T),
  }
end

local function term_print(model)
  local pal = model.palette
  local out = {}
  for y = 0, model.MY - 1, 2 do
    for x = 0, model.MX - 1 do
      local a = pal[model:pixel(x, y)]
      local b = y + 1 < model.MY and pal[model:pixel(x, y + 1)] or { 0, 0, 0 }
      out[#out + 1] = ("\27[38;2;%d;%d;%dm\27[48;2;%d;%d;%dm▀"):format(a[1], a[2], a[3], b[1], b[2], b[3])
    end
    out[#out + 1] = "\27[0m\n"
  end
  io.write(table.concat(out))
end

local function write_png(model, path, scale)
  local pal = model.palette
  png.write(path, model.MX * scale, model.MY * scale, function(x, y)
    local c = pal[model:pixel(x // scale, y // scale)]
    return c[1], c[2], c[3]
  end)
end

-- GIF palette: 6x6x6 colour cube for blended states + exact sample colours
local function gif_palette(pal)
  local p, exact = {}, {}
  for r = 0, 5 do for g = 0, 5 do for b = 0, 5 do
    p[#p + 1] = { r * 51, g * 51, b * 51 }
  end end end
  for i, c in ipairs(pal) do
    p[216 + i] = c
    exact[(c[1] << 16) | (c[2] << 8) | c[3]] = 215 + i
  end
  return p, exact
end

local function capture(model, scale, exact)
  local MX, MY = model.MX, model.MY
  local cell = {}
  for y = 0, MY - 1 do
    for x = 0, MX - 1 do
      local r, g, b, done = model:blend(x, y)
      local idx
      if done then
        idx = exact[(r << 16) | (g << 8) | b]
      else
        idx = math.floor(r / 51 + 0.5) * 36 + math.floor(g / 51 + 0.5) * 6 + math.floor(b / 51 + 0.5)
      end
      cell[x + y * MX] = idx
    end
  end
  local W = MX * scale
  local px = {}
  for y = 0, MY * scale - 1 do
    local row = (y // scale) * MX
    for x = 0, W - 1 do px[1 + x + y * W] = cell[row + x // scale] end
  end
  return px
end

local function generate(o)
  local sample = Sample.load(o.sample)
  local frames, exact, gpal, scale = {}, nil, nil, math.max(1, o.gif and math.min(o.scale, 4) or o.scale)
  local hooks
  if o.gif then
    gpal, exact = gif_palette(sample.palette)
    local cells = (o.width or sample.width) * (o.height or sample.height)
    hooks = {
      step_every = math.max(1, cells // (o.frames * 4)),
      on_attempt = function(a)
        frames = {}
        if a > 1 then log(o, "  contradiction, restarting (attempt %d)\n", a) end
      end,
      on_step = function(m) frames[#frames + 1] = { indices = capture(m, scale, exact), delay = 5 } end,
    }
  end
  local model, st = solve(sample, o, hooks)
  local ok, windows = model:validate()
  log(o, "%s: %d patterns (N=%d, symmetry=%d), propagator density %.1f%%\n",
    sample.name, st.patterns, sample.N, sample.symmetry, st.density * 100)
  log(o, "  %dx%d %s output, seed %d, %d attempt(s)\n", model.MX, model.MY,
    model.periodic and "periodic" or "bounded", model.used_seed, st.attempts)
  log(o, "  model %.2fs, solve %.2fs; %d/%d windows found in sample: %s\n",
    st.build, st.solve, ok and windows or windows, windows, ok and "VALID" or "INVALID")
  assert(ok, "output contains a window that does not occur in the sample")

  if o.term then term_print(model) end
  local out = o.out or (sample.name:lower() .. ".png")
  write_png(model, out, o.scale)
  log(o, "  wrote %s\n", out)
  if o.gif then
    local keep = {}
    local stride = math.max(1, #frames // o.frames)
    for i = 1, #frames, stride do keep[#keep + 1] = frames[i] end
    keep[#keep + 1] = { indices = capture(model, scale, exact), delay = 300 }
    local f = assert(io.open(o.gif, "wb"))
    f:write(gif.encode(model.MX * scale, model.MY * scale, gpal, keep))
    f:close()
    log(o, "  wrote %s (%d frames)\n", o.gif, #keep)
  end
end

-- One row per sample: the input bitmap, then three generated outputs.
local function gallery(o)
  local files = {}
  for _, n in ipairs { "flowers", "islands", "dungeon", "maze" } do
    files[#files + 1] = here .. "/samples/" .. n .. ".txt"
  end
  local BG, FG = { 24, 24, 32 }, { 230, 230, 240 }
  local rows, W, H = {}, 0, 16
  local PAD, S, LS = 16, 3, 2 -- padding, output scale, label scale
  for _, path in ipairs(files) do
    local s = Sample.load(path)
    local ow, oh = 64, s.ground and 40 or 64
    local outs = {}
    for k = 1, 3 do
      local m, st = solve(s, { seed = o.seed + k * 101, width = ow, height = oh })
      assert(m:validate())
      outs[k] = m
      log(o, "%s #%d: %d patterns, %.2fs, %d attempt(s)\n", s.name, k, st.patterns, st.solve, st.attempts)
    end
    local inscale = math.max(1, (oh * S) // s.h)
    local row = { s = s, outs = outs, y = H, inscale = inscale,
      label = ("%s  N%d  SYMx%d  %d PATTERNS"):format(s.name:upper(), s.N, s.symmetry, outs[1].T) }
    local width = PAD + s.w * inscale + PAD * 2 + 3 * (ow * S + PAD)
    W = math.max(W, width)
    row.h = 5 * LS + 8 + oh * S
    H = H + row.h + PAD * 2
    rows[#rows + 1] = row
  end
  local img = {}
  local function set(x, y, c) img[x + y * W] = c end
  for _, row in ipairs(rows) do
    font.draw(row.label, PAD, row.y, LS, function(x, y) set(x, y, FG) end)
    local y0 = row.y + 5 * LS + 8
    local s = row.s
    for y = 0, s.h * row.inscale - 1 do
      for x = 0, s.w * row.inscale - 1 do
        set(PAD + x, y0 + y, s.palette[s.pixels[x // row.inscale + (y // row.inscale) * s.w]])
      end
    end
    local x0 = PAD + s.w * row.inscale + PAD * 2
    -- arrow
    local ax, ay = x0 - PAD * 2 + 9, y0 + (row.h - 5 * LS - 8) // 2
    for dx = 0, 7 do
      for dy = -(7 - dx), 7 - dx do set(ax + dx, ay + dy, FG) end
    end
    for _, m in ipairs(row.outs) do
      for y = 0, m.MY * S - 1 do
        for x = 0, m.MX * S - 1 do
          set(x0 + x, y0 + y, m.palette[m:pixel(x // S, y // S)])
        end
      end
      x0 = x0 + m.MX * S + PAD
    end
  end
  png.write(o.gallery, W, H, function(x, y)
    local c = img[x + y * W] or BG
    return c[1], c[2], c[3]
  end)
  log(o, "wrote %s (%dx%d)\n", o.gallery, W, H)
end

local o = parse(arg)
if o.gallery then gallery(o)
elseif o.sample then generate(o)
else io.write(USAGE); os.exit(1) end
