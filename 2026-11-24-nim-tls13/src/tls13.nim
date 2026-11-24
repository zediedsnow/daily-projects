## TLS 1.3 (RFC 8446) client and server: record layer, key schedule, handshake.
## Suites: TLS_CHACHA20_POLY1305_SHA256, TLS_AES_128_GCM_SHA256.
## Key exchange: X25519.  Certificates / CertificateVerify: Ed25519.
import std/[net, sysrand, strutils, sequtils]
import sha2, chacha, aesgcm, curve25519, x509
export x509

const
  ctChangeCipherSpec = 20'u8
  ctAlert = 21'u8
  ctHandshake = 22'u8
  ctAppData = 23'u8

  hsClientHello* = 1'u8
  hsServerHello* = 2'u8
  hsNewSessionTicket* = 4'u8
  hsEncryptedExtensions* = 8'u8
  hsCertificate* = 11'u8
  hsCertificateRequest* = 13'u8
  hsCertificateVerify* = 15'u8
  hsFinished* = 20'u8
  hsKeyUpdate* = 24'u8
  hsMessageHash = 254'u8

  suiteAes128Gcm* = 0x1301'u16
  suiteChaCha* = 0x1303'u16
  groupX25519 = 0x001d'u16
  sigEd25519 = 0x0807'u16

  extServerName = 0'u16
  extSupportedGroups = 10'u16
  extSigAlgs = 13'u16
  extAlpn = 16'u16
  extSupportedVersions = 43'u16
  extCookie = 44'u16
  extKeyShare = 51'u16

  # alert descriptions
  alCloseNotify* = 0'u8
  alUnexpectedMessage = 10'u8
  alBadRecordMac = 20'u8
  alRecordOverflow = 22'u8
  alHandshakeFailure = 40'u8
  alBadCertificate = 42'u8
  alIllegalParameter = 47'u8
  alDecodeError = 50'u8
  alDecryptError = 51'u8
  alProtocolVersion = 70'u8
  alInternalError = 80'u8
  alMissingExtension = 109'u8

  hrrRandom = "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c"

type
  TlsError* = object of CatchableError
    alert*: uint8
  CipherState = object
    active: bool
    suite: uint16
    secret: Bytes
    key, iv: Bytes
    seq: uint64
  Role* = enum rClient, rServer
  TlsConn* = ref object
    sock*: Socket
    role*: Role
    rd, wr: CipherState
    hsBuf: Bytes
    transcript: Bytes
    suite*: uint16
    peerClosed*: bool
    appBuf: Bytes
    trace*: proc (s: string)
    keylog*: File
    clientRandom*: Bytes
    serverName*: string
    peerChain*: seq[Cert]
    hrrSent*: bool
    keyUpdatesReceived*: int
    alpn*: string

proc tlsFail(alert: uint8, msg: string) {.noreturn.} =
  var e = newException(TlsError, msg)
  e.alert = alert
  raise e

proc log(c: TlsConn, s: string) =
  if c.trace != nil: c.trace(s)

proc suiteName*(s: uint16): string =
  case s
  of suiteChaCha: "TLS_CHACHA20_POLY1305_SHA256"
  of suiteAes128Gcm: "TLS_AES_128_GCM_SHA256"
  else: "0x" & toHex(int(s), 4)

# ---------------------------------------------------------------- byte helpers
proc u8(b: var Bytes, v: int) = b.add byte(v and 0xff)
proc u16(b: var Bytes, v: int) = b.u8(v shr 8); b.u8(v)
proc u24(b: var Bytes, v: int) = b.u8(v shr 16); b.u8(v shr 8); b.u8(v)
proc vec8(b: var Bytes, d: openArray[byte]) = b.u8(d.len); b.add d
proc vec16(b: var Bytes, d: openArray[byte]) = b.u16(d.len); b.add d
proc vec24(b: var Bytes, d: openArray[byte]) = b.u24(d.len); b.add d

type Reader = object
  d: Bytes
  p: int

proc rdr(d: Bytes): Reader = Reader(d: d, p: 0)
proc left(r: Reader): int = r.d.len - r.p
proc need(r: Reader, n: int) =
  if r.p + n > r.d.len: tlsFail(alDecodeError, "message truncated")
proc r8(r: var Reader): int =
  r.need(1); result = int(r.d[r.p]); inc r.p
proc r16(r: var Reader): int =
  r.need(2); result = (int(r.d[r.p]) shl 8) or int(r.d[r.p+1]); r.p += 2
proc r24(r: var Reader): int =
  r.need(3); result = (int(r.d[r.p]) shl 16) or (int(r.d[r.p+1]) shl 8) or int(r.d[r.p+2]); r.p += 3
proc take(r: var Reader, n: int): Bytes =
  r.need(n); result = r.d[r.p ..< r.p + n]; r.p += n
proc rv8(r: var Reader): Bytes = r.take(r.r8)
proc rv16(r: var Reader): Bytes = r.take(r.r16)
proc rv24(r: var Reader): Bytes = r.take(r.r24)
proc done(r: Reader) =
  if r.left != 0: tlsFail(alDecodeError, "trailing bytes in message")

proc randomBytes(n: int): Bytes =
  result = newSeq[byte](n)
  if not urandom(result): tlsFail(alInternalError, "no randomness")

# ---------------------------------------------------------------- key schedule
proc expandLabel*(secret: Bytes, label: string, context: Bytes, length: int): Bytes =
  var info: Bytes
  info.u16(length)
  info.vec8(toBytes("tls13 " & label))
  info.vec8(context)
  hkdfExpand(secret, info, length)

proc deriveSecret*(secret: Bytes, label: string, transcriptHash: Bytes): Bytes =
  expandLabel(secret, label, transcriptHash, 32)

proc keyLen(suite: uint16): int = (if suite == suiteChaCha: 32 else: 16)

proc setKeys(cs: var CipherState, suite: uint16, secret: Bytes) =
  cs.active = true
  cs.suite = suite
  cs.secret = secret
  cs.key = expandLabel(secret, "key", @[], keyLen(suite))
  cs.iv = expandLabel(secret, "iv", @[], 12)
  cs.seq = 0

proc nonceFor(cs: CipherState): Bytes =
  result = cs.iv
  for i in 0 ..< 8: result[11 - i] = result[11 - i] xor byte((cs.seq shr (8*i)) and 0xff)

proc thash(c: TlsConn): Bytes = sha256(c.transcript)

proc keylogLine(c: TlsConn, label: string, secret: Bytes) =
  if c.keylog != nil:
    c.keylog.writeLine(label & " " & hex(c.clientRandom) & " " & hex(secret))
    c.keylog.flushFile()

# ---------------------------------------------------------------- record layer
proc recvExact(c: TlsConn, n: int): Bytes =
  var s = ""
  while s.len < n:
    var chunk = ""
    let got = c.sock.recv(chunk, n - s.len)
    if got <= 0: tlsFail(alDecodeError, "connection closed by peer")
    s.add chunk
  toBytes(s)

proc sendRaw(c: TlsConn, b: Bytes) = c.sock.send(toStr(b))

proc writeRecord(c: TlsConn, ctype: uint8, data: Bytes) =
  var off = 0
  while true:
    let n = min(16384, data.len - off)
    let frag = data[off ..< off + n]
    var rec: Bytes
    if not c.wr.active or ctype == ctChangeCipherSpec:
      rec.u8(int(ctype)); rec.u16(0x0303); rec.vec16(frag)
    else:
      var inner = frag
      inner.add ctype
      let ctLen = inner.len + 16
      var hdr: Bytes
      hdr.u8(int(ctAppData)); hdr.u16(0x0303); hdr.u16(ctLen)
      let nonce = c.wr.nonceFor()
      let sealed = if c.wr.suite == suiteChaCha: chachaPolySeal(c.wr.key, nonce, hdr, inner)
                   else: aesGcmSeal(c.wr.key, nonce, hdr, inner)
      inc c.wr.seq
      rec = hdr
      rec.add sealed
    c.sendRaw(rec)
    off += n
    if off >= data.len: break

proc sendAlert*(c: TlsConn, desc: uint8) =
  try: c.writeRecord(ctAlert, @[(if desc == alCloseNotify: 1'u8 else: 2'u8), desc])
  except CatchableError: discard

proc readRecord(c: TlsConn): (uint8, Bytes) =
  let hdr = c.recvExact(5)
  let ctype = hdr[0]
  let length = (int(hdr[3]) shl 8) or int(hdr[4])
  if length > 16384 + 256: tlsFail(alRecordOverflow, "record too large")
  let body = c.recvExact(length)
  if ctype == ctChangeCipherSpec:
    if body != @[1'u8]: tlsFail(alUnexpectedMessage, "bad change_cipher_spec")
    return (ctype, body)
  if not c.rd.active:
    if ctype == ctAppData: tlsFail(alUnexpectedMessage, "encrypted record before keys")
    return (ctype, body)
  if ctype != ctAppData: 
    if ctype == ctAlert: return (ctype, body)
    tlsFail(alUnexpectedMessage, "plaintext record after keys established")
  var ok: bool
  let nonce = c.rd.nonceFor()
  let pt = if c.rd.suite == suiteChaCha: chachaPolyOpen(c.rd.key, nonce, hdr, body, ok)
           else: aesGcmOpen(c.rd.key, nonce, hdr, body, ok)
  if not ok: tlsFail(alBadRecordMac, "record authentication failed")
  inc c.rd.seq
  var i = pt.len - 1
  while i >= 0 and pt[i] == 0: dec i
  if i < 0: tlsFail(alUnexpectedMessage, "record with no content type")
  (pt[i], pt[0 ..< i])

proc handleAlert(c: TlsConn, body: Bytes) =
  if body.len != 2: tlsFail(alDecodeError, "bad alert")
  if body[1] == alCloseNotify:
    c.peerClosed = true
    return
  tlsFail(body[1], "peer sent fatal alert " & $body[1])

proc readHandshake(c: TlsConn): (uint8, Bytes, Bytes) =
  ## Returns (type, body, full encoded message).
  while c.hsBuf.len < 4 or c.hsBuf.len < 4 + ((int(c.hsBuf[1]) shl 16) or (int(c.hsBuf[2]) shl 8) or int(c.hsBuf[3])):
    let (t, d) = c.readRecord()
    case t
    of ctHandshake: c.hsBuf.add d
    of ctChangeCipherSpec: discard    # middlebox-compatibility record, ignored
    of ctAlert:
      c.handleAlert(d)
      if c.peerClosed: tlsFail(alUnexpectedMessage, "peer closed during handshake")
    else: tlsFail(alUnexpectedMessage, "expected handshake record, got type " & $t)
  let n = (int(c.hsBuf[1]) shl 16) or (int(c.hsBuf[2]) shl 8) or int(c.hsBuf[3])
  let full = c.hsBuf[0 ..< 4 + n]
  c.hsBuf = c.hsBuf[4 + n .. ^1]
  (full[0], full[4 .. ^1], full)

proc hsMsg(t: uint8, body: Bytes): Bytes =
  result.u8(int(t)); result.vec24(body)

proc sendHandshake(c: TlsConn, t: uint8, body: Bytes) =
  let m = hsMsg(t, body)
  c.transcript.add m
  c.writeRecord(ctHandshake, m)

proc requireKeyBoundary(c: TlsConn) =
  if c.hsBuf.len != 0: tlsFail(alUnexpectedMessage, "handshake data spans a key change")

proc finishedMac(base: Bytes, th: Bytes): Bytes =
  hmacSha256(expandLabel(base, "finished", @[], 32), th)

proc certVerifyContent(th: Bytes, server: bool): Bytes =
  for i in 0 ..< 64: result.add 0x20
  result.add toBytes(if server: "TLS 1.3, server CertificateVerify" else: "TLS 1.3, client CertificateVerify")
  result.add 0
  result.add th

# ---------------------------------------------------------------- application data
proc processPostHandshake(c: TlsConn, d: Bytes) =
  c.hsBuf.add d
  while c.hsBuf.len >= 4:
    let n = (int(c.hsBuf[1]) shl 16) or (int(c.hsBuf[2]) shl 8) or int(c.hsBuf[3])
    if c.hsBuf.len < 4 + n: break
    let t = c.hsBuf[0]
    let body = c.hsBuf[4 ..< 4 + n]
    c.hsBuf = c.hsBuf[4 + n .. ^1]
    case t
    of hsNewSessionTicket:
      c.log("<- NewSessionTicket (" & $n & " bytes, not used: no resumption)")
    of hsKeyUpdate:
      if body.len != 1 or body[0] > 1: tlsFail(alDecodeError, "bad KeyUpdate")
      c.requireKeyBoundary()
      c.rd.setKeys(c.suite, expandLabel(c.rd.secret, "traffic upd", @[], 32))
      inc c.keyUpdatesReceived
      c.log("<- KeyUpdate(update_requested=" & $body[0] & "): read keys rotated")
      if body[0] == 1:
        c.writeRecord(ctHandshake, hsMsg(hsKeyUpdate, @[0'u8]))
        c.wr.setKeys(c.suite, expandLabel(c.wr.secret, "traffic upd", @[], 32))
        c.log("-> KeyUpdate(update_not_requested): write keys rotated")
    else:
      tlsFail(alUnexpectedMessage, "unexpected post-handshake message " & $t)

proc read*(c: TlsConn): Bytes =
  ## Next chunk of application data; empty once the peer has closed.
  if c.appBuf.len > 0:
    result = c.appBuf; c.appBuf = @[]; return
  while not c.peerClosed:
    var t: uint8
    var d: Bytes
    try:
      (t, d) = c.readRecord()
    except TlsError as e:
      if e.msg == "connection closed by peer":
        c.peerClosed = true; return
      raise
    case t
    of ctAppData: return d
    of ctHandshake: c.processPostHandshake(d)
    of ctAlert: c.handleAlert(d)
    else: tlsFail(alUnexpectedMessage, "unexpected record type " & $t)

proc readAll*(c: TlsConn): Bytes =
  while true:
    let d = c.read()
    if d.len == 0 and c.peerClosed: break
    result.add d

proc write*(c: TlsConn, data: Bytes) = c.writeRecord(ctAppData, data)
proc write*(c: TlsConn, s: string) = c.write(toBytes(s))

proc requestKeyUpdate*(c: TlsConn) =
  c.writeRecord(ctHandshake, hsMsg(hsKeyUpdate, @[1'u8]))
  c.wr.setKeys(c.suite, expandLabel(c.wr.secret, "traffic upd", @[], 32))
  c.log("-> KeyUpdate(update_requested): write keys rotated")

proc close*(c: TlsConn) =
  c.sendAlert(alCloseNotify)
  c.sock.close()

# ---------------------------------------------------------------- extensions
proc ext(b: var Bytes, typ: uint16, data: Bytes) =
  b.u16(int(typ)); b.vec16(data)

proc parseExts(data: Bytes): seq[(uint16, Bytes)] =
  var r = rdr(data)
  var seen: seq[uint16]
  while r.left > 0:
    let t = uint16(r.r16)
    if t in seen: tlsFail(alIllegalParameter, "duplicate extension " & $t)
    seen.add t
    result.add (t, r.rv16)

proc find(exts: seq[(uint16, Bytes)], t: uint16): (bool, Bytes) =
  for (k, v) in exts:
    if k == t: return (true, v)
  (false, @[])

# ---------------------------------------------------------------- client
proc buildClientHello(host: string, pub: Bytes, random, sessionId: Bytes,
                      suites: seq[uint16]): Bytes =
  var b: Bytes
  b.u16(0x0303)
  b.add random
  b.vec8(sessionId)
  var cs: Bytes
  for s in suites: cs.u16(int(s))
  b.vec16(cs)
  b.vec8(@[0'u8])
  var exts: Bytes
  if host.len > 0 and not host.isIpAddress:
    var sni: Bytes
    var entry: Bytes
    entry.u8(0); entry.vec16(toBytes(host))
    sni.vec16(entry)
    exts.ext(extServerName, sni)
  var groups: Bytes
  groups.vec16(@[0x00'u8, 0x1d])
  exts.ext(extSupportedGroups, groups)
  var sigs: Bytes
  sigs.vec16(@[0x08'u8, 0x07])
  exts.ext(extSigAlgs, sigs)
  var alpn, proto: Bytes
  proto.vec8(toBytes("http/1.1"))
  alpn.vec16(proto)
  exts.ext(extAlpn, alpn)
  exts.ext(extSupportedVersions, @[2'u8, 0x03, 0x04])
  var ks, share: Bytes
  share.u16(int(groupX25519)); share.vec16(pub)
  ks.vec16(share)
  exts.ext(extKeyShare, ks)
  b.vec16(exts)
  hsMsg(hsClientHello, b)

proc clientHandshake*(c: TlsConn, host: string, anchors: seq[Cert], verify = true,
                      suites = @[suiteChaCha, suiteAes128Gcm]) =
  c.role = rClient
  c.serverName = host
  let priv = randomBytes(32)
  let pub = x25519Base(priv)
  c.clientRandom = randomBytes(32)
  let sessionId = randomBytes(32)
  let ch = buildClientHello(host, pub, c.clientRandom, sessionId, suites)
  c.transcript.add ch
  c.writeRecord(ctHandshake, ch)
  c.log("-> ClientHello (suites: " & suites.mapIt(suiteName(it)).join(", ") & "; X25519 key share; Ed25519 signatures)")

  # ServerHello
  let (t, body, full) = c.readHandshake()
  if t != hsServerHello: tlsFail(alUnexpectedMessage, "expected ServerHello")
  var r = rdr(body)
  if r.r16 != 0x0303: tlsFail(alProtocolVersion, "bad legacy_version")
  let srvRandom = r.take(32)
  if hex(srvRandom) == hrrRandom:
    tlsFail(alHandshakeFailure, "server sent HelloRetryRequest but we only speak X25519")
  if srvRandom[24 ..< 32] == toBytes("DOWNGRD\x01") or srvRandom[24 ..< 32] == toBytes("DOWNGRD\x00"):
    tlsFail(alIllegalParameter, "downgrade sentinel in ServerHello")
  if r.rv8 != sessionId: tlsFail(alIllegalParameter, "session id not echoed")
  let suite = uint16(r.r16)
  if suite notin suites: tlsFail(alIllegalParameter, "server chose a suite we did not offer")
  if r.r8 != 0: tlsFail(alIllegalParameter, "compression")
  let exts = parseExts(r.rv16)
  r.done()
  let (hasV, v) = exts.find(extSupportedVersions)
  if not hasV or v != @[0x03'u8, 0x04]: tlsFail(alProtocolVersion, "server did not negotiate TLS 1.3")
  let (hasK, ksd) = exts.find(extKeyShare)
  if not hasK: tlsFail(alMissingExtension, "no key_share in ServerHello")
  var kr = rdr(ksd)
  if uint16(kr.r16) != groupX25519: tlsFail(alIllegalParameter, "server picked a group we did not offer")
  let srvPub = kr.rv16
  kr.done()
  if srvPub.len != 32: tlsFail(alIllegalParameter, "bad X25519 share")
  c.transcript.add full
  c.suite = suite
  c.log("<- ServerHello (" & suiteName(suite) & ", X25519)")

  let shared = x25519(priv, srvPub)
  if shared == newSeq[byte](32): tlsFail(alIllegalParameter, "X25519 produced the all-zero secret")
  let early = hkdfExtract(@[], newSeq[byte](32))
  let hs = hkdfExtract(deriveSecret(early, "derived", sha256(@[])), shared)
  let thSH = c.thash()
  let cHs = deriveSecret(hs, "c hs traffic", thSH)
  let sHs = deriveSecret(hs, "s hs traffic", thSH)
  c.keylogLine("CLIENT_HANDSHAKE_TRAFFIC_SECRET", cHs)
  c.keylogLine("SERVER_HANDSHAKE_TRAFFIC_SECRET", sHs)
  c.requireKeyBoundary()
  c.rd.setKeys(suite, sHs)
  c.log("   handshake keys derived; everything from here on is encrypted")

  # EncryptedExtensions
  var (t2, b2, f2) = c.readHandshake()
  if t2 != hsEncryptedExtensions: tlsFail(alUnexpectedMessage, "expected EncryptedExtensions")
  var er = rdr(b2)
  let ee = parseExts(er.rv16)
  er.done()
  let (hasA, ad) = ee.find(extAlpn)
  if hasA:
    var ar = rdr(ad)
    var pl = rdr(ar.rv16)
    c.alpn = toStr(pl.rv8)
  c.transcript.add f2
  c.log("<- EncryptedExtensions (" & $ee.len & " extensions" & (if c.alpn.len > 0: ", ALPN " & c.alpn else: "") & ")")

  # Certificate
  var (t3, b3, f3) = c.readHandshake()
  if t3 == hsCertificateRequest: tlsFail(alHandshakeFailure, "client certificates are not supported")
  if t3 != hsCertificate: tlsFail(alUnexpectedMessage, "expected Certificate")
  var cr = rdr(b3)
  if cr.rv8.len != 0: tlsFail(alIllegalParameter, "non-empty certificate_request_context")
  var lr = rdr(cr.rv24)
  cr.done()
  while lr.left > 0:
    let der = lr.rv24
    discard lr.rv16
    try: c.peerChain.add parseCert(der)
    except X509Error as e: tlsFail(alBadCertificate, "certificate parse error: " & e.msg)
  if c.peerChain.len == 0: tlsFail(alBadCertificate, "server sent no certificate")
  c.transcript.add f3
  c.log("<- Certificate (" & $c.peerChain.len & (if c.peerChain.len == 1: " cert" else: " certs") & ", leaf CN=" & c.peerChain[0].subjectCN & ")")
  if verify:
    let why = verifyChain(c.peerChain, anchors, host)
    if why.len > 0: tlsFail(alBadCertificate, "certificate verification failed: " & why)
    c.log("   chain verified: " & c.peerChain[0].subjectCN & " <- " & c.peerChain[^1].issuerCN & " (trusted)")

  # CertificateVerify
  let thCert = c.thash()
  var (t4, b4, f4) = c.readHandshake()
  if t4 != hsCertificateVerify: tlsFail(alUnexpectedMessage, "expected CertificateVerify")
  var vr = rdr(b4)
  let alg = uint16(vr.r16)
  let sig = vr.rv16
  vr.done()
  if alg != sigEd25519: tlsFail(alIllegalParameter, "unsupported signature algorithm")
  if c.peerChain[0].pubKey.len != 32 or
     not ed25519Verify(c.peerChain[0].pubKey, certVerifyContent(thCert, true), sig):
    tlsFail(alDecryptError, "CertificateVerify signature is invalid")
  c.transcript.add f4
  c.log("<- CertificateVerify (Ed25519 signature over transcript: valid)")

  # Server Finished
  let thCv = c.thash()
  var (t5, b5, f5) = c.readHandshake()
  if t5 != hsFinished: tlsFail(alUnexpectedMessage, "expected Finished")
  if not ctEqual(b5, finishedMac(sHs, thCv)): tlsFail(alDecryptError, "server Finished MAC is wrong")
  c.transcript.add f5
  c.log("<- Finished (MAC verified)")

  let master = hkdfExtract(deriveSecret(hs, "derived", sha256(@[])), newSeq[byte](32))
  let thSF = c.thash()
  let cAp = deriveSecret(master, "c ap traffic", thSF)
  let sAp = deriveSecret(master, "s ap traffic", thSF)
  c.keylogLine("CLIENT_TRAFFIC_SECRET_0", cAp)
  c.keylogLine("SERVER_TRAFFIC_SECRET_0", sAp)

  c.writeRecord(ctChangeCipherSpec, @[1'u8])
  c.wr.setKeys(suite, cHs)
  c.sendHandshake(hsFinished, finishedMac(cHs, thSF))
  c.log("-> Finished")
  c.requireKeyBoundary()
  c.rd.setKeys(suite, sAp)
  c.wr.setKeys(suite, cAp)
  c.log("   application keys installed - handshake complete")

proc connect*(host: string, port: int, anchors: seq[Cert], verify = true,
              trace: proc (s: string) = nil, keylog: File = nil,
              suites = @[suiteChaCha, suiteAes128Gcm]): TlsConn =
  let s = newSocket(buffered = false)
  s.connect(host, Port(port))
  result = TlsConn(sock: s, trace: trace, keylog: keylog)
  try:
    result.clientHandshake(host, anchors, verify, suites)
  except TlsError as e:
    result.sendAlert(e.alert)
    s.close()
    raise

# ---------------------------------------------------------------- server
type ServerConfig* = object
  chain*: seq[Bytes]        # DER certificates, leaf first
  seed*: Bytes              # Ed25519 private key seed
  suites*: seq[uint16]      # server preference order

proc serverHandshake*(c: TlsConn, cfg: ServerConfig) =
  c.role = rServer
  var (t, body, full) = c.readHandshake()
  if t != hsClientHello: tlsFail(alUnexpectedMessage, "expected ClientHello")
  var priorHash: Bytes
  var clientShare: Bytes
  var sessionId: Bytes
  var suite: uint16
  for attempt in 0 .. 1:
    var r = rdr(body)
    discard r.r16
    let random = r.take(32)
    if attempt == 0: c.clientRandom = random
    sessionId = r.rv8
    var sr = rdr(r.rv16)
    var offered: seq[uint16]
    while sr.left > 0: offered.add uint16(sr.r16)
    let comp = r.rv8
    if comp != @[0'u8]: tlsFail(alIllegalParameter, "compression offered")
    let exts = parseExts(r.rv16)
    r.done()
    let (hasV, v) = exts.find(extSupportedVersions)
    var tls13 = false
    if hasV:
      var vr = rdr(v)
      var vl = rdr(vr.rv8)
      while vl.left > 0:
        if vl.r16 == 0x0304: tls13 = true
    if not tls13: tlsFail(alProtocolVersion, "client does not support TLS 1.3")
    suite = 0
    for s in cfg.suites:
      if s in offered: suite = s; break
    if suite == 0: tlsFail(alHandshakeFailure, "no shared cipher suite")
    let (hasS, sd) = exts.find(extSigAlgs)
    var edOk = false
    if hasS:
      var a = rdr(sd)
      var al = rdr(a.rv16)
      while al.left > 0:
        if uint16(al.r16) == sigEd25519: edOk = true
    if not edOk: tlsFail(alHandshakeFailure, "client does not accept Ed25519 signatures")
    let (hasSni, sni) = exts.find(extServerName)
    if hasSni:
      var a = rdr(sni)
      var l = rdr(a.rv16)
      if l.r8 == 0: c.serverName = toStr(l.rv16)
    let (hasAlpn, alpnD) = exts.find(extAlpn)
    if hasAlpn:
      var a = rdr(alpnD)
      var l = rdr(a.rv16)
      while l.left > 0:
        if toStr(l.rv8) == "http/1.1": c.alpn = "http/1.1"
    let (hasG, gd) = exts.find(extSupportedGroups)
    var groupOk = false
    if hasG:
      var a = rdr(gd)
      var l = rdr(a.rv16)
      while l.left > 0:
        if uint16(l.r16) == groupX25519: groupOk = true
    if not groupOk: tlsFail(alHandshakeFailure, "client does not support X25519")
    let (hasK, kd) = exts.find(extKeyShare)
    if not hasK: tlsFail(alMissingExtension, "no key_share")
    var a = rdr(kd)
    var l = rdr(a.rv16)
    clientShare = @[]
    var groupsSent: seq[int]
    while l.left > 0:
      let g = l.r16
      let k = l.rv16
      groupsSent.add g
      if uint16(g) == groupX25519: clientShare = k
    c.log("<- ClientHello" & (if attempt == 1: " #2" else: "") & " (SNI=" & c.serverName &
          ", " & $offered.len & " suites, key shares for groups " & groupsSent.mapIt("0x" & toHex(it, 4)).join(",") & ")")
    if clientShare.len == 32:
      c.transcript.add priorHash
      c.transcript.add full
      break
    if attempt == 1: tlsFail(alIllegalParameter, "second ClientHello still lacks an X25519 share")
    # HelloRetryRequest: ask for an X25519 share.  The transcript restarts
    # with a synthetic message_hash(ClientHello1) message (RFC 8446 4.4.1).
    priorHash = @[hsMessageHash, 0, 0, 32]
    priorHash.add sha256(full)
    var hrr: Bytes
    hrr.u16(0x0303)
    hrr.add unhex(hrrRandom)
    hrr.vec8(sessionId)
    hrr.u16(int(suite))
    hrr.u8(0)
    var e: Bytes
    e.ext(extSupportedVersions, @[0x03'u8, 0x04])
    e.ext(extKeyShare, @[0x00'u8, 0x1d])
    hrr.vec16(e)
    let hrrMsg = hsMsg(hsServerHello, hrr)
    priorHash.add hrrMsg
    c.writeRecord(ctHandshake, hrrMsg)
    if sessionId.len > 0: c.writeRecord(ctChangeCipherSpec, @[1'u8])
    c.hrrSent = true
    c.log("-> HelloRetryRequest (no X25519 share offered; asking for one)")
    (t, body, full) = c.readHandshake()
    if t != hsClientHello: tlsFail(alUnexpectedMessage, "expected second ClientHello")

  c.suite = suite
  let priv = randomBytes(32)
  let pub = x25519Base(priv)
  var sh: Bytes
  sh.u16(0x0303)
  sh.add randomBytes(32)
  sh.vec8(sessionId)
  sh.u16(int(suite))
  sh.u8(0)
  var e: Bytes
  e.ext(extSupportedVersions, @[0x03'u8, 0x04])
  var ks: Bytes
  ks.u16(int(groupX25519)); ks.vec16(pub)
  e.ext(extKeyShare, ks)
  sh.vec16(e)
  c.sendHandshake(hsServerHello, sh)
  if sessionId.len > 0 and not c.hrrSent: c.writeRecord(ctChangeCipherSpec, @[1'u8])
  c.log("-> ServerHello (" & suiteName(suite) & ", X25519)")

  let shared = x25519(priv, clientShare)
  if shared == newSeq[byte](32): tlsFail(alIllegalParameter, "X25519 produced the all-zero secret")
  let early = hkdfExtract(@[], newSeq[byte](32))
  let hs = hkdfExtract(deriveSecret(early, "derived", sha256(@[])), shared)
  let thSH = c.thash()
  let cHs = deriveSecret(hs, "c hs traffic", thSH)
  let sHs = deriveSecret(hs, "s hs traffic", thSH)
  c.keylogLine("CLIENT_HANDSHAKE_TRAFFIC_SECRET", cHs)
  c.keylogLine("SERVER_HANDSHAKE_TRAFFIC_SECRET", sHs)
  c.requireKeyBoundary()
  c.wr.setKeys(suite, sHs)
  c.rd.setKeys(suite, cHs)

  var ee, eexts: Bytes
  if c.alpn.len > 0:
    var pl, al: Bytes
    pl.vec8(toBytes(c.alpn)); al.vec16(pl)
    eexts.ext(extAlpn, al)
  ee.vec16(eexts)
  c.sendHandshake(hsEncryptedExtensions, ee)
  var cert, list: Bytes
  cert.vec8(@[])
  for d in cfg.chain:
    list.vec24(d); list.u16(0)
  cert.vec24(list)
  c.sendHandshake(hsCertificate, cert)
  var cv: Bytes
  cv.u16(int(sigEd25519))
  cv.vec16(ed25519Sign(cfg.seed, certVerifyContent(c.thash(), true)))
  c.sendHandshake(hsCertificateVerify, cv)
  c.sendHandshake(hsFinished, finishedMac(sHs, c.thash()))
  c.log("-> EncryptedExtensions, Certificate (" & $cfg.chain.len & "), CertificateVerify (Ed25519), Finished")

  let master = hkdfExtract(deriveSecret(hs, "derived", sha256(@[])), newSeq[byte](32))
  let thSF = c.thash()
  let cAp = deriveSecret(master, "c ap traffic", thSF)
  let sAp = deriveSecret(master, "s ap traffic", thSF)
  c.keylogLine("CLIENT_TRAFFIC_SECRET_0", cAp)
  c.keylogLine("SERVER_TRAFFIC_SECRET_0", sAp)
  c.wr.setKeys(suite, sAp)

  var (t6, b6, f6) = c.readHandshake()
  if t6 == hsCertificate: tlsFail(alUnexpectedMessage, "unsolicited client certificate")
  if t6 != hsFinished: tlsFail(alUnexpectedMessage, "expected client Finished")
  if not ctEqual(b6, finishedMac(cHs, thSF)): tlsFail(alDecryptError, "client Finished MAC is wrong")
  c.transcript.add f6
  c.requireKeyBoundary()
  c.rd.setKeys(suite, cAp)
  c.log("<- Finished (MAC verified) - handshake complete")

proc accept*(s: Socket, cfg: ServerConfig, trace: proc (s: string) = nil, keylog: File = nil): TlsConn =
  var client: Socket
  s.accept(client)
  result = TlsConn(sock: client, trace: trace, keylog: keylog)
  try:
    result.serverHandshake(cfg)
  except TlsError as e:
    result.sendAlert(e.alert)
    client.close()
    raise

proc loadServerConfig*(certFile, keyFile: string): ServerConfig =
  result.chain = pemDecode(readFile(certFile), "CERTIFICATE")
  if result.chain.len == 0: raise newException(ValueError, "no certificates in " & certFile)
  let keys = pemDecode(readFile(keyFile), "PRIVATE KEY")
  if keys.len == 0: raise newException(ValueError, "no PRIVATE KEY in " & keyFile)
  result.seed = ed25519SeedFromPkcs8(keys[0])
  let leaf = parseCert(result.chain[0])
  if leaf.pubKey != ed25519PublicKey(result.seed):
    raise newException(ValueError, "private key does not match the leaf certificate")
  result.suites = @[suiteChaCha, suiteAes128Gcm]

proc loadAnchors*(file: string): seq[Cert] =
  for d in pemDecode(readFile(file), "CERTIFICATE"): result.add parseCert(d)
