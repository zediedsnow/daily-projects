-- Minimal PNG writer with its own DEFLATE compressor (LZ77 with hash
-- chains + the fixed Huffman code from RFC 1951). Pixel art is mostly
-- long runs, so this gets within a small factor of zlib with ~100 lines.
local bytes = require("bytes")

local M = {}

-- length codes 257..285: base length and extra bits
local LBASE = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258 }
local LEXTRA = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0 }
-- distance codes 0..29
local DBASE = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577 }
local DEXTRA = { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 }

-- precompute: length -> (code index), distance lookup is by scan
local LEN_CODE = {}
for len = 3, 258 do
  local c = 1
  while c < 29 and LBASE[c + 1] <= len do c = c + 1 end
  LEN_CODE[len] = c
end

local function dist_code(d)
  local lo, hi = 1, 30
  while lo < hi do -- largest i with DBASE[i] <= d
    local mid = (lo + hi + 1) // 2
    if DBASE[mid] <= d then lo = mid else hi = mid - 1 end
  end
  return lo
end

-- reverse the low n bits of v (Huffman codes are sent MSB first)
local function rev(v, n)
  local r = 0
  for _ = 1, n do r = (r << 1) | (v & 1); v = v >> 1 end
  return r
end

-- fixed Huffman table for literal/length symbols 0..287
local FIXED = {}
for s = 0, 287 do
  local code, n
  if s <= 143 then code, n = 0x30 + s, 8
  elseif s <= 255 then code, n = 0x190 + s - 144, 9
  elseif s <= 279 then code, n = s - 256, 7
  else code, n = 0xC0 + s - 280, 8 end
  FIXED[s] = { rev(code, n), n }
end
local FIXED_D = {}
for d = 0, 29 do FIXED_D[d] = rev(d, 5) end

function M.deflate(data)
  local src = bytes.toarray(data)
  local n = #src
  local out, on = {}, 0
  local buf, nb = 0, 0
  local function put(v, bits)
    buf = buf | (v << nb); nb = nb + bits
    while nb >= 8 do
      on = on + 1; out[on] = buf & 0xFF
      buf = buf >> 8; nb = nb - 8
    end
  end
  local function sym(s) local f = FIXED[s]; put(f[1], f[2]) end

  put(1, 1); put(1, 2) -- BFINAL=1, BTYPE=01 (fixed Huffman)
  local head, prev = {}, {}
  local MAXCHAIN, WINDOW = 48, 32768
  local i = 1
  while i <= n do
    local best, bestd = 0, 0
    if i + 2 <= n then
      local key = (src[i] << 16) | (src[i + 1] << 8) | src[i + 2]
      local cand = head[key]
      local chain = 0
      local limit = math.min(258, n - i + 1)
      while cand and i - cand <= WINDOW and chain < MAXCHAIN do
        if src[cand + best] == src[i + best] then
          local l = 0
          while l < limit and src[cand + l] == src[i + l] do l = l + 1 end
          if l > best then
            best, bestd = l, i - cand
            if l == limit then break end
          end
        end
        cand = prev[cand]; chain = chain + 1
      end
      prev[i] = head[key]; head[key] = i
    end
    if best >= 3 then
      local lc = LEN_CODE[best]
      sym(256 + lc)
      if LEXTRA[lc] > 0 then put(best - LBASE[lc], LEXTRA[lc]) end
      local dc = dist_code(bestd)
      put(FIXED_D[dc - 1], 5)
      if DEXTRA[dc] > 0 then put(bestd - DBASE[dc], DEXTRA[dc]) end
      -- index the skipped positions so later matches can find them
      for j = i + 1, math.min(i + best - 1, n - 2) do
        local key = (src[j] << 16) | (src[j + 1] << 8) | src[j + 2]
        prev[j] = head[key]; head[key] = j
      end
      i = i + best
    else
      sym(src[i]); i = i + 1
    end
  end
  sym(256)
  if nb > 0 then on = on + 1; out[on] = buf & 0xFF end
  return bytes.tostring(out, on)
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return (b << 16) | a
end

local function chunk(kind, payload)
  return string.pack(">I4", #payload) .. kind .. payload
      .. string.pack(">I4", bytes.crc32(kind .. payload))
end

-- pixels: function(x, y) -> r, g, b  (0-based coords)
function M.encode(w, h, pixel)
  local rows = {}
  for y = 0, h - 1 do
    local row, k = { 0 }, 1
    for x = 0, w - 1 do
      local r, g, b = pixel(x, y)
      row[k + 1], row[k + 2], row[k + 3] = r, g, b
      k = k + 3
    end
    rows[y + 1] = bytes.tostring(row, k)
  end
  local raw = table.concat(rows)
  local z = "\x78\x01" .. M.deflate(raw) .. string.pack(">I4", adler32(raw))
  return "\x89PNG\r\n\26\n"
      .. chunk("IHDR", string.pack(">I4I4BBBBB", w, h, 8, 2, 0, 0, 0))
      .. chunk("IDAT", z)
      .. chunk("IEND", "")
end

function M.write(path, w, h, pixel)
  local f = assert(io.open(path, "wb"))
  f:write(M.encode(w, h, pixel))
  f:close()
end

return M
