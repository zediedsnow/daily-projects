-- Animated GIF89a encoder: global 256-colour palette, variable-width
-- LZW (9..12 bit codes, clear on table overflow), NETSCAPE looping.
local bytes = require("bytes")

local M = {}

local function lzw(indices, n)
  local out, on = {}, 0
  local buf, nb = 0, 0
  local function put(code, size)
    buf = buf | (code << nb); nb = nb + size
    while nb >= 8 do
      on = on + 1; out[on] = buf & 0xFF
      buf = buf >> 8; nb = nb - 8
    end
  end
  local CLEAR, EOI = 256, 257
  local size, nextc = 9, 258
  local dict = {}
  put(CLEAR, size)
  local w = indices[1]
  for i = 2, n do
    local k = indices[i]
    local key = (w << 8) | k
    local c = dict[key]
    if c then
      w = c
    else
      put(w, size)
      if nextc == 4096 then
        put(CLEAR, size)
        dict, nextc, size = {}, 258, 9
      else
        if nextc >= (1 << size) then size = size + 1 end
        dict[key] = nextc; nextc = nextc + 1
      end
      w = k
    end
  end
  put(w, size)
  put(EOI, size)
  if nb > 0 then on = on + 1; out[on] = buf & 0xFF end
  -- split into sub-blocks of at most 255 bytes
  local blocks = {}
  for i = 1, on, 255 do
    local j = math.min(i + 254, on)
    blocks[#blocks + 1] = string.char(j - i + 1) .. bytes.tostring({ table.unpack(out, i, j) })
  end
  return table.concat(blocks) .. "\0"
end

-- palette: array of 256 {r,g,b}; frames: array of {indices=..., delay=centiseconds}
function M.encode(w, h, palette, frames)
  local parts = { "GIF89a", string.pack("<I2I2BBB", w, h, 0xF7, 0, 0) }
  for i = 1, 256 do
    local c = palette[i] or { 0, 0, 0 }
    parts[#parts + 1] = string.char(c[1], c[2], c[3])
  end
  parts[#parts + 1] = "\x21\xFF\x0BNETSCAPE2.0\x03\x01\0\0\0" -- loop forever
  for _, f in ipairs(frames) do
    parts[#parts + 1] = "\x21\xF9\x04" .. string.pack("<BI2BB", 0x04, f.delay or 4, 0, 0)
    parts[#parts + 1] = "\x2C" .. string.pack("<I2I2I2I2B", 0, 0, w, h, 0)
    parts[#parts + 1] = "\x08" .. lzw(f.indices, w * h)
  end
  parts[#parts + 1] = "\x3B"
  return table.concat(parts)
end

return M
