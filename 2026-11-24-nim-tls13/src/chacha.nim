## ChaCha20, Poly1305 and the ChaCha20-Poly1305 AEAD (RFC 8439).
import sha2

template rotl(x: uint32, n: int): uint32 = (x shl n) or (x shr (32 - n))

proc le32(b: openArray[byte], o: int): uint32 {.inline.} =
  uint32(b[o]) or (uint32(b[o+1]) shl 8) or (uint32(b[o+2]) shl 16) or (uint32(b[o+3]) shl 24)

proc chachaBlock*(key: openArray[byte], counter: uint32, nonce: openArray[byte]): array[64, byte] =
  var s: array[16, uint32] = [0x61707865'u32, 0x3320646e'u32, 0x79622d32'u32, 0x6b206574'u32,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  for i in 0 ..< 8: s[4+i] = le32(key, 4*i)
  s[12] = counter
  for i in 0 ..< 3: s[13+i] = le32(nonce, 4*i)
  var x = s
  template qr(a, b, c, d: int) =
    x[a] += x[b]; x[d] = rotl(x[d] xor x[a], 16)
    x[c] += x[d]; x[b] = rotl(x[b] xor x[c], 12)
    x[a] += x[b]; x[d] = rotl(x[d] xor x[a], 8)
    x[c] += x[d]; x[b] = rotl(x[b] xor x[c], 7)
  for _ in 0 ..< 10:
    qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
    qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
  for i in 0 ..< 16:
    let v = x[i] + s[i]
    result[4*i] = byte(v and 0xff); result[4*i+1] = byte((v shr 8) and 0xff)
    result[4*i+2] = byte((v shr 16) and 0xff); result[4*i+3] = byte(v shr 24)

proc chacha20Xor*(key: openArray[byte], counter: uint32, nonce, data: openArray[byte]): Bytes =
  result = newSeq[byte](data.len)
  var ctr = counter
  var i = 0
  while i < data.len:
    let ks = chachaBlock(key, ctr, nonce)
    for j in 0 ..< 64:
      if i + j >= data.len: break
      result[i+j] = data[i+j] xor ks[j]
    i += 64
    inc ctr

proc poly1305*(key, msg: openArray[byte]): Bytes =
  ## 26-bit limb implementation (after poly1305-donna-32).
  let r0 = le32(key, 0) and 0x3ffffff
  let r1 = (le32(key, 3) shr 2) and 0x3ffff03
  let r2 = (le32(key, 6) shr 4) and 0x3ffc0ff
  let r3 = (le32(key, 9) shr 6) and 0x3f03fff
  let r4 = (le32(key, 12) shr 8) and 0x00fffff
  let s1 = r1 * 5; let s2 = r2 * 5; let s3 = r3 * 5; let s4 = r4 * 5
  var h0, h1, h2, h3, h4: uint32
  var i = 0
  var blk: array[17, byte]
  while i < msg.len:
    let n = min(16, msg.len - i)
    for j in 0 ..< 17: blk[j] = 0
    for j in 0 ..< n: blk[j] = msg[i+j]
    blk[n] = 1
    h0 += le32(blk, 0) and 0x3ffffff
    h1 += (le32(blk, 3) shr 2) and 0x3ffffff
    h2 += (le32(blk, 6) shr 4) and 0x3ffffff
    h3 += (le32(blk, 9) shr 6) and 0x3ffffff
    h4 += (le32(blk, 12) shr 8) or (uint32(blk[16]) shl 24)
    let d0 = uint64(h0)*r0 + uint64(h1)*s4 + uint64(h2)*s3 + uint64(h3)*s2 + uint64(h4)*s1
    var d1 = uint64(h0)*r1 + uint64(h1)*r0 + uint64(h2)*s4 + uint64(h3)*s3 + uint64(h4)*s2
    var d2 = uint64(h0)*r2 + uint64(h1)*r1 + uint64(h2)*r0 + uint64(h3)*s4 + uint64(h4)*s3
    var d3 = uint64(h0)*r3 + uint64(h1)*r2 + uint64(h2)*r1 + uint64(h3)*r0 + uint64(h4)*s4
    var d4 = uint64(h0)*r4 + uint64(h1)*r3 + uint64(h2)*r2 + uint64(h3)*r1 + uint64(h4)*r0
    var c = uint32(d0 shr 26); h0 = uint32(d0) and 0x3ffffff
    d1 += c; c = uint32(d1 shr 26); h1 = uint32(d1) and 0x3ffffff
    d2 += c; c = uint32(d2 shr 26); h2 = uint32(d2) and 0x3ffffff
    d3 += c; c = uint32(d3 shr 26); h3 = uint32(d3) and 0x3ffffff
    d4 += c; c = uint32(d4 shr 26); h4 = uint32(d4) and 0x3ffffff
    h0 += c * 5; c = h0 shr 26; h0 = h0 and 0x3ffffff
    h1 += c
    i += 16
  # full carry
  var c = h1 shr 26; h1 = h1 and 0x3ffffff
  h2 += c; c = h2 shr 26; h2 = h2 and 0x3ffffff
  h3 += c; c = h3 shr 26; h3 = h3 and 0x3ffffff
  h4 += c; c = h4 shr 26; h4 = h4 and 0x3ffffff
  h0 += c * 5; c = h0 shr 26; h0 = h0 and 0x3ffffff
  h1 += c
  # compute h - p and select constant-time
  var g0 = h0 + 5; c = g0 shr 26; g0 = g0 and 0x3ffffff
  var g1 = h1 + c; c = g1 shr 26; g1 = g1 and 0x3ffffff
  var g2 = h2 + c; c = g2 shr 26; g2 = g2 and 0x3ffffff
  var g3 = h3 + c; c = g3 shr 26; g3 = g3 and 0x3ffffff
  let g4 = h4 + c - (1'u32 shl 26)
  let mask = (g4 shr 31) - 1   # all ones if g4 didn't underflow (h >= p)
  h0 = (h0 and not mask) or (g0 and mask)
  h1 = (h1 and not mask) or (g1 and mask)
  h2 = (h2 and not mask) or (g2 and mask)
  h3 = (h3 and not mask) or (g3 and mask)
  h4 = (h4 and not mask) or (g4 and mask)
  # h mod 2^128, then + s
  let w0 = (h0 or (h1 shl 26))
  let w1 = ((h1 shr 6) or (h2 shl 20))
  let w2 = ((h2 shr 12) or (h3 shl 14))
  let w3 = ((h3 shr 18) or (h4 shl 8))
  var f = uint64(w0) + le32(key, 16)
  var o: array[4, uint32]
  o[0] = uint32(f and 0xffffffff'u64)
  f = uint64(w1) + le32(key, 20) + (f shr 32); o[1] = uint32(f and 0xffffffff'u64)
  f = uint64(w2) + le32(key, 24) + (f shr 32); o[2] = uint32(f and 0xffffffff'u64)
  f = uint64(w3) + le32(key, 28) + (f shr 32); o[3] = uint32(f and 0xffffffff'u64)
  result = newSeq[byte](16)
  for k in 0 ..< 4:
    for j in 0 ..< 4: result[4*k+j] = byte((o[k] shr (8*j)) and 0xff)

proc macData(aad, ct: openArray[byte]): Bytes =
  for x in aad: result.add x
  while result.len mod 16 != 0: result.add 0
  for x in ct: result.add x
  while result.len mod 16 != 0: result.add 0
  for v in [uint64(aad.len), uint64(ct.len)]:
    for j in 0 ..< 8: result.add byte((v shr (8*j)) and 0xff)

proc chachaPolySeal*(key, nonce, aad, pt: openArray[byte]): Bytes =
  let otk = chachaBlock(key, 0, nonce)
  let ct = chacha20Xor(key, 1, nonce, pt)
  let tag = poly1305(otk[0 ..< 32], macData(aad, ct))
  result = ct
  result.add tag

proc chachaPolyOpen*(key, nonce, aad, ctTag: openArray[byte], ok: var bool): Bytes =
  ok = false
  if ctTag.len < 16: return
  let ct = ctTag[0 ..< ctTag.len - 16]
  let otk = chachaBlock(key, 0, nonce)
  let tag = poly1305(otk[0 ..< 32], macData(aad, ct))
  if not ctEqual(tag, ctTag[ctTag.len - 16 ..< ctTag.len]): return
  ok = true
  chacha20Xor(key, 1, nonce, ct)
