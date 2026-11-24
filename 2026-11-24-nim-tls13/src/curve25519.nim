## X25519 (RFC 7748) and Ed25519 (RFC 8032) over GF(2^255 - 19).
## Field elements are 16 signed 16-bit limbs held in int64 (TweetNaCl layout);
## all secret-dependent operations are branch-free.
import sha2

type Gf = array[16, int64]

const
  gf0: Gf = [0'i64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  gf1: Gf = [1'i64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  c121665: Gf = [0xDB41'i64, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  D: Gf = [0x78a3'i64, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
           0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203]
  D2: Gf = [0xf159'i64, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
            0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406]
  X: Gf = [0xd51a'i64, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
           0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169]
  Y: Gf = [0x6658'i64, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
           0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666]
  I: Gf = [0xa0b0'i64, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
           0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83]

proc car(o: var Gf) =
  for i in 0 ..< 16:
    o[i] += (1'i64 shl 16)
    let c = o[i] shr 16
    if i < 15: o[i+1] += c - 1 else: o[0] += 38 * (c - 1)
    o[i] -= c shl 16

proc sel(p, q: var Gf, b: int64) =
  let c = not (b - 1)
  for i in 0 ..< 16:
    let t = c and (p[i] xor q[i])
    p[i] = p[i] xor t
    q[i] = q[i] xor t

proc pack(o: var array[32, byte], n: Gf) =
  var t = n
  var m: Gf
  car(t); car(t); car(t)
  for _ in 0 ..< 2:
    m[0] = t[0] - 0xffed
    for i in 1 ..< 15:
      m[i] = t[i] - 0xffff - ((m[i-1] shr 16) and 1)
      m[i-1] = m[i-1] and 0xffff
    m[15] = t[15] - 0x7fff - ((m[14] shr 16) and 1)
    let b = (m[15] shr 16) and 1
    m[14] = m[14] and 0xffff
    sel(t, m, 1 - b)
  for i in 0 ..< 16:
    o[2*i] = byte(t[i] and 0xff)
    o[2*i+1] = byte((t[i] shr 8) and 0xff)

proc unpack(o: var Gf, n: openArray[byte]) =
  for i in 0 ..< 16: o[i] = int64(n[2*i]) + (int64(n[2*i+1]) shl 8)
  o[15] = o[15] and 0x7fff

proc A(a, b: Gf): Gf =
  for i in 0 ..< 16: result[i] = a[i] + b[i]
proc Z(a, b: Gf): Gf =
  for i in 0 ..< 16: result[i] = a[i] - b[i]
proc M(a, b: Gf): Gf =
  var t: array[31, int64]
  for i in 0 ..< 16:
    for j in 0 ..< 16: t[i+j] += a[i] * b[j]
  for i in 0 ..< 15: t[i] += 38 * t[i+16]
  for i in 0 ..< 16: result[i] = t[i]
  car(result); car(result)
proc S(a: Gf): Gf = M(a, a)

proc inv25519(i: Gf): Gf =
  var c = i
  for a in countdown(253, 0):
    c = S(c)
    if a != 2 and a != 4: c = M(c, i)
  c

proc pow2523(i: Gf): Gf =
  var c = i
  for a in countdown(250, 0):
    c = S(c)
    if a != 1: c = M(c, i)
  c

proc neq(a, b: Gf): bool =
  var c, d: array[32, byte]
  pack(c, a); pack(d, b)
  not ctEqual(c, d)

proc par(a: Gf): byte =
  var d: array[32, byte]
  pack(d, a)
  d[0] and 1

# ---------------------------------------------------------------- X25519
proc x25519*(scalar, point: openArray[byte]): Bytes =
  var z: array[32, byte]
  for i in 0 ..< 32: z[i] = scalar[i]
  z[31] = (z[31] and 127) or 64
  z[0] = z[0] and 248
  var x: Gf
  unpack(x, point)
  var a, b, c, d: Gf
  b = x
  a = gf1; d = gf1; c = gf0
  for i in countdown(254, 0):
    let r = int64((z[i shr 3] shr (i and 7)) and 1)
    sel(a, b, r); sel(c, d, r)
    var e = A(a, c)
    a = Z(a, c)
    c = A(b, d)
    b = Z(b, d)
    d = S(e)
    var f = S(a)
    a = M(c, a)
    c = M(b, e)
    e = A(a, c)
    a = Z(a, c)
    b = S(a)
    c = Z(d, f)
    a = M(c, c121665)
    a = A(a, d)
    c = M(c, a)
    a = M(d, f)
    d = M(b, x)
    b = S(e)
    sel(a, b, r); sel(c, d, r)
  let r = M(a, inv25519(c))
  var o: array[32, byte]
  pack(o, r)
  @o

proc x25519Base*(scalar: openArray[byte]): Bytes =
  var nine = newSeq[byte](32)
  nine[0] = 9
  x25519(scalar, nine)

# ---------------------------------------------------------------- Ed25519
type Pt = array[4, Gf]   # extended coordinates (X, Y, Z, T)

proc add(p: var Pt, q: Pt) =
  let a = M(Z(p[1], p[0]), Z(q[1], q[0]))
  let b = M(A(p[0], p[1]), A(q[0], q[1]))
  let c = M(M(p[3], q[3]), D2)
  let d0 = M(p[2], q[2])
  let d = A(d0, d0)
  let e = Z(b, a); let f = Z(d, c); let g = A(d, c); let h = A(b, a)
  p[0] = M(e, f); p[1] = M(h, g); p[2] = M(g, f); p[3] = M(e, h)

proc cswap(p, q: var Pt, b: byte) =
  for i in 0 ..< 4: sel(p[i], q[i], int64(b))

proc packPt(r: var array[32, byte], p: Pt) =
  let zi = inv25519(p[2])
  let tx = M(p[0], zi); let ty = M(p[1], zi)
  pack(r, ty)
  r[31] = r[31] xor (par(tx) shl 7)

proc scalarmult(p: var Pt, q: var Pt, s: openArray[byte]) =
  p = [gf0, gf1, gf1, gf0]
  for i in countdown(255, 0):
    let b = (s[i div 8] shr (i and 7)) and 1
    cswap(p, q, b)
    add(q, p)
    add(p, p)
    cswap(p, q, b)

proc scalarbase(p: var Pt, s: openArray[byte]) =
  var q: Pt = [X, Y, gf1, M(X, Y)]
  scalarmult(p, q, s)

const L: array[32, int64] = [0xed'i64, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2,
  0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10]

proc modL(r: var array[32, byte], x: var array[64, int64]) =
  for i in countdown(63, 32):
    var carry = 0'i64
    var j = i - 32
    while j < i - 12:
      x[j] += carry - 16 * x[i] * L[j - (i - 32)]
      carry = (x[j] + 128) shr 8
      x[j] -= carry shl 8
      inc j
    x[j] += carry
    x[i] = 0
  var carry = 0'i64
  for j in 0 ..< 32:
    x[j] += carry - (x[31] shr 4) * L[j]
    carry = x[j] shr 8
    x[j] = x[j] and 255
  for j in 0 ..< 32: x[j] -= carry * L[j]
  for i in 0 ..< 32:
    x[i+1] += x[i] shr 8
    r[i] = byte(x[i] and 255)

proc reduce(h: openArray[byte]): array[32, byte] =
  var x: array[64, int64]
  for i in 0 ..< 64: x[i] = int64(h[i])
  modL(result, x)

proc ed25519PublicKey*(seed: openArray[byte]): Bytes =
  var d = sha512(seed)
  d[0] = d[0] and 248; d[31] = (d[31] and 127) or 64
  var p: Pt
  scalarbase(p, d[0 ..< 32])
  var pk: array[32, byte]
  packPt(pk, p)
  @pk

proc ed25519Sign*(seed, msg: openArray[byte]): Bytes =
  var d = sha512(seed)
  d[0] = d[0] and 248; d[31] = (d[31] and 127) or 64
  let pk = ed25519PublicKey(seed)
  var rin = d[32 ..< 64]
  for x in msg: rin.add x
  let r = reduce(sha512(rin))
  var p: Pt
  scalarbase(p, r)
  var rEnc: array[32, byte]
  packPt(rEnc, p)
  var hin = @rEnc
  hin.add pk
  for x in msg: hin.add x
  let h = reduce(sha512(hin))
  var x: array[64, int64]
  for i in 0 ..< 32: x[i] = int64(r[i])
  for i in 0 ..< 32:
    for j in 0 ..< 32: x[i+j] += int64(h[i]) * int64(d[j])
  var s: array[32, byte]
  modL(s, x)
  result = @rEnc
  result.add s

proc unpackNeg(r: var Pt, p: openArray[byte]): bool =
  ## Decode a point and negate it; false if it is not on the curve.
  r[2] = gf1
  unpack(r[1], p)
  var num = S(r[1])
  var den = M(num, D)
  num = Z(num, r[2])
  den = A(r[2], den)
  let den2 = S(den)
  let den4 = S(den2)
  let den6 = M(den4, den2)
  var t = M(den6, num)
  t = M(t, den)
  t = pow2523(t)
  t = M(t, num); t = M(t, den); t = M(t, den); r[0] = M(t, den)
  var chk = M(S(r[0]), den)
  if neq(chk, num): r[0] = M(r[0], I)
  chk = M(S(r[0]), den)
  if neq(chk, num): return false
  if par(r[0]) == (p[31] shr 7): r[0] = Z(gf0, r[0])
  r[3] = M(r[0], r[1])
  true

proc scalarIsCanonical(s: openArray[byte]): bool =
  ## RFC 8032 requires S < L (rejects malleable signatures).
  for i in countdown(31, 0):
    if int64(s[i]) < L[i]: return true
    if int64(s[i]) > L[i]: return false
  false

proc ed25519Verify*(pk, msg, sig: openArray[byte]): bool =
  if sig.len != 64 or pk.len != 32: return false
  if not scalarIsCanonical(sig[32 ..< 64]): return false
  var q: Pt
  if not unpackNeg(q, pk): return false
  var hin = sig[0 ..< 32]
  hin.add pk
  for x in msg: hin.add x
  let h = reduce(sha512(hin))
  var p: Pt
  scalarmult(p, q, h)
  var b: Pt
  scalarbase(b, sig[32 ..< 64])
  add(p, b)
  var t: array[32, byte]
  packPt(t, p)
  ctEqual(t, sig[0 ..< 32])
