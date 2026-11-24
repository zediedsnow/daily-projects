## wren - a TLS 1.3 client and HTTPS server written from scratch in Nim.
import std/[net, os, strutils, parseopt, uri, times, monotimes]
import sha2, tls13

proc usage() =
  echo """wren - TLS 1.3 from scratch

  wren get <https://host:port/path> [--cafile=ca.pem] [--insecure] [-v]
           [--keylog=file] [--suite=chacha|aes] [--keyupdate] [--head]
  wren serve --cert=chain.pem --key=key.pem [--port=8443] [-v]
           [--keylog=file] [--max=N]
"""
  quit 1

proc stderrTrace(s: string) = stderr.writeLine "  " & s

proc doGet(args: seq[string], opts: seq[(string, string)]) =
  if args.len < 1: usage()
  var cafile = ""
  var insecure, verbose, keyupdate, headOnly = false
  var keylog: File = nil
  var suites = @[suiteChaCha, suiteAes128Gcm]
  for (k, v) in opts:
    case k
    of "cafile": cafile = v
    of "insecure", "k": insecure = true
    of "v", "verbose": verbose = true
    of "keylog": keylog = open(v, fmAppend)
    of "suite": suites = (if v == "aes": @[suiteAes128Gcm] else: @[suiteChaCha])
    of "keyupdate": keyupdate = true
    of "head": headOnly = true
    else: usage()
  let u = parseUri(args[0])
  if u.scheme != "https": quit "only https:// URLs are supported"
  let port = if u.port.len > 0: parseInt(u.port) else: 443
  let path = (if u.path.len > 0: u.path else: "/") & (if u.query.len > 0: "?" & u.query else: "")
  var anchors: seq[Cert]
  if cafile.len > 0: anchors = loadAnchors(cafile)
  elif not insecure: quit "need --cafile=<pem> (or --insecure)"
  let t0 = getMonoTime()
  let c = connect(u.hostname, port, anchors, verify = not insecure,
                  trace = (if verbose: stderrTrace else: nil), keylog = keylog, suites = suites)
  let hsMs = (getMonoTime() - t0).inMicroseconds.float / 1000
  if verbose: stderr.writeLine "  handshake took " & formatFloat(hsMs, ffDecimal, 2) & " ms"
  if keyupdate: c.requestKeyUpdate()
  c.write("GET " & path & " HTTP/1.1\r\nHost: " & u.hostname & "\r\nUser-Agent: wren/1.0\r\nConnection: close\r\n\r\n")
  let resp = toStr(c.readAll())
  c.close()
  if headOnly:
    let e = resp.find("\r\n\r\n")
    stdout.write(if e >= 0: resp[0 ..< e] & "\n" else: resp)
  else:
    stdout.write resp

proc page(c: TlsConn, path: string): (string, string) =
  if path.startsWith("/bytes/"):
    let n = parseInt(path[7 .. ^1])
    var s = newString(n)
    for i in 0 ..< n: s[i] = char(97 + (i * 7 + i div 13) mod 26)
    return ("application/octet-stream", s)
  let body = """<!doctype html><html><head><meta charset="utf-8"><title>wren</title></head>
<body style="font-family:system-ui;max-width:40em;margin:3em auto">
<h1>Hello over TLS 1.3</h1>
<p>This page was served by <b>wren</b>, a TLS 1.3 stack written from scratch in Nim.</p>
<table>
<tr><td>cipher suite</td><td><code>$1</code></td></tr>
<tr><td>key exchange</td><td><code>X25519</code></td></tr>
<tr><td>signature</td><td><code>Ed25519</code></td></tr>
<tr><td>SNI</td><td><code>$2</code></td></tr>
<tr><td>HelloRetryRequest</td><td><code>$3</code></td></tr>
<tr><td>ALPN</td><td><code>$4</code></td></tr>
<tr><td>path</td><td><code>$5</code></td></tr>
<tr><td>client random</td><td><code>$6</code></td></tr>
</table></body></html>
""" % [suiteName(c.suite), (if c.serverName.len > 0: c.serverName else: "(none)"),
       (if c.hrrSent: "yes" else: "no"), (if c.alpn.len > 0: c.alpn else: "(none)"),
       path.multiReplace(("<", "&lt;"), (">", "&gt;"), ("&", "&amp;")), hex(c.clientRandom)[0 ..< 16] & "..."]
  ("text/html; charset=utf-8", body)

proc doServe(opts: seq[(string, string)]) =
  var certF, keyF = ""
  var port = 8443
  var verbose = false
  var maxConns = -1
  var keylog: File = nil
  for (k, v) in opts:
    case k
    of "cert": certF = v
    of "key": keyF = v
    of "port": port = parseInt(v)
    of "v", "verbose": verbose = true
    of "max": maxConns = parseInt(v)
    of "keylog": keylog = open(v, fmAppend)
    else: usage()
  if certF.len == 0 or keyF.len == 0: usage()
  let cfg = loadServerConfig(certF, keyF)
  let s = newSocket(buffered = false)
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(port))
  s.listen()
  stderr.writeLine "wren: listening on https://localhost:" & $port & "/"
  var served = 0
  while maxConns < 0 or served < maxConns:
    inc served
    var c: TlsConn
    try:
      c = s.accept(cfg, trace = (if verbose: stderrTrace else: nil), keylog = keylog)
    except CatchableError as e:
      stderr.writeLine "wren: handshake failed: " & e.msg
      continue
    try:
      var req = ""
      while req.find("\r\n\r\n") < 0:
        let d = c.read()
        if d.len == 0: break
        req.add toStr(d)
      let line = req.split("\r\n")[0]
      let parts = line.split(' ')
      let path = if parts.len >= 2: parts[1] else: "/"
      let (ctype, body) = page(c, path)
      c.write("HTTP/1.1 200 OK\r\nContent-Type: " & ctype & "\r\nContent-Length: " & $body.len &
              "\r\nServer: wren/1.0\r\nConnection: close\r\n\r\n" & body)
      stderr.writeLine "wren: " & line & " -> 200 (" & $body.len & " bytes, " & suiteName(c.suite) &
                       (if c.keyUpdatesReceived > 0: ", " & $c.keyUpdatesReceived & " KeyUpdate" else: "") & ")"
      c.close()
    except CatchableError as e:
      stderr.writeLine "wren: connection error: " & e.msg
      try: c.sock.close() except CatchableError: discard

when isMainModule:
  var args: seq[string]
  var opts: seq[(string, string)]
  var p = initOptParser(commandLineParams())
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: args.add key
    of cmdLongOption, cmdShortOption: opts.add (key, val)
    of cmdEnd: discard
  if args.len == 0: usage()
  try:
    case args[0]
    of "get": doGet(args[1 .. ^1], opts)
    of "serve": doServe(opts)
    else: usage()
  except TlsError as e:
    stderr.writeLine "wren: TLS error: " & e.msg & " (alert " & $e.alert & ")"
    quit 2
  except CatchableError as e:
    stderr.writeLine "wren: " & e.msg
    quit 2
