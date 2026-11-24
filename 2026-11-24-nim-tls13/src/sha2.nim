## SHA-256, SHA-512, HMAC and HKDF (FIPS 180-4, RFC 2104, RFC 5869).

type Bytes* = seq[byte]

proc toBytes*(s: string): Bytes =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc toStr*(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc hex*(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b:
    result.add d[int(x shr 4)]
    result.add d[int(x and 15)]

proc unhex*(s: string): Bytes =
  proc v(c: char): int =
    case c
    of '0'..'9': ord(c) - 48
    of 'a'..'f': ord(c) - 87
    of 'A'..'F': ord(c) - 55
    else: raise newException(ValueError, "bad hex")
  var t = ""
  for c in s:
    if c notin {' ', '\n', '\t', ':'}: t.add c
  result = newSeq[byte](t.len div 2)
  for i in 0 ..< result.len: result[i] = byte(v(t[2*i]) * 16 + v(t[2*i+1]))

# ---------------------------------------------------------------- SHA-256
const K256: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32, 0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32, 0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

template rotr32(x: uint32, n: int): uint32 = (x shr n) or (x shl (32 - n))
template rotr64(x: uint64, n: int): uint64 = (x shr n) or (x shl (64 - n))

type Sha256* = object
  h: array[8, uint32]
  buf: array[64, byte]
  bufLen: int
  total: uint64

proc init*(c: var Sha256) =
  c.h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
         0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  c.bufLen = 0
  c.total = 0

proc compress(c: var Sha256, p: openArray[byte], off: int) =
  var w: array[64, uint32]
  for i in 0 ..< 16:
    w[i] = (uint32(p[off+4*i]) shl 24) or (uint32(p[off+4*i+1]) shl 16) or
           (uint32(p[off+4*i+2]) shl 8) or uint32(p[off+4*i+3])
  for i in 16 ..< 64:
    let s0 = rotr32(w[i-15], 7) xor rotr32(w[i-15], 18) xor (w[i-15] shr 3)
    let s1 = rotr32(w[i-2], 17) xor rotr32(w[i-2], 19) xor (w[i-2] shr 10)
    w[i] = w[i-16] + s0 + w[i-7] + s1
  var a = c.h[0]; var b = c.h[1]; var cc = c.h[2]; var d = c.h[3]
  var e = c.h[4]; var f = c.h[5]; var g = c.h[6]; var h = c.h[7]
  for i in 0 ..< 64:
    let S1 = rotr32(e, 6) xor rotr32(e, 11) xor rotr32(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let t1 = h + S1 + ch + K256[i] + w[i]
    let S0 = rotr32(a, 2) xor rotr32(a, 13) xor rotr32(a, 22)
    let mj = (a and b) xor (a and cc) xor (b and cc)
    let t2 = S0 + mj
    h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2
  c.h[0] += a; c.h[1] += b; c.h[2] += cc; c.h[3] += d
  c.h[4] += e; c.h[5] += f; c.h[6] += g; c.h[7] += h

proc update*(c: var Sha256, data: openArray[byte]) =
  c.total += uint64(data.len)
  var i = 0
  if c.bufLen > 0:
    while i < data.len and c.bufLen < 64:
      c.buf[c.bufLen] = data[i]; inc c.bufLen; inc i
    if c.bufLen == 64:
      c.compress(c.buf, 0); c.bufLen = 0
  while i + 64 <= data.len:
    c.compress(data, i); i += 64
  while i < data.len:
    c.buf[c.bufLen] = data[i]; inc c.bufLen; inc i

proc finish*(c: var Sha256): Bytes =
  let bits = c.total * 8
  var pad = @[0x80'u8]
  while (c.total + uint64(pad.len)) mod 64 != 56: pad.add 0
  for i in countdown(7, 0): pad.add byte((bits shr (8*i)) and 0xff)
  c.update(pad)
  result = newSeq[byte](32)
  for i in 0 ..< 8:
    for j in 0 ..< 4: result[4*i+j] = byte((c.h[i] shr (24 - 8*j)) and 0xff)

proc sha256*(data: openArray[byte]): Bytes =
  var c: Sha256
  c.init(); c.update(data); c.finish()

# ---------------------------------------------------------------- SHA-512
const K512: array[80, uint64] = [
  0x428a2f98d728ae22'u64, 0x7137449123ef65cd'u64, 0xb5c0fbcfec4d3b2f'u64, 0xe9b5dba58189dbbc'u64,
  0x3956c25bf348b538'u64, 0x59f111f1b605d019'u64, 0x923f82a4af194f9b'u64, 0xab1c5ed5da6d8118'u64,
  0xd807aa98a3030242'u64, 0x12835b0145706fbe'u64, 0x243185be4ee4b28c'u64, 0x550c7dc3d5ffb4e2'u64,
  0x72be5d74f27b896f'u64, 0x80deb1fe3b1696b1'u64, 0x9bdc06a725c71235'u64, 0xc19bf174cf692694'u64,
  0xe49b69c19ef14ad2'u64, 0xefbe4786384f25e3'u64, 0x0fc19dc68b8cd5b5'u64, 0x240ca1cc77ac9c65'u64,
  0x2de92c6f592b0275'u64, 0x4a7484aa6ea6e483'u64, 0x5cb0a9dcbd41fbd4'u64, 0x76f988da831153b5'u64,
  0x983e5152ee66dfab'u64, 0xa831c66d2db43210'u64, 0xb00327c898fb213f'u64, 0xbf597fc7beef0ee4'u64,
  0xc6e00bf33da88fc2'u64, 0xd5a79147930aa725'u64, 0x06ca6351e003826f'u64, 0x142929670a0e6e70'u64,
  0x27b70a8546d22ffc'u64, 0x2e1b21385c26c926'u64, 0x4d2c6dfc5ac42aed'u64, 0x53380d139d95b3df'u64,
  0x650a73548baf63de'u64, 0x766a0abb3c77b2a8'u64, 0x81c2c92e47edaee6'u64, 0x92722c851482353b'u64,
  0xa2bfe8a14cf10364'u64, 0xa81a664bbc423001'u64, 0xc24b8b70d0f89791'u64, 0xc76c51a30654be30'u64,
  0xd192e819d6ef5218'u64, 0xd69906245565a910'u64, 0xf40e35855771202a'u64, 0x106aa07032bbd1b8'u64,
  0x19a4c116b8d2d0c8'u64, 0x1e376c085141ab53'u64, 0x2748774cdf8eeb99'u64, 0x34b0bcb5e19b48a8'u64,
  0x391c0cb3c5c95a63'u64, 0x4ed8aa4ae3418acb'u64, 0x5b9cca4f7763e373'u64, 0x682e6ff3d6b2b8a3'u64,
  0x748f82ee5defb2fc'u64, 0x78a5636f43172f60'u64, 0x84c87814a1f0ab72'u64, 0x8cc702081a6439ec'u64,
  0x90befffa23631e28'u64, 0xa4506cebde82bde9'u64, 0xbef9a3f7b2c67915'u64, 0xc67178f2e372532b'u64,
  0xca273eceea26619c'u64, 0xd186b8c721c0c207'u64, 0xeada7dd6cde0eb1e'u64, 0xf57d4f7fee6ed178'u64,
  0x06f067aa72176fba'u64, 0x0a637dc5a2c898a6'u64, 0x113f9804bef90dae'u64, 0x1b710b35131c471b'u64,
  0x28db77f523047d84'u64, 0x32caab7b40c72493'u64, 0x3c9ebe0a15c9bebc'u64, 0x431d67c49c100d4c'u64,
  0x4cc5d4becb3e42b6'u64, 0x597f299cfc657e2a'u64, 0x5fcb6fab3ad6faec'u64, 0x6c44198c4a475817'u64]

proc sha512*(data: openArray[byte]): Bytes =
  var h = [0x6a09e667f3bcc908'u64, 0xbb67ae8584caa73b'u64, 0x3c6ef372fe94f82b'u64, 0xa54ff53a5f1d36f1'u64,
           0x510e527fade682d1'u64, 0x9b05688c2b3e6c1f'u64, 0x1f83d9abfb41bd6b'u64, 0x5be0cd19137e2179'u64]
  var msg = newSeq[byte](data.len)
  for i, x in data: msg[i] = x
  let bits = uint64(data.len) * 8
  msg.add 0x80
  while msg.len mod 128 != 112: msg.add 0
  for i in 0 ..< 8: msg.add 0
  for i in countdown(7, 0): msg.add byte((bits shr (8*i)) and 0xff)
  var w: array[80, uint64]
  var blk = 0
  while blk < msg.len:
    for i in 0 ..< 16:
      var v = 0'u64
      for j in 0 ..< 8: v = (v shl 8) or uint64(msg[blk + 8*i + j])
      w[i] = v
    for i in 16 ..< 80:
      let s0 = rotr64(w[i-15], 1) xor rotr64(w[i-15], 8) xor (w[i-15] shr 7)
      let s1 = rotr64(w[i-2], 19) xor rotr64(w[i-2], 61) xor (w[i-2] shr 6)
      w[i] = w[i-16] + s0 + w[i-7] + s1
    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]
    var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
    for i in 0 ..< 80:
      let S1 = rotr64(e, 14) xor rotr64(e, 18) xor rotr64(e, 41)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + S1 + ch + K512[i] + w[i]
      let S0 = rotr64(a, 28) xor rotr64(a, 34) xor rotr64(a, 39)
      let mj = (a and b) xor (a and c) xor (b and c)
      let t2 = S0 + mj
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
    blk += 128
  result = newSeq[byte](64)
  for i in 0 ..< 8:
    for j in 0 ..< 8: result[8*i+j] = byte((h[i] shr (56 - 8*j)) and 0xff)

# ---------------------------------------------------------------- HMAC / HKDF
proc hmacSha256*(key, msg: openArray[byte]): Bytes =
  var k = newSeq[byte](64)
  if key.len > 64:
    let hk = sha256(key)
    for i in 0 ..< 32: k[i] = hk[i]
  else:
    for i in 0 ..< key.len: k[i] = key[i]
  var ipad = newSeq[byte](64)
  var opad = newSeq[byte](64)
  for i in 0 ..< 64:
    ipad[i] = k[i] xor 0x36
    opad[i] = k[i] xor 0x5c
  var inner: Sha256
  inner.init(); inner.update(ipad); inner.update(msg)
  let ih = inner.finish()
  var outer: Sha256
  outer.init(); outer.update(opad); outer.update(ih)
  outer.finish()

proc hkdfExtract*(salt, ikm: openArray[byte]): Bytes =
  if salt.len == 0: hmacSha256(newSeq[byte](32), ikm) else: hmacSha256(salt, ikm)

proc hkdfExpand*(prk, info: openArray[byte], length: int): Bytes =
  var t: Bytes = @[]
  var counter = 1'u8
  while result.len < length:
    var m = t
    for x in info: m.add x
    m.add counter
    t = hmacSha256(prk, m)
    for x in t:
      if result.len < length: result.add x
    inc counter

proc ctEqual*(a, b: openArray[byte]): bool =
  ## Constant-time comparison (for MACs / Finished).
  if a.len != b.len: return false
  var d = 0'u8
  for i in 0 ..< a.len: d = d or (a[i] xor b[i])
  d == 0
