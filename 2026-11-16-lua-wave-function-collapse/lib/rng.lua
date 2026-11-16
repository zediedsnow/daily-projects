-- SplitMix64: tiny, fast, and identical on every Lua 5.4 build
-- (math.random's sequence is an implementation detail; ours is not).
local Rng = {}
Rng.__index = Rng

function Rng.new(seed)
  return setmetatable({ s = math.tointeger(seed) or 0 }, Rng)
end

function Rng:next()
  self.s = self.s + 0x9E3779B97F4A7C15 -- 64-bit integer arithmetic wraps
  local z = self.s
  z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
  z = (z ~ (z >> 27)) * 0x94D049BB133111EB
  return z ~ (z >> 31)
end

-- uniform float in [0, 1)
function Rng:float()
  return (self:next() >> 11) * (1.0 / 9007199254740992.0)
end

return Rng
