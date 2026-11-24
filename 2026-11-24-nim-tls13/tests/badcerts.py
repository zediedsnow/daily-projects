#!/usr/bin/env python3
"""Builds deliberately broken Ed25519 certificate chains for the negative tests."""
import datetime as dt, ipaddress, sys, os
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
pem = lambda c: c.public_bytes(serialization.Encoding.PEM)
def key_pem(k):
    return k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())

def ca(name):
    k = Ed25519PrivateKey.generate()
    n = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    c = (x509.CertificateBuilder().subject_name(n).issuer_name(n).public_key(k.public_key())
         .serial_number(x509.random_serial_number()).not_valid_before(now - dt.timedelta(days=1))
         .not_valid_after(now + dt.timedelta(days=365))
         .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(k, None))
    return k, c

def leaf(cak, cac, names, before, after, is_ca=False):
    k = Ed25519PrivateKey.generate()
    c = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, names[0])]))
         .issuer_name(cac.subject).public_key(k.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(before).not_valid_after(after)
         .add_extension(x509.SubjectAlternativeName([x509.DNSName(n) for n in names]), critical=False)
         .add_extension(x509.BasicConstraints(ca=is_ca, path_length=None), critical=True).sign(cak, None))
    return k, c

rootk, root = ca("Good Root")
otherk, other = ca("Other Root")
open(f"{out}/root.pem", "wb").write(pem(root))
day = dt.timedelta(days=1)
def write(name, k, chain):
    open(f"{out}/{name}.key", "wb").write(key_pem(k))
    open(f"{out}/{name}.pem", "wb").write(b"".join(pem(c) for c in chain))

k, c = leaf(rootk, root, ["localhost"], now - day, now + 30 * day); write("good", k, [c, root])
k, c = leaf(rootk, root, ["example.com"], now - day, now + 30 * day); write("wronghost", k, [c, root])
k, c = leaf(rootk, root, ["localhost"], now - 30 * day, now - day); write("expired", k, [c, root])
k, c = leaf(rootk, root, ["localhost"], now + day, now + 30 * day); write("notyet", k, [c, root])
k, c = leaf(otherk, other, ["localhost"], now - day, now + 30 * day); write("untrusted", k, [c, other])
k, c = leaf(rootk, root, ["*.localhost", "localhost"], now - day, now + 30 * day); write("multisan", k, [c, root])
# intermediate that is NOT a CA signing a leaf
ik, ic = leaf(rootk, root, ["Not A CA"], now - day, now + 30 * day, is_ca=False)
k, c = leaf(ik, ic, ["localhost"], now - day, now + 30 * day); write("nonca", k, [c, ic])
# real intermediate CA (valid 3-cert chain)
ik2, ic2 = leaf(rootk, root, ["Good Intermediate"], now - day, now + 30 * day, is_ca=True)
k, c = leaf(ik2, ic2, ["localhost"], now - day, now + 30 * day); write("intermediate", k, [c, ic2])
# tampered: flip one bit inside the leaf's signed TBS (serial number) -> signature no longer matches
k, c = leaf(rootk, root, ["localhost"], now - day, now + 30 * day)
der = bytearray(c.public_bytes(serialization.Encoding.DER))
der[15] ^= 0x01
tampered = x509.load_der_x509_certificate(bytes(der))
write("tampered", k, [tampered, root])
print("wrote test chains to", out)
