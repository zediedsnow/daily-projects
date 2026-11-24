## Reads "op hex hex ..." lines on stdin, prints one hex result per line.
## Driven by tests/fuzz.py, which checks every answer against pyca/cryptography (OpenSSL).
import std/[strutils, sequtils]
import ../src/[sha2, chacha, aesgcm, curve25519]

for line in stdin.lines:
  let f = line.split(' ')
  let a = f[1 .. ^1].mapIt(if it == "-": newSeq[byte]() else: unhex(it))
  var ok = true
  let r = case f[0]
    of "sha256": sha256(a[0])
    of "sha512": sha512(a[0])
    of "hmac": hmacSha256(a[0], a[1])
    of "hkdf": hkdfExpand(hkdfExtract(a[0], a[1]), a[2], int(a[3][0]) * 256 + int(a[3][1]))
    of "chacha": chachaPolySeal(a[0], a[1], a[2], a[3])
    of "chachaopen": chachaPolyOpen(a[0], a[1], a[2], a[3], ok)
    of "gcm": aesGcmSeal(a[0], a[1], a[2], a[3])
    of "gcmopen": aesGcmOpen(a[0], a[1], a[2], a[3], ok)
    of "x25519": x25519(a[0], a[1])
    of "edpub": ed25519PublicKey(a[0])
    of "edsign": ed25519Sign(a[0], a[1])
    of "edverify": @[byte(ord(ed25519Verify(a[0], a[1], a[2])))]
    else: quit "bad op " & f[0]
  echo (if ok: (if r.len == 0: "-" else: hex(r)) else: "FAIL")
