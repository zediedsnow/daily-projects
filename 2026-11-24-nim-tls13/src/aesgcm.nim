## AES-128 (FIPS 197) and GCM (NIST SP 800-38D).
import sha2

proc xtime(x: byte): byte {.inline.} =
  byte(((int(x) shl 1) xor (if (x and 0x80) != 0: 0x1b else: 0)) and 0xff)

proc gmul(a, b: byte): byte =
  var a = a; var b = b
  while b != 0:
    if (b and 1) != 0: result = result xor a
    a = xtime(a); b = b shr 1

proc buildSbox(): array[256, byte] =
  # inverse in GF(2^8) followed by the affine transform
  for i in 0 ..< 256:
    var inv = 0'u8
    if i != 0:
      for j in 1 ..< 256:
        if gmul(byte(i), byte(j)) == 1: inv = byte(j); break
    var s = inv
    var x = inv
    for _ in 0 ..< 4:
      x = byte(((int(x) shl 1) or (int(x) shr 7)) and 0xff)
      s = s xor x
    result[i] = s xor 0x63

const SBOX = buildSbox()

type Aes128* = object
  rk: array[176, byte]

proc initAes128*(key: openArray[byte]): Aes128 =
  for i in 0 ..< 16: result.rk[i] = key[i]
  var rcon = 1'u8
  var i = 16
  while i < 176:
    var t = [result.rk[i-4], result.rk[i-3], result.rk[i-2], result.rk[i-1]]
    if i mod 16 == 0:
      let u = t
      t = [SBOX[u[1]] xor rcon, SBOX[u[2]], SBOX[u[3]], SBOX[u[0]]]
      rcon = xtime(rcon)
    for j in 0 ..< 4: result.rk[i+j] = result.rk[i-16+j] xor t[j]
    i += 4

proc encryptBlock*(a: Aes128, input: openArray[byte]): array[16, byte] =
  var s: array[16, byte]
  for i in 0 ..< 16: s[i] = input[i] xor a.rk[i]
  for round in 1 .. 10:
    var t: array[16, byte]
    # SubBytes + ShiftRows (column-major state)
    for c in 0 ..< 4:
      for r in 0 ..< 4:
        t[4*c + r] = SBOX[s[4*((c + r) mod 4) + r]]
    if round != 10:
      for c in 0 ..< 4:
        let a0 = t[4*c]; let a1 = t[4*c+1]; let a2 = t[4*c+2]; let a3 = t[4*c+3]
        let all = a0 xor a1 xor a2 xor a3
        t[4*c]   = a0 xor all xor xtime(a0 xor a1)
        t[4*c+1] = a1 xor all xor xtime(a1 xor a2)
        t[4*c+2] = a2 xor all xor xtime(a2 xor a3)
        t[4*c+3] = a3 xor all xor xtime(a3 xor a0)
    for i in 0 ..< 16: s[i] = t[i] xor a.rk[16*round + i]
  s

# ---------------------------------------------------------------- GHASH
type U128 = tuple[hi, lo: uint64]

proc load128(b: openArray[byte], o = 0): U128 =
  for i in 0 ..< 8: result.hi = (result.hi shl 8) or uint64(b[o+i])
  for i in 8 ..< 16: result.lo = (result.lo shl 8) or uint64(b[o+i])

proc gfMul(x, y: U128): U128 =
  ## Multiply in GF(2^128) with GCM's reflected bit order.
  var z: U128 = (0'u64, 0'u64)
  var v = y
  for i in 0 ..< 128:
    let bit = if i < 64: (x.hi shr (63 - i)) and 1 else: (x.lo shr (127 - i)) and 1
    let m = 0'u64 - bit
    z.hi = z.hi xor (v.hi and m); z.lo = z.lo xor (v.lo and m)
    let lsb = v.lo and 1
    v.lo = (v.lo shr 1) or (v.hi shl 63)
    v.hi = (v.hi shr 1) xor (0xe100000000000000'u64 and (0'u64 - lsb))
  z

proc ghash(h: U128, aad, ct: openArray[byte]): U128 =
  var y: U128 = (0'u64, 0'u64)
  proc absorb(y: var U128, data: openArray[byte]) =
    var i = 0
    while i < data.len:
      var blk: array[16, byte]
      for j in 0 ..< 16:
        if i + j < data.len: blk[j] = data[i+j]
      let b = load128(blk)
      y = gfMul((y.hi xor b.hi, y.lo xor b.lo), h)
      i += 16
  absorb(y, aad)
  absorb(y, ct)
  let lens: U128 = (uint64(aad.len) * 8, uint64(ct.len) * 8)
  gfMul((y.hi xor lens.hi, y.lo xor lens.lo), h)

proc ctrXor(a: Aes128, j0: array[16, byte], data: openArray[byte]): Bytes =
  result = newSeq[byte](data.len)
  var ctr = j0
  var i = 0
  while i < data.len:
    # increment low 32 bits
    var c = (uint32(ctr[12]) shl 24) or (uint32(ctr[13]) shl 16) or (uint32(ctr[14]) shl 8) or uint32(ctr[15])
    c += 1
    ctr[12] = byte(c shr 24); ctr[13] = byte((c shr 16) and 0xff)
    ctr[14] = byte((c shr 8) and 0xff); ctr[15] = byte(c and 0xff)
    let ks = a.encryptBlock(ctr)
    for j in 0 ..< 16:
      if i + j < data.len: result[i+j] = data[i+j] xor ks[j]
    i += 16

proc tagFor(a: Aes128, j0: array[16, byte], aad, ct: openArray[byte]): Bytes =
  var zero: array[16, byte]
  let h = load128(a.encryptBlock(zero))
  let s = ghash(h, aad, ct)
  let ek = a.encryptBlock(j0)
  result = newSeq[byte](16)
  for i in 0 ..< 8:
    result[i] = ek[i] xor byte((s.hi shr (56 - 8*i)) and 0xff)
    result[8+i] = ek[8+i] xor byte((s.lo shr (56 - 8*i)) and 0xff)

proc j0Of(nonce: openArray[byte]): array[16, byte] =
  for i in 0 ..< 12: result[i] = nonce[i]
  result[15] = 1

proc aesGcmSeal*(key, nonce, aad, pt: openArray[byte]): Bytes =
  let a = initAes128(key)
  let j0 = j0Of(nonce)
  result = ctrXor(a, j0, pt)
  result.add tagFor(a, j0, aad, result)

proc aesGcmOpen*(key, nonce, aad, ctTag: openArray[byte], ok: var bool): Bytes =
  ok = false
  if ctTag.len < 16: return
  let a = initAes128(key)
  let j0 = j0Of(nonce)
  let ct = ctTag[0 ..< ctTag.len - 16]
  if not ctEqual(tagFor(a, j0, aad, ct), ctTag[ctTag.len - 16 ..< ctTag.len]): return
  ok = true
  ctrXor(a, j0, ct)
