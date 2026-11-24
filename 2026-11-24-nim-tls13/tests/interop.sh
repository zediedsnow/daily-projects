#!/usr/bin/env bash
# Interop + negative test matrix: wren vs OpenSSL s_server/s_client, curl, and itself.
set -uo pipefail
cd "$(dirname "$0")/.."
W=./wren; D=demo; T=$(mktemp -d); pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
expect() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
cleanup() { pkill -f "s_server -accept 459" 2>/dev/null; pkill -f "wren serve" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
[ -f $D/ca.pem ] || $D/mkcerts.sh >/dev/null 2>&1
python3 tests/badcerts.py $T/bad >/dev/null
EXPECT_BYTES=$(python3 -c "import hashlib;print(hashlib.sha256(bytes(97+(i*7+i//13)%26 for i in range(1000000))).hexdigest())")

echo "wren client -> openssl s_server"
for s in chacha aes; do
  ossl=$([ $s = chacha ] && echo TLS_CHACHA20_POLY1305_SHA256 || echo TLS_AES_128_GCM_SHA256)
  openssl s_server -accept 4590 -cert $D/server.pem -key $D/server.key -www -tls1_3 -ciphersuites $ossl \
     -keylogfile $T/ossl-$s.keys >/dev/null 2>&1 & sleep 0.4
  expect "GET over $ossl" "$W get https://localhost:4590/ --cafile=$D/ca.pem --suite=$s --keylog=$T/wren-$s.keys | grep -q 'Cipher is $ossl'"
  expect "KeyUpdate both ways ($s)" "$W get https://localhost:4590/ --cafile=$D/ca.pem --suite=$s --keyupdate -v 2>&1 | grep -q 'read keys rotated'"
  # Both sides must have derived byte-identical secrets for the first connection.
  expect "key schedule matches OpenSSL's keylog ($s)" \
    "diff <(grep -v '^#' $T/wren-$s.keys | sort) <(grep -v '^#' $T/ossl-$s.keys | grep \"\$(cut -d' ' -f2 $T/wren-$s.keys | head -1)\" | grep -v EXPORTER | sort)"
  kill %1 2>/dev/null; wait 2>/dev/null
done

echo "openssl s_client / curl -> wren server"
$W serve --cert=$D/chain.pem --key=$D/server.key --port=4591 2>$T/srv.log & sleep 0.4
for c in TLS_CHACHA20_POLY1305_SHA256 TLS_AES_128_GCM_SHA256; do
  expect "s_client $c, chain verifies" "echo | openssl s_client -connect localhost:4591 -CAfile $D/ca.pem -ciphersuites $c -servername localhost 2>&1 | grep -q 'Verify return code: 0'"
  expect "curl $c, 1 MB body intact" "[ \"\$(curl -sS --cacert $D/ca.pem --tls13-ciphers $c https://localhost:4591/bytes/1000000 | sha256sum | cut -d' ' -f1)\" = $EXPECT_BYTES ]"
done
expect "HelloRetryRequest when client leads with P-256" "echo | openssl s_client -connect localhost:4591 -CAfile $D/ca.pem -groups P-256:X25519 2>&1 | grep -q 'Verify return code: 0' && grep -q 'HelloRetryRequest</td><td><code>yes' <(curl -sS --cacert $D/ca.pem --curves P-256:X25519 https://localhost:4591/)"
expect "s_client KeyUpdate accepted by server" "(sleep 0.3; printf 'K\n'; sleep 0.3; printf 'GET / HTTP/1.0\r\n\r\n'; sleep 0.5) | openssl s_client -connect localhost:4591 -CAfile $D/ca.pem 2>&1 | grep -q 'Hello over TLS 1.3' && grep -q 'GET / HTTP/1.0 -> 200 .*1 KeyUpdate' $T/srv.log"
expect "TLS 1.2-only client is refused" "! curl -sS --cacert $D/ca.pem --tls-max 1.2 https://localhost:4591/"
expect "client without X25519 is refused" "! echo | openssl s_client -connect localhost:4591 -groups P-256 2>&1 | grep -q 'Cipher is TLS'"

echo "wren client -> wren server"
expect "wren <-> wren, chacha" "$W get https://localhost:4591/ --cafile=$D/ca.pem | grep -q CHACHA20"
expect "wren <-> wren, aes" "$W get https://localhost:4591/ --cafile=$D/ca.pem --suite=aes | grep -q AES_128_GCM"
expect "wren <-> wren, 1 MB body" "[ \"\$($W get https://localhost:4591/bytes/1000000 --cafile=$D/ca.pem | tail -c 1000000 | sha256sum | cut -d' ' -f1)\" = $EXPECT_BYTES ]"
kill %1 2>/dev/null; wait 2>/dev/null

echo "certificate validation (wren client -> openssl s_server)"
port=4592
for case in good:ok multisan:ok intermediate:ok wronghost:'not valid for host' expired:expired notyet:'not yet valid' \
            untrusted:'no trusted root' tampered:'bad signature' nonca:'is not a CA'; do
  name=${case%%:*}; want=${case#*:}
  openssl s_server -accept $port -cert $T/bad/$name.pem -key $T/bad/$name.key -cert_chain $T/bad/$name.pem -www -tls1_3 >/dev/null 2>&1 & sleep 0.4
  out=$($W get https://localhost:$port/ --cafile=$T/bad/root.pem 2>&1)
  if [ "$want" = ok ]; then expect "$name chain accepted" "echo \"\$out\" | grep -q 'Cipher is'"
  else expect "$name chain rejected ($want)" "echo \"\$out\" | grep -q '$want'"; fi
  kill %1 2>/dev/null; wait 2>/dev/null; port=$((port+1))
done

echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
