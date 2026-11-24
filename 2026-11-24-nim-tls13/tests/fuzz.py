#!/usr/bin/env python3
"""Differential fuzzer: wren's primitives vs pyca/cryptography (backed by OpenSSL)."""
import hashlib, hmac, os, random, subprocess, sys
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305, AESGCM
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.exceptions import InvalidSignature

N = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
rb = lambda n: bytes(rng.getrandbits(8) for _ in range(n))
h = lambda b: b.hex() if b else "-"
def rlen():  # bias toward block / limb boundaries
    return rng.choice([0, 1, 15, 16, 17, 31, 32, 33, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129, rng.randrange(0, 3000)])

cases = []   # (category, line, expected)
for _ in range(N):
    m = rb(rlen())
    cases.append(("sha256", f"sha256 {h(m)}", hashlib.sha256(m).hexdigest() ))
    cases.append(("sha512", f"sha512 {h(m)}", hashlib.sha512(m).hexdigest()))
    k = rb(rlen())
    cases.append(("hmac", f"hmac {h(k)} {h(m)}", hmac.new(k, m, hashlib.sha256).hexdigest()))
    salt, info, L = rb(rng.randrange(1, 80)), rb(rng.randrange(0, 60)), rng.randrange(1, 255 * 32 // 8)
    exp = HKDF(hashes.SHA256(), L, salt, info).derive(m)
    cases.append(("hkdf", f"hkdf {h(salt)} {h(m)} {h(info)} {L:04x}", exp.hex()))
    key, nonce, aad = rb(32), rb(12), rb(rng.choice([0, 5, 13, 16, 40]))
    ct = ChaCha20Poly1305(key).encrypt(nonce, m, aad)
    cases.append(("chacha20poly1305", f"chacha {h(key)} {h(nonce)} {h(aad)} {h(m)}", ct.hex()))
    bad = bytearray(ct); bad[rng.randrange(len(bad))] ^= 1 << rng.randrange(8)
    cases.append(("chacha20poly1305", f"chachaopen {h(key)} {h(nonce)} {h(aad)} {h(bytes(bad))}", "FAIL"))
    cases.append(("chacha20poly1305", f"chachaopen {h(key)} {h(nonce)} {h(aad)} {h(ct)}", h(m)))
    k16 = rb(16)
    g = AESGCM(k16).encrypt(nonce, m, aad)
    cases.append(("aes128gcm", f"gcm {h(k16)} {h(nonce)} {h(aad)} {h(m)}", g.hex()))
    bad = bytearray(g); bad[rng.randrange(len(bad))] ^= 1 << rng.randrange(8)
    cases.append(("aes128gcm", f"gcmopen {h(k16)} {h(nonce)} {h(aad)} {h(bytes(bad))}", "FAIL"))
    a, b = rb(32), rb(32)
    b_pub = X25519PrivateKey.from_private_bytes(b).public_key().public_bytes_raw()
    shared = X25519PrivateKey.from_private_bytes(a).exchange(X25519PublicKey.from_public_bytes(b_pub))
    cases.append(("x25519", f"x25519 {h(a)} {h(b_pub)}", shared.hex()))
    # non-canonical / high-bit u-coordinates must be handled per RFC 7748 (mask bit 255)
    u = bytearray(rb(32)); u[31] |= 0x80
    try:
        exp = X25519PrivateKey.from_private_bytes(a).exchange(X25519PublicKey.from_public_bytes(bytes(u))).hex()
        cases.append(("x25519", f"x25519 {h(a)} {h(bytes(u))}", exp))
    except ValueError:
        pass   # low-order point -> all-zero output rejected by OpenSSL
    seed = rb(32)
    sk = Ed25519PrivateKey.from_private_bytes(seed)
    pk = sk.public_key().public_bytes_raw()
    sig = sk.sign(m)
    cases.append(("ed25519", f"edpub {h(seed)}", pk.hex()))
    cases.append(("ed25519", f"edsign {h(seed)} {h(m)}", sig.hex()))
    # verification of valid, bit-flipped, and S+L (malleable) signatures
    flipped = bytearray(sig); flipped[rng.randrange(64)] ^= 1 << rng.randrange(8)
    for s in (sig, bytes(flipped)):
        try: Ed25519PublicKey.from_public_bytes(pk).verify(s, m); want = "01"
        except InvalidSignature: want = "00"
        cases.append(("ed25519", f"edverify {h(pk)} {h(m)} {h(s)}", want))
    S = int.from_bytes(sig[32:], "little") + (2**252 + 27742317777372353535851937790883648493)
    if S < 2**256:
        mall = sig[:32] + S.to_bytes(32, "little")
        cases.append(("ed25519", f"edverify {h(pk)} {h(m)} {h(mall)}", "00"))

p = subprocess.run([sys.argv[1]], input="\n".join(c[1] for c in cases) + "\n",
                   capture_output=True, text=True, check=True)
got = p.stdout.split("\n")
stats, fails = {}, 0
for (cat, line, want), g in zip(cases, got):
    ok = g == want
    stats.setdefault(cat, [0, 0])[0 if ok else 1] += 1
    if not ok:
        fails += 1
        if fails <= 5: print("MISMATCH", line[:120], "\n  got ", g[:80], "\n  want", want[:80])
for cat, (ok, bad) in sorted(stats.items()):
    print(f"  {cat:<18} {ok:>7} agree  {bad:>3} differ")
print(f"total {len(cases)} cases, {fails} mismatches")
sys.exit(1 if fails else 0)
