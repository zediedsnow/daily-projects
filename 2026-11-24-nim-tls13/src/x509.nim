## Minimal DER / X.509 parser and Ed25519 certificate-chain verifier (RFC 5280 subset).
import std/[strutils, times, base64]
import sha2, curve25519

type
  X509Error* = object of CatchableError
  Tlv = object
    tag: int
    start, hdrLen, len: int      # offsets into the buffer
  Cert* = object
    raw*: Bytes
    tbs*: Bytes
    issuer*, subject*: Bytes      # raw DER Name encodings, compared bytewise
    subjectCN*, issuerCN*: string
    notBefore*, notAfter*: Time
    pubKey*: Bytes               # 32-byte Ed25519 key
    sigAlgEd25519*: bool
    signature*: Bytes
    isCA*: bool
    dnsNames*: seq[string]
    ipAddrs*: seq[string]
    serial*: string

const
  oidEd25519 = @[0x2b'u8, 0x65, 0x70]
  oidCN = @[0x55'u8, 0x04, 0x03]
  oidSAN = @[0x55'u8, 0x1d, 0x11]
  oidBasic = @[0x55'u8, 0x1d, 0x13]

proc fail(msg: string) {.noreturn.} = raise newException(X509Error, msg)

proc readTlv(b: openArray[byte], pos: int, limit: int): Tlv =
  if pos + 2 > limit: fail "truncated DER"
  result.tag = int(b[pos])
  if (result.tag and 0x1f) == 0x1f: fail "high tag numbers unsupported"
  var l = int(b[pos+1])
  var h = 2
  if l >= 0x80:
    let n = l and 0x7f
    if n == 0 or n > 3: fail "bad DER length"
    if pos + 2 + n > limit: fail "truncated DER length"
    l = 0
    for i in 0 ..< n: l = (l shl 8) or int(b[pos+2+i])
    if l < 0x80 or (n > 1 and int(b[pos+2]) == 0): fail "non-minimal DER length"
    h = 2 + n
  result.start = pos; result.hdrLen = h; result.len = l
  if pos + h + l > limit: fail "DER element overruns parent"

template body(t: Tlv): int = t.start + t.hdrLen
template endOf(t: Tlv): int = t.start + t.hdrLen + t.len

proc children(b: openArray[byte], t: Tlv): seq[Tlv] =
  var p = t.body
  while p < t.endOf:
    let c = readTlv(b, p, t.endOf)
    result.add c
    p = c.endOf

proc slice(b: openArray[byte], t: Tlv, whole = false): Bytes =
  if whole: @(b[t.start ..< t.endOf]) else: @(b[t.body ..< t.endOf])

proc expect(t: Tlv, tag: int, what: string) =
  if t.tag != tag: fail what & ": expected tag 0x" & toHex(tag, 2) & " got 0x" & toHex(t.tag, 2)

proc parseTime(b: openArray[byte], t: Tlv): Time =
  var s = toStr(slice(b, t))
  if t.tag == 0x17:   # UTCTime YYMMDDHHMMSSZ
    if s.len != 13 or s[^1] != 'Z': fail "bad UTCTime"
    let yy = parseInt(s[0..1])
    s = (if yy >= 50: "19" else: "20") & s
  elif t.tag != 0x18: fail "bad time tag"
  if s.len != 15 or s[^1] != 'Z': fail "bad GeneralizedTime"
  try:
    parse(s[0 ..< 14], "yyyyMMddHHmmss", utc()).toTime
  except CatchableError:
    fail "unparseable time"

proc cnOf(b: openArray[byte], name: Tlv): string =
  for rdn in children(b, name):
    for atv in children(b, rdn):
      let kv = children(b, atv)
      if kv.len == 2 and slice(b, kv[0]) == oidCN: return toStr(slice(b, kv[1]))

proc parseCert*(der: Bytes): Cert =
  result.raw = der
  let top = readTlv(der, 0, der.len)
  top.expect(0x30, "Certificate")
  if top.endOf != der.len: fail "trailing data after certificate"
  let parts = children(der, top)
  if parts.len != 3: fail "Certificate must have 3 parts"
  result.tbs = slice(der, parts[0], whole = true)
  let alg = children(der, parts[1])
  result.sigAlgEd25519 = alg.len >= 1 and slice(der, alg[0]) == oidEd25519
  parts[2].expect(0x03, "signatureValue")
  let sv = slice(der, parts[2])
  if sv.len < 1 or sv[0] != 0: fail "bad signature BIT STRING"
  result.signature = sv[1 .. ^1]
  var f = children(der, parts[0])
  var i = 0
  if f.len > 0 and f[0].tag == 0xa0: inc i           # [0] version
  if f.len < i + 6: fail "TBSCertificate too short"
  f[i].expect(0x02, "serial"); result.serial = hex(slice(der, f[i]))
  let issuerT = f[i+2]; let validity = f[i+3]; let subjectT = f[i+4]; let spki = f[i+5]
  issuerT.expect(0x30, "issuer"); subjectT.expect(0x30, "subject")
  result.issuer = slice(der, issuerT, whole = true)
  result.subject = slice(der, subjectT, whole = true)
  result.issuerCN = cnOf(der, issuerT)
  result.subjectCN = cnOf(der, subjectT)
  let v = children(der, validity)
  if v.len != 2: fail "bad validity"
  result.notBefore = parseTime(der, v[0]); result.notAfter = parseTime(der, v[1])
  let sp = children(der, spki)
  if sp.len != 2: fail "bad SubjectPublicKeyInfo"
  let spAlg = children(der, sp[0])
  if spAlg.len >= 1 and slice(der, spAlg[0]) == oidEd25519:
    let k = slice(der, sp[1])
    if k.len != 33 or k[0] != 0: fail "bad Ed25519 key"
    result.pubKey = k[1 .. ^1]
  # extensions
  for j in i+6 ..< f.len:
    if f[j].tag != 0xa3: continue
    let extsSeq = children(der, f[j])
    if extsSeq.len != 1: fail "bad extensions"
    for ext in children(der, extsSeq[0]):
      let e = children(der, ext)
      if e.len < 2: fail "bad extension"
      let oid = slice(der, e[0])
      let valT = e[^1]
      valT.expect(0x04, "extnValue")
      let inner = readTlv(der, valT.body, valT.endOf)
      if oid == oidSAN:
        for gn in children(der, inner):
          if gn.tag == 0x82: result.dnsNames.add toStr(slice(der, gn))
          elif gn.tag == 0x87 and gn.len == 4:
            let ip = slice(der, gn)
            result.ipAddrs.add $ip[0] & "." & $ip[1] & "." & $ip[2] & "." & $ip[3]
      elif oid == oidBasic:
        for c in children(der, inner):
          if c.tag == 0x01 and c.len == 1 and der[c.body] != 0: result.isCA = true

proc pemDecode*(text: string, label: string): seq[Bytes] =
  ## Every block "-----BEGIN <label>-----" ... in order.
  let b = "-----BEGIN " & label & "-----"
  let e = "-----END " & label & "-----"
  var p = 0
  while true:
    let s = text.find(b, p)
    if s < 0: break
    let t = text.find(e, s)
    if t < 0: fail "unterminated PEM block"
    var body = text[s + b.len ..< t]
    body = body.multiReplace(("\n", ""), ("\r", ""), (" ", ""))
    result.add toBytes(decode(body))
    p = t + e.len

proc ed25519SeedFromPkcs8*(der: Bytes): Bytes =
  ## PrivateKeyInfo { version, AlgorithmIdentifier{1.3.101.112}, OCTET STRING { OCTET STRING seed } }
  let top = readTlv(der, 0, der.len)
  let p = children(der, top)
  if p.len < 3: fail "bad PKCS#8"
  let alg = children(der, p[1])
  if alg.len < 1 or slice(der, alg[0]) != oidEd25519: fail "private key is not Ed25519"
  let inner = readTlv(der, p[2].body, p[2].endOf)
  inner.expect(0x04, "CurvePrivateKey")
  result = slice(der, inner)
  if result.len != 32: fail "bad Ed25519 seed"

proc hostMatches(pattern, host: string): bool =
  let p = pattern.toLowerAscii; let h = host.toLowerAscii
  if p.startsWith("*."):
    let dot = h.find('.')
    return dot > 0 and h[dot+1 .. ^1] == p[2 .. ^1]
  p == h

proc verifyChain*(chain: seq[Cert], anchors: seq[Cert], host: string, now = getTime()): string =
  ## Returns "" when the chain is valid for `host`, else a reason.
  if chain.len == 0: return "empty certificate chain"
  let leaf = chain[0]
  if leaf.pubKey.len != 32: return "leaf key is not Ed25519"
  if host.len > 0:
    var ok = false
    for n in leaf.dnsNames:
      if hostMatches(n, host): ok = true
    for ip in leaf.ipAddrs:
      if ip == host: ok = true
    if leaf.dnsNames.len == 0 and leaf.ipAddrs.len == 0 and hostMatches(leaf.subjectCN, host): ok = true
    if not ok: return "certificate is not valid for host '" & host & "'"
  # Path building: starting at the leaf, repeatedly look for a trust anchor or a
  # certificate in the peer's bundle that issued the current one.  Order and
  # duplicates in the bundle are tolerated (RFC 8446 4.4.2), loops are not.
  var cur = leaf
  var used = @[0]
  for depth in 0 .. 8:
    if now < cur.notBefore: return "certificate '" & cur.subjectCN & "' is not yet valid"
    if now > cur.notAfter: return "certificate '" & cur.subjectCN & "' has expired"
    for a in anchors:
      if a.raw == cur.raw: return ""
      if a.subject == cur.issuer:
        if not cur.sigAlgEd25519 or a.pubKey.len != 32 or not ed25519Verify(a.pubKey, cur.tbs, cur.signature):
          return "bad signature on '" & cur.subjectCN & "' (claimed issuer: trusted root '" & a.subjectCN & "')"
        if now > a.notAfter or now < a.notBefore: return "trust anchor is outside its validity period"
        return ""
    var next = -1
    for j, p in chain:
      if j notin used and p.subject == cur.issuer and p.raw != cur.raw:
        next = j; break
    if next < 0: return "no trusted root found for the chain (issuer '" & cur.issuerCN & "')"
    let parent = chain[next]
    if not parent.isCA: return "'" & parent.subjectCN & "' is not a CA"
    if not cur.sigAlgEd25519 or parent.pubKey.len != 32 or not ed25519Verify(parent.pubKey, cur.tbs, cur.signature):
      return "bad signature on '" & cur.subjectCN & "'"
    used.add next
    cur = parent
  "certificate chain too long"
