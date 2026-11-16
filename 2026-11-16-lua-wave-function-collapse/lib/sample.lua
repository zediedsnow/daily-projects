-- Loads a sample file: a small header of "key: value" lines and
-- "color <char> #rrggbb" declarations, a "---" separator, then the
-- bitmap itself drawn as ASCII art (one character per pixel).
local M = {}

local function hex(s)
  local r, g, b = s:match("^#?(%x%x)(%x%x)(%x%x)$")
  assert(r, "bad colour '" .. s .. "'")
  return { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) }
end

local function bool(v)
  return v == "true" or v == "yes" or v == "1"
end

function M.load(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("a")
  f:close()

  local s = {
    name = path:match("([^/\\]+)%.%w+$") or path,
    N = 3, symmetry = 8, periodic_input = true, periodic_output = true,
    ground = false, width = 48, height = 48,
    palette = {}, chars = {}, rows = {},
  }
  local index_of = {}
  local in_body = false
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    if in_body then
      if line:match("%S") then s.rows[#s.rows + 1] = line end
    elseif line:match("^%-%-%-") then
      in_body = true
    elseif line:match("^%s*#") or not line:match("%S") then
      -- comment / blank
    else
      local ch, col = line:match("^color%s+(%S)%s+(%S+)")
      if ch then
        s.palette[#s.palette + 1] = hex(col)
        s.chars[#s.chars + 1] = ch
        index_of[ch] = #s.palette
      else
        local k, v = line:match("^([%w%-]+)%s*:%s*(.-)%s*$")
        assert(k, "cannot parse header line: " .. line)
        if k == "name" then s.name = v
        elseif k == "N" then s.N = tonumber(v)
        elseif k == "symmetry" then s.symmetry = tonumber(v)
        elseif k == "periodic-input" then s.periodic_input = bool(v)
        elseif k == "periodic-output" then s.periodic_output = bool(v)
        elseif k == "ground" then s.ground = bool(v)
        elseif k == "size" then
          local w, h = v:match("(%d+)%s+(%d+)")
          s.width, s.height = tonumber(w), tonumber(h)
        else error("unknown header key: " .. k) end
      end
    end
  end
  assert(#s.rows > 0, path .. ": no bitmap after '---'")
  s.w, s.h = #s.rows[1], #s.rows
  s.pixels = {} -- 0-based flat: pixels[x + y*w] = colour index (1-based)
  for y, row in ipairs(s.rows) do
    assert(#row == s.w, ("%s: row %d has width %d, expected %d"):format(path, y, #row, s.w))
    for x = 1, #row do
      local c = index_of[row:sub(x, x)]
      assert(c, ("%s: undeclared colour '%s' at %d,%d"):format(path, row:sub(x, x), x, y))
      s.pixels[(x - 1) + (y - 1) * s.w] = c
    end
  end
  return s
end

return M
