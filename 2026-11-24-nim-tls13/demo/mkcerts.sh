#!/usr/bin/env bash
# Creates an Ed25519 root CA and an Ed25519 leaf for localhost (demo only).
set -euo pipefail
cd "$(dirname "$0")"
openssl genpkey -algorithm ed25519 -out ca.key
openssl req -x509 -new -key ca.key -subj "/CN=Wren Demo Root CA" -days 3650 \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" -out ca.pem
openssl genpkey -algorithm ed25519 -out server.key
openssl req -new -key server.key -subj "/CN=localhost" -out server.csr
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n" > leaf.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 \
  -extfile leaf.ext -out server.pem
cat server.pem ca.pem > chain.pem
rm -f server.csr leaf.ext ca.srl
echo "wrote ca.pem, server.pem, chain.pem, server.key"
