## Known-answer tests from the RFCs / FIPS documents.
import ../src/[sha2, chacha, aesgcm, curve25519]

var passed, failed = 0
proc check(name: string, got, want: string) =
  if got == want: inc passed
  else:
    inc failed
    echo "FAIL ", name, "\n  got  ", got, "\n  want ", want

# FIPS 180-4
check "sha256 abc", hex(sha256(toBytes("abc"))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
check "sha256 empty", hex(sha256(newSeq[byte]())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
check "sha256 448", hex(sha256(toBytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))),
  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
var mil = newSeq[byte](1_000_000)
for i in 0 ..< mil.len: mil[i] = byte('a')
check "sha256 million a", hex(sha256(mil)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
check "sha512 abc", hex(sha512(toBytes("abc"))),
  "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
check "sha512 million a", hex(sha512(mil)),
  "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b"

# RFC 4231 case 2
check "hmac rfc4231#2", hex(hmacSha256(toBytes("Jefe"), toBytes("what do ya want for nothing?"))),
  "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
# RFC 5869 A.1
let prk = hkdfExtract(unhex("000102030405060708090a0b0c"), unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"))
check "hkdf extract", hex(prk), "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
check "hkdf expand", hex(hkdfExpand(prk, unhex("f0f1f2f3f4f5f6f7f8f9"), 42)),
  "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"

# RFC 8439 2.4.2 / 2.5.2 / 2.8.2
let ckey = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
let sunscreen = toBytes("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
check "chacha20", hex(chacha20Xor(ckey, 1, unhex("000000000000004a00000000"), sunscreen)),
  "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d"
check "poly1305", hex(poly1305(unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"), toBytes("Cryptographic Forum Research Group"))),
  "a8061dc1305136c6c22b8baf0c0127a9"
let akey = unhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
let anonce = unhex("070000004041424344454647")
let aad = unhex("50515253c0c1c2c3c4c5c6c7")
let sealed = chachaPolySeal(akey, anonce, aad, sunscreen)
check "aead tag", hex(sealed[^16 .. ^1]), "1ae10b594f09e26a7e902ecbd0600691"
var ok: bool
discard chachaPolyOpen(akey, anonce, aad, sealed, ok)
check "aead open", $ok, "true"
var tampered = sealed
tampered[5] = tampered[5] xor 1
discard chachaPolyOpen(akey, anonce, aad, tampered, ok)
check "aead reject", $ok, "false"

# FIPS 197 C.1 + GCM spec test case 4 (AES-128)
check "aes128", hex(initAes128(unhex("000102030405060708090a0b0c0d0e0f")).encryptBlock(unhex("00112233445566778899aabbccddeeff"))),
  "69c4e0d86a7b0430d8cdb78070b4c55a"
let gk = unhex("feffe9928665731c6d6a8f9467308308")
let giv = unhex("cafebabefacedbaddecaf888")
let gpt = unhex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
let gaad = unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
let gs = aesGcmSeal(gk, giv, gaad, gpt)
check "gcm tc4", hex(gs),
  "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091" &
  "5bc94fbc3221a5db94fae95ae7121a47"
discard aesGcmOpen(gk, giv, gaad, gs, ok)
check "gcm open", $ok, "true"

# RFC 7748 5.2 / 6.1
check "x25519 #1", hex(x25519(unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                              unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"))),
  "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
let alicePriv = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
let bobPriv = unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
check "x25519 alice pub", hex(x25519Base(alicePriv)), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
check "x25519 shared", hex(x25519(alicePriv, x25519Base(bobPriv))),
  "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
# RFC 7748 5.2 iterated (1,000 iterations)
var k = unhex("0900000000000000000000000000000000000000000000000000000000000000")
var u = k
for i in 0 ..< 1000:
  let nk = x25519(k, u)
  u = k; k = nk
check "x25519 iter1000", hex(k), "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"

# RFC 8032 7.1 tests 1-3
let tests = [
  ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "",
   "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
   "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
  ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "72",
   "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
   "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
  ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "af82",
   "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
   "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a")]
for (sk, m, pk, sig) in tests:
  check "ed25519 pk", hex(ed25519PublicKey(unhex(sk))), pk
  check "ed25519 sig", hex(ed25519Sign(unhex(sk), unhex(m))), sig
  check "ed25519 verify", $ed25519Verify(unhex(pk), unhex(m), unhex(sig)), "true"
  var bad = unhex(sig); bad[10] = bad[10] xor 4
  check "ed25519 reject", $ed25519Verify(unhex(pk), unhex(m), bad), "false"

echo passed, " passed, ", failed, " failed"
if failed > 0: quit 1
