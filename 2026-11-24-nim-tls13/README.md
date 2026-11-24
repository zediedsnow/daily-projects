# wren: TLS 1.3 from scratch in Nim

**wren** is a TLS 1.3 client and HTTPS server written from scratch in about 1,850 lines of Nim. Every
primitive under it is hand-written too: SHA-256/512, HMAC, HKDF, ChaCha20-Poly1305, AES-128-GCM,
X25519, Ed25519, a DER/X.509 parser and a certificate-chain verifier. There are no dependencies
outside Nim's standard library, which supplies sockets and `urandom`.

It is fully interoperable with real implementations. **curl** and **`openssl s_client`** connect to
`wren serve` and verify its certificate chain. `wren get` talks to **`openssl s_server`**. In both
directions the two sides derive byte-identical traffic secrets.

```
$ wren get https://localhost:4433/ --cafile=demo/ca.pem -v --keyupdate --head      # against openssl s_server
  -> ClientHello (suites: TLS_CHACHA20_POLY1305_SHA256, TLS_AES_128_GCM_SHA256; X25519 key share; Ed25519 signatures)
  <- ServerHello (TLS_CHACHA20_POLY1305_SHA256, X25519)
     handshake keys derived; everything from here on is encrypted
  <- EncryptedExtensions (0 extensions)
  <- Certificate (1 cert, leaf CN=localhost)
     chain verified: localhost <- Wren Demo Root CA (trusted)
  <- CertificateVerify (Ed25519 signature over transcript: valid)
  <- Finished (MAC verified)
  -> Finished
     application keys installed - handshake complete
  handshake took 9.29 ms
  -> KeyUpdate(update_requested): write keys rotated
  <- NewSessionTicket (213 bytes, not used: no resumption)
  <- NewSessionTicket (213 bytes, not used: no resumption)
  <- KeyUpdate(update_requested=0): read keys rotated
HTTP/1.0 200 ok
Content-type: text/html
```

```
$ wren serve --cert=demo/chain.pem --key=demo/server.key -v &
$ curl --cacert demo/ca.pem --curves P-256:X25519 https://localhost:8443/    # curl leads with a P-256 key share
  <- ClientHello (SNI=localhost, 31 suites, key shares for groups 0x0017)
  -> HelloRetryRequest (no X25519 share offered; asking for one)
  <- ClientHello #2 (SNI=localhost, 31 suites, key shares for groups 0x001D)
  -> ServerHello (TLS_CHACHA20_POLY1305_SHA256, X25519)
  -> EncryptedExtensions, Certificate (2), CertificateVerify (Ed25519), Finished
  <- Finished (MAC verified) - handshake complete
wren: GET / HTTP/1.1 -> 200 (775 bytes, TLS_CHACHA20_POLY1305_SHA256)
curl: HTTP 200, verify=0
```

## Why it's interesting

TLS is the protocol people most often tell you never to write yourself, and that's good advice for
production. The point of writing it anyway is to see that no single piece is magic. The whole
handshake is a transcript hash fed through an HKDF ladder, a Diffie-Hellman exchange, and one
signature. Each primitive fits in one screen of code. What makes it hard is getting every byte exactly
right, because one wrong label, length prefix or nonce makes OpenSSL hang up with `bad_record_mac`.
For that reason the project is mostly tests.

## Results

| Check | Result |
|---|---|
| RFC / FIPS known-answer vectors (FIPS 180-4, RFC 4231, 5869, 8439, 7748 incl. 1,000-iteration ladder, 8032, GCM spec) | **33 / 33** |
| Differential fuzz of every primitive vs pyca/cryptography (OpenSSL), 80,000 cases incl. tampered ciphertexts, bit-flipped and malleable (S+L) Ed25519 signatures, high-bit X25519 inputs | **0 mismatches** |
| `wren get` → `openssl s_server`, both suites, with KeyUpdate in both directions | ✅ |
| Traffic secrets in wren's `SSLKEYLOGFILE` vs OpenSSL's `-keylogfile`, same connection | **byte-identical** |
| `openssl s_client` / `curl` → `wren serve`, both suites, chain verified, 1 MB body SHA-256 checked | ✅ |
| HelloRetryRequest (client leads with P-256), client-initiated KeyUpdate from OpenSSL | ✅ |
| TLS 1.2-only and non-X25519 clients refused with proper alerts | ✅ |
| Cert validation: good / multi-SAN / 3-cert chain with intermediate accepted. Wrong host, expired, not-yet-valid, untrusted root, tampered signature, non-CA intermediate rejected | **9 / 9** |
| 5,000 mutated ClientHellos thrown at the server | no crashes, no hangs; every one answered with an alert or a ServerHello |

Throughput over loopback (wren ↔ wren, 20 MB): ChaCha20-Poly1305 ≈ 46 MB/s, AES-128-GCM ≈ 16 MB/s.
AES is slower because it uses a portable byte-wise AES and a bit-serial GHASH, not AES-NI or PCLMUL.

## Build and run

Requires Nim ≥ 1.6 (`apt install nim`). The tests also need `openssl`, `curl`, and Python 3 with
`cryptography`.

```bash
make                 # builds ./wren
make certs           # Ed25519 demo root CA + localhost leaf (demo/*.pem, demo/server.key)
./wren serve --cert=demo/chain.pem --key=demo/server.key -v            # https://localhost:8443/
curl --cacert demo/ca.pem https://localhost:8443/
./wren get https://localhost:8443/ --cafile=demo/ca.pem -v [--suite=aes] [--keyupdate] [--keylog=keys.txt]
make test            # vectors + 32k-case differential fuzz + 26-case interop matrix + ClientHello fuzz
```

`--keylog` writes the standard NSS key log format, so Wireshark can decrypt a capture of wren's traffic.

## How it works

```
src/sha2.nim        SHA-256 (streaming), SHA-512, HMAC-SHA256, HKDF, constant-time compare
src/chacha.nim      ChaCha20 block function, Poly1305 (26-bit limbs, constant-time final reduce), AEAD
src/aesgcm.nim      AES-128 (S-box computed at compile time from GF(2^8) inverses), GHASH, GCM
src/curve25519.nim  GF(2^255-19) with 16x16-bit limbs; X25519 Montgomery ladder; Ed25519 sign/verify
src/x509.nim        strict DER reader, X.509 fields + SAN/basicConstraints, PEM, PKCS#8, path building
src/tls13.nim       record layer, key schedule, client + server state machines, KeyUpdate, alerts
src/wren.nim        CLI: `get` (HTTPS client) and `serve` (HTTPS server)
```

**Key schedule (RFC 8446 §7.1).** `early = HKDF-Extract(0, 0)` →
`handshake = Extract(Derive(early,"derived"), X25519 shared secret)` → client/server handshake
traffic secrets over `Hash(ClientHello..ServerHello)` → `master = Extract(Derive(handshake,"derived"), 0)`
→ application secrets over `Hash(ClientHello..server Finished)`. Each secret expands into a key and an
IV via `HKDF-Expand-Label`. The per-record nonce is `IV XOR sequence-number`. KeyUpdate replaces a
secret with `Expand-Label(secret, "traffic upd")`. The keylog comparison against OpenSSL tests this
whole chain end to end.

**Record layer.** Once keys are installed, every record looks like `application_data` on the wire.
The real content type is the last non-zero byte of the decrypted plaintext, and the 5-byte header is
the AEAD's associated data. The code enforces RFC 8446's rule that a key change must fall on a
record boundary, so a handshake message may not straddle two keys. It also ignores the
middlebox-compatibility `change_cipher_spec` records.

**Authentication.** The server signs `64×0x20 ‖ "TLS 1.3, server CertificateVerify" ‖ 0 ‖
Hash(transcript)` with Ed25519. The client checks that signature against the leaf key, then builds a
path from the leaf to a trust anchor. It tolerates the reordered and duplicated certificates that real
servers send, checks validity periods and `basicConstraints cA`, and matches the hostname against SAN
DNS/IP entries. Finished messages are HMACs over the transcript and are compared in constant time.

**HelloRetryRequest.** If a client sends no X25519 share, the server answers with the magic
HRR random. The transcript then restarts as `message_hash(Hash(ClientHello1)) ‖ HRR ‖ ClientHello2`.
Getting that synthetic message wrong makes the client reject the server's Finished, so a successful
curl connection shows the HRR transcript is right.

**Curve25519** follows TweetNaCl's representation: sixteen signed 16-bit limbs in `int64`, carries
folded with ×38, conditional swaps done with masks. Ed25519 verification rejects non-canonical `S ≥ L`
(malleable signatures), which the fuzzer checks against OpenSSL.

A Nim gotcha that cost a test failure: `t = [f(t[1]), f(t[2]), f(t[3]), f(t[0])]` assigns in place
element by element. By the time the last element is computed, `t[0]` has already been overwritten,
which corrupted the AES key schedule. The FIPS-197 vector caught it immediately.

## Scope and limits

This is an educational stack, not a hardened one. It implements one group (X25519), one signature
scheme (Ed25519), and two cipher suites. It does not do PSK/session resumption, 0-RTT, client
certificates, or the secp256r1/RSA certificates most public websites use, so `wren get` talks to
servers with Ed25519 certificates. Browsers can't connect to `wren serve` because Chrome and Firefox
don't accept Ed25519 TLS certificates. The field and ladder arithmetic is constant-time in structure,
but the AES S-box lookups are not, so it is not safe against cache-timing attacks.
