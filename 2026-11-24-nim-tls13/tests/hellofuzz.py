#!/usr/bin/env python3
"""Robustness fuzzer: throws mutated ClientHellos at `wren serve` and checks that it
never crashes, never hangs, and still completes a real handshake afterwards."""
import random, socket, subprocess, sys, tempfile, time

wren, cert, key, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rng = random.Random(42)

# 1. capture a genuine ClientHello from OpenSSL
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind(("127.0.0.1", 4601)); ls.listen(1)
cli = subprocess.Popen(["openssl", "s_client", "-connect", "127.0.0.1:4601", "-tls1_3"],
                       stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
conn, _ = ls.accept(); conn.settimeout(2)
hello = conn.recv(65536); conn.close(); ls.close(); cli.kill()
assert hello[0] == 22, "did not capture a handshake record"

srv = subprocess.Popen([wren, "serve", f"--cert={cert}", f"--key={key}", "--port=4602"],
                       stderr=(log := tempfile.TemporaryFile("w+")))  # a file, not a pipe: a full pipe would block the server
time.sleep(0.4)
alerts = {}
def mutate(b):
    b = bytearray(b)
    for _ in range(rng.choice([1, 1, 2, 4, 8])):
        op = rng.randrange(4)
        i = rng.randrange(len(b))
        if op == 0: b[i] ^= 1 << rng.randrange(8)
        elif op == 1: b[i] = rng.choice([0, 0xff, 0x7f, 0x80, rng.randrange(256)])
        elif op == 2: del b[i:i + rng.randrange(1, 16)]
        else: b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 16)))
    if rng.random() < 0.2: b = b[:rng.randrange(len(b))]   # truncation
    return bytes(b)

for k in range(n):
    s = socket.create_connection(("127.0.0.1", 4602)); s.settimeout(5)
    try:
        last = mutate(hello); s.sendall(last); s.shutdown(socket.SHUT_WR)
        resp = s.recv(7)
        kind = "alert %d" % resp[6] if len(resp) == 7 and resp[0] == 21 else ("serverhello" if resp[:1] == b"\x16" else "closed")
    except socket.timeout:
        print("HANG on case", k); srv.kill(); sys.exit(1)
    except OSError:
        kind = "reset"
    alerts[kind] = alerts.get(kind, 0) + 1
    s.close()
    if srv.poll() is not None:
        print("SERVER CRASHED on case", k); log.seek(0); print(log.read()[-2000:]); sys.exit(1)

ok = subprocess.run(["curl", "-sS", "--cacert", cert.replace("chain.pem", "ca.pem"), "https://localhost:4602/"],
                    capture_output=True, text=True).stdout
srv.kill()
print(f"{n} mutated ClientHellos: no crashes, no hangs")
for kind, cnt in sorted(alerts.items(), key=lambda x: -x[1]): print(f"  {kind:<14} {cnt}")
print("server still healthy afterwards:", "Hello over TLS 1.3" in ok)
sys.exit(0 if "Hello over TLS 1.3" in ok else 1)
