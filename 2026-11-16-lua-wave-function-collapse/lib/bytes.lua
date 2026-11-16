-- Helpers for building binary strings out of byte arrays without
-- tripping over Lua's limit on the number of arguments to string.char.
local M = {}

local char, unpack, concat = string.char, table.unpack, table.concat

function M.tostring(arr, n)
  n = n or #arr
  local parts = {}
  for i = 1, n, 4096 do
    parts[#parts + 1] = char(unpack(arr, i, math.min(i + 4095, n)))
  end
  return concat(parts)
end

function M.toarray(s)
  local arr, n = {}, #s
  for i = 1, n, 4096 do
    local chunk = { s:byte(i, math.min(i + 4095, n)) }
    for j = 1, #chunk do arr[i + j - 1] = chunk[j] end
  end
  return arr
end

local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  crc_table[i] = c
end

function M.crc32(s, crc)
  crc = (crc or 0) ~ 0xFFFFFFFF
  for i = 1, #s do
    crc = crc_table[(crc ~ s:byte(i)) & 0xFF] ~ (crc >> 8)
  end
  return crc ~ 0xFFFFFFFF
end

return M
