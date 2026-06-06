## Pure Nim streaming HTTP/HTTPS client
## Reads responses line-by-line without buffering the entire body.
## Supports HTTP/1.1, TLS via openssl, and optional HTTP proxy.

import std/[net, strutils, parseutils]

export net.Port

type
  StreamHttpUrl* = object
    scheme*: string
    host*: string
    port*: int
    path*: string

  StreamHttpClient* = ref object
    timeout*: int               ## Connect/read timeout in ms (default 300000)
    proxyUrl*: string           ## Optional HTTP proxy URL
    reuseConnections*: bool     ## Not yet implemented

  StreamHttpResponse* = object
    statusCode*: int
    statusText*: string
    headers*: seq[(string, string)]

proc parseStreamUrl*(url: string): StreamHttpUrl =
  ## Parse a URL into components; defaults to https:443 and path /
  result = StreamHttpUrl(scheme: "https", host: "", port: 443, path: "/")
  var s = url
  if s.startsWith("https://"):
    result.scheme = "https"
    result.port = 443
    s = s[8 .. ^1]
  elif s.startsWith("http://"):
    result.scheme = "http"
    result.port = 80
    s = s[7 .. ^1]

  var hostPort = s
  let slashIdx = s.find('/')
  if slashIdx >= 0:
    hostPort = s[0 ..< slashIdx]
    result.path = s[slashIdx .. ^1]
  else:
    result.path = "/"

  let colonIdx = hostPort.find(':')
  if colonIdx >= 0:
    result.host = hostPort[0 ..< colonIdx]
    discard parseInt(hostPort[colonIdx + 1 .. ^1], result.port)
  else:
    result.host = hostPort

proc findHeader(headers: seq[(string, string)], key: string): string =
  let lowerKey = key.toLower
  for (k, v) in headers:
    if k.toLower == lowerKey:
      return v
  return ""

proc connectSocket(host: string, port: int, timeoutMs: int): Socket =
  result = newSocket()
  try:
    result.setSockOpt(OptNoDelay, true)
  except OSError:
    discard
  result.connect(host, Port(port), timeoutMs)

proc sendAll(socket: Socket, data: string) =
  var total = 0
  while total < data.len:
    let sent = socket.send(addr data[total], data.len - total)
    if sent < 0:
      raise newException(IOError, "Failed to send HTTP request")
    if sent == 0:
      raise newException(IOError, "HTTP request send returned 0 bytes (connection closed)")
    total += sent

proc readLineInto(socket: Socket, buf: var string, timeoutMs: int): bool =
  ## Read a single LF-terminated line into buf (excluding LF but stripping CR).
  ## Returns false on EOF/error.
  buf.setLen(0)
  var ch: char
  while true:
    let n = socket.recv(addr ch, 1, timeoutMs)
    if n <= 0:
      return buf.len > 0
    if ch == '\n':
      if buf.len > 0 and buf[^1] == '\r':
        buf.setLen(buf.len - 1)
      return true
    buf.add(ch)

proc parseStatusLine(line: string): (int, string) =
  ## "HTTP/1.1 200 OK" -> (200, "OK")
  let parts = line.split(' ', maxsplit = 2)
  if parts.len >= 2:
    var code = 0
    discard parseInt(parts[1], code)
    let text = if parts.len >= 3: parts[2] else: ""
    return (code, text)
  return (0, "")

proc parseHeaderLine(line: string): (string, string) =
  let idx = line.find(':')
  if idx >= 0:
    return (line[0 ..< idx].strip, line[idx + 1 .. ^1].strip)
  return ("", "")

proc performRequest*(
  client: StreamHttpClient,
  url: StreamHttpUrl,
  httpMethod, body: string,
  headers: seq[(string, string)],
  lineCallback: proc(line: string) {.closure.}
): StreamHttpResponse =
  ## Perform a streaming HTTP/HTTPS request.
  ## Reads the response line-by-line; callback is invoked for each body line.
  ## Returns parsed status and headers.

  let targetHost = url.host
  let targetPort = url.port
  let targetPath = url.path

  # Determine effective connection endpoint (proxy-aware)
  var connectHost = targetHost
  var connectPort = targetPort
  when defined(ssl):
    var useProxy = false
    if client.proxyUrl != "":
      useProxy = true
      let pu = parseStreamUrl(client.proxyUrl)
      connectHost = pu.host
      connectPort = pu.port

  let socket = connectSocket(connectHost, connectPort, client.timeout)

  when defined(ssl):
    var ctx: SslContext = nil
    if url.scheme == "https":
      if useProxy:
        # HTTP CONNECT tunnel
        let connectReq = "CONNECT " & targetHost & ":" & $targetPort & " HTTP/1.1\r\nHost: " & targetHost & ":" & $targetPort & "\r\n\r\n"
        socket.sendAll(connectReq)
        var line = ""
        var statusRead = false
        while socket.readLineInto(line, client.timeout):
          if line == "":
            break
          if not statusRead:
            let (code, _) = parseStatusLine(line)
            if code != 200:
              raise newException(IOError, "Proxy CONNECT failed: " & $code)
            statusRead = true

      ctx = newContext(verifyMode = CVerifyPeer)
      ctx.wrapConnectedSocket(socket, handshakeAsClient, targetHost)

    # Ensure socket closes before SSL context is destroyed.
    defer:
      if ctx != nil:
        destroyContext(ctx)
    defer: socket.close()
  else:
    defer: socket.close()

  # Build request
  var requestLines: seq[string] = @[]
  requestLines.add(httpMethod.toUpper & " " & targetPath & " HTTP/1.1")
  requestLines.add("Host: " & targetHost)
  requestLines.add("Connection: close")
  requestLines.add("Accept: text/event-stream")
  if body.len > 0:
    requestLines.add("Content-Length: " & $body.len)
  for (k, v) in headers:
    requestLines.add(k & ": " & v)
  requestLines.add("")

  var request = requestLines.join("\r\n") & "\r\n"
  if body.len > 0:
    request.add(body)
  socket.sendAll(request)

  # Read status line
  var line = ""
  if not socket.readLineInto(line, client.timeout):
    raise newException(IOError, "Failed to read HTTP status line")
  let (statusCode, statusText) = parseStatusLine(line)

  # Read headers
  var respHeaders: seq[(string, string)] = @[]
  while true:
    if not socket.readLineInto(line, client.timeout):
      break
    if line == "":
      break
    let (k, v) = parseHeaderLine(line)
    if k != "":
      respHeaders.add((k, v))

  let transferEncoding = findHeader(respHeaders, "Transfer-Encoding")

  result = StreamHttpResponse(statusCode: statusCode, statusText: statusText, headers: respHeaders)

  # Read body line-by-line
  if transferEncoding.toLower.contains("chunked"):
    # Chunked transfer encoding
    while true:
      # Read chunk size line
      if not socket.readLineInto(line, client.timeout):
        break
      var chunkSize = 0
      var hexStr = line
      let semiIdx = hexStr.find(';')
      if semiIdx >= 0:
        hexStr = hexStr[0 ..< semiIdx]
      chunkSize = parseHexInt(hexStr.strip)
      if chunkSize <= 0:
        # Read trailing headers
        while socket.readLineInto(line, client.timeout):
          if line == "":
            break
        break

      # Read chunk data line-by-line (simplification: read chunk raw, split by LF)
      var chunkBuf = newString(chunkSize)
      var totalRead = 0
      while totalRead < chunkSize:
        let n = socket.recv(addr chunkBuf[totalRead], chunkSize - totalRead, client.timeout)
        if n <= 0:
          break
        totalRead += n
      chunkBuf.setLen(totalRead)

      # Read trailing \r\n after chunk
      var crlf: array[2, char]
      discard socket.recv(addr crlf[0], 2, client.timeout)

      # Emit lines from chunk
      var start = 0
      for i in 0 ..< chunkBuf.len:
        if chunkBuf[i] == '\n':
          var ln = chunkBuf[start ..< i]
          if ln.len > 0 and ln[^1] == '\r':
            ln.setLen(ln.len - 1)
          lineCallback(ln)
          start = i + 1
      if start < chunkBuf.len:
        var ln = chunkBuf[start .. ^1]
        if ln.len > 0 and ln[^1] == '\r':
          ln.setLen(ln.len - 1)
        lineCallback(ln)
  else:
    # Non-chunked: read until connection close
    while socket.readLineInto(line, client.timeout):
      lineCallback(line)

proc newStreamHttpClient*(timeout: int = 300_000, proxyUrl: string = ""): StreamHttpClient =
  result = StreamHttpClient(
    timeout: timeout,
    proxyUrl: proxyUrl,
    reuseConnections: false,
  )
