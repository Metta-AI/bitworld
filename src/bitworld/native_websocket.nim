## Owned native WebSocket transport. Callers join workers before close; one caller
## owns receive. Sends and libcurl calls are serialized without a hidden reader.
import std/[atomics, base64, locks, monotimes, os, posix, sequtils, sha1, strutils, sysrand,
  times, unicode, uri]
import libcurl except Option
import native_stop

type
  WebSocketKind* = enum
    wsMessage, wsReady, wsDeadline, wsInterrupted, wsClosed, wsFailure
  WebSocketResult* = object
    kind*: WebSocketKind
    data*, error*: string
  IoPurpose = enum
    ipPlayer, ipCleanup
  PongState = enum
    psNone, psWaiting, psQueued, psSent
  NativeWebSocket* = ref object
    handle: PCurl
    socket: cint
    ioLock, sendLock: Lock
    incoming, fragments, pending: string
    fragmentOpcode: int
    pongState: Atomic[PongState]
    pongData: string
    maximum: int
    closed: bool
  WebSocketConnection* = object
    kind*: WebSocketKind
    socket*: NativeWebSocket
    error*: string
  Connecting = object
    deadline: MonoTime

when defined(macosx):
  const CurlLibrary = "libcurl(|.4).dylib"
else:
  const CurlLibrary = "libcurl.so(|.4)"
proc curlSend(handle: PCurl, buffer: pointer, length: csize_t,
  sent: ptr csize_t): cint {.cdecl, importc: "curl_easy_send", dynlib: CurlLibrary.}
proc curlReceive(handle: PCurl, buffer: pointer, length: csize_t,
  received: ptr csize_t): cint {.cdecl, importc: "curl_easy_recv", dynlib: CurlLibrary.}
const
  CurlAgain = 81
  ActiveSocket = cast[Info](0x500000 + 44)
  TimeoutMs = cast[libcurl.Option](155)
  ConnectTimeoutMs = cast[libcurl.Option](156)
  Protocols = cast[libcurl.Option](181)
  ProgressFunction = cast[libcurl.Option](20219)

proc requireCurl(code: Code) =
  if code != E_OK: raise newException(Defect, $easy_strerror(code))
block:
  requireCurl(global_init(GLOBAL_DEFAULT))
  doAssert (version_info(VERSION_NOW).features and VERSION_ASYNCHDNS) != 0

template withBlockedPipe(body: untyped) =
  var oldMask, pipeMask, previousPending: Sigset
  doAssert sigemptyset(pipeMask) == 0
  doAssert sigaddset(pipeMask, SIGPIPE) == 0
  doAssert sigpending(previousPending) == 0
  let pipeWasPending = sigismember(previousPending, SIGPIPE) != 0
  doAssert pthread_sigmask(SIG_BLOCK, pipeMask, oldMask) == 0
  try:
    body
  finally:
    if not pipeWasPending:
      var pending: Sigset
      doAssert sigpending(pending) == 0
      if sigismember(pending, SIGPIPE) > 0:
        var received: cint
        doAssert sigwait(pipeMask, received) == 0
    var discarded: Sigset
    doAssert pthread_sigmask(SIG_SETMASK, oldMask, discarded) == 0

proc interrupted(purpose: IoPurpose): bool =
  purpose == ipPlayer and interruptionRequested()

proc waitSocket(ws: NativeWebSocket, events: cshort, deadline: MonoTime,
    purpose: IoPurpose): WebSocketResult =
  while true:
    if interrupted(purpose): return WebSocketResult(kind: wsInterrupted)
    let remaining = (deadline - getMonoTime()).inNanoseconds
    if remaining <= 0: return WebSocketResult(kind: wsDeadline)
    var descriptor = TPollfd(fd: ws.socket, events: events)
    # Short polling bounds signal delivery even when the handler runs elsewhere.
    let milliseconds = cint(min(50'i64, (remaining + 999_999) div 1_000_000))
    let code = poll(descriptor.addr, Tnfds(1), milliseconds)
    if code < 0:
      if errno == EINTR: continue
      return WebSocketResult(kind: wsFailure, error: "WebSocket poll failed")
    if code > 0:
      if (descriptor.revents and POLLNVAL) != 0:
        return WebSocketResult(kind: wsFailure, error: "WebSocket descriptor invalid")
      return WebSocketResult(kind: wsReady)

proc receiveBytes(ws: NativeWebSocket, deadline: MonoTime,
    purpose: IoPurpose): WebSocketResult =
  while true:
    if interrupted(purpose): return WebSocketResult(kind: wsInterrupted)
    if getMonoTime() >= deadline: return WebSocketResult(kind: wsDeadline)
    var buffer: array[16384, char]
    var count: csize_t
    acquire(ws.ioLock)
    var code: cint
    withBlockedPipe:
      code = curlReceive(ws.handle, buffer.addr, csize_t(buffer.len), count.addr)
    release(ws.ioLock)
    if code == 0:
      if count == 0: return WebSocketResult(kind: wsClosed)
      let offset = ws.incoming.len
      ws.incoming.setLen(offset + int(count))
      copyMem(ws.incoming[offset].addr, buffer.addr, int(count))
      return WebSocketResult(kind: wsReady)
    if code != CurlAgain:
      return WebSocketResult(kind: wsFailure, error: "WebSocket receive failed")
    let ready = ws.waitSocket(POLLIN, deadline, purpose)
    if ready.kind != wsReady: return ready

proc flushPending(ws: NativeWebSocket, deadline: MonoTime,
    purpose: IoPurpose): WebSocketResult =
  while ws.pending.len > 0:
    if interrupted(purpose): return WebSocketResult(kind: wsInterrupted)
    if getMonoTime() >= deadline: return WebSocketResult(kind: wsDeadline)
    var sent: csize_t
    acquire(ws.ioLock)
    var code: cint
    withBlockedPipe:
      code = curlSend(ws.handle, ws.pending[0].addr,
        csize_t(ws.pending.len), sent.addr)
    release(ws.ioLock)
    if code == 0:
      if sent > 0: ws.pending.delete(0 .. int(sent) - 1)
    elif code != CurlAgain:
      return WebSocketResult(kind: wsFailure, error: "WebSocket send failed")
    if ws.pending.len > 0:
      let ready = ws.waitSocket(POLLOUT, deadline, purpose)
      if ready.kind != wsReady: return ready
  if ws.pongState.load() == psQueued: ws.pongState.store(psSent)
  WebSocketResult(kind: wsReady)

proc lockWriter(ws: NativeWebSocket, deadline: MonoTime,
    purpose: IoPurpose): WebSocketResult =
  while not tryAcquire(ws.sendLock):
    if interrupted(purpose): return WebSocketResult(kind: wsInterrupted)
    if getMonoTime() >= deadline: return WebSocketResult(kind: wsDeadline)
    sleep(1)
  WebSocketResult(kind: wsReady)

proc sendFrame(ws: NativeWebSocket, opcode: int, data: string,
    deadline: MonoTime, purpose: IoPurpose): WebSocketResult =
  let locked = ws.lockWriter(deadline, purpose)
  if locked.kind != wsReady: return locked
  try:
    if ws.closed: return WebSocketResult(kind: wsClosed)
    # A partially written earlier frame must finish before any subsequent frame.
    let previous = ws.flushPending(deadline, purpose)
    if previous.kind != wsReady: return previous
    if data.len > ws.maximum:
      return WebSocketResult(kind: wsFailure, error: "WebSocket message too large")
    var frame = $char(0x80 or opcode)
    if data.len < 126:
      frame.add char(0x80 or data.len)
    elif data.len <= 65535:
      frame.add char(0x80 or 126)
      frame.add char((data.len shr 8) and 255)
      frame.add char(data.len and 255)
    else:
      frame.add char(0x80 or 127)
      for shift in countdown(56, 0, 8):
        frame.add char((uint64(data.len) shr shift) and 255)
    let mask = urandom(4)
    for value in mask: frame.add char(value)
    for index, value in data:
      frame.add char(ord(value) xor int(mask[index mod 4]))
    ws.pending = move(frame)
    if opcode == 10: ws.pongState.store(psQueued)
    return ws.flushPending(deadline, purpose)
  finally:
    release(ws.sendLock)

proc receiveMessage(ws: NativeWebSocket, deadline: MonoTime,
    purpose: IoPurpose): WebSocketResult =
  while true:
    if ws.closed: return WebSocketResult(kind: wsClosed)
    if interrupted(purpose): return WebSocketResult(kind: wsInterrupted)
    if getMonoTime() >= deadline: return WebSocketResult(kind: wsDeadline)
    case ws.pongState.load()
    of psWaiting:
      let sent = ws.sendFrame(10, ws.pongData, deadline, purpose)
      if sent.kind != wsReady: return sent
      ws.pongState.store(psNone)
    of psQueued:
      let locked = ws.lockWriter(deadline, purpose)
      if locked.kind != wsReady: return locked
      var sent: WebSocketResult
      try:
        sent = ws.flushPending(deadline, purpose)
      finally:
        release(ws.sendLock)
      if sent.kind != wsReady: return sent
      ws.pongState.store(psNone)
    of psSent: ws.pongState.store(psNone)
    of psNone: discard
    var headerLength = 2
    var length = 0'u64
    var completeHeader = ws.incoming.len >= 2
    if completeHeader:
      let marker = ord(ws.incoming[1]) and 127
      if (ord(ws.incoming[0]) and 0x70) != 0 or
          (ord(ws.incoming[1]) and 0x80) != 0:
        return WebSocketResult(kind: wsFailure, error: "Invalid WebSocket frame flags")
      length = uint64(marker)
      if marker == 126: headerLength = 4
      elif marker == 127: headerLength = 10
      completeHeader = ws.incoming.len >= headerLength
      if completeHeader and marker >= 126:
        length = 0
        for index in 2 ..< headerLength:
          length = (length shl 8) or uint64(ord(ws.incoming[index]))
        if (marker == 126 and length < 126) or
            (marker == 127 and length < 65536):
          return WebSocketResult(kind: wsFailure, error: "Noncanonical WebSocket length")
      if completeHeader and length > uint64(ws.maximum):
        return WebSocketResult(kind: wsFailure, error: "WebSocket message too large")
    if not completeHeader or ws.incoming.len - headerLength < int(length):
      let received = ws.receiveBytes(deadline, purpose)
      if received.kind != wsReady: return received
      continue
    let first = ord(ws.incoming[0])
    let opcode = first and 15
    let final = (first and 0x80) != 0
    let payload = ws.incoming[headerLength ..< headerLength + int(length)]
    ws.incoming.delete(0 .. headerLength + int(length) - 1)
    if opcode >= 8:
      if not final or length > 125:
        return WebSocketResult(kind: wsFailure, error: "Invalid WebSocket control frame")
      case opcode
      of 8:
        if payload.len == 1:
          return WebSocketResult(kind: wsFailure, error: "Invalid WebSocket close frame")
        if payload.len >= 2:
          let code = ord(payload[0]) * 256 + ord(payload[1])
          if code < 1000 or code >= 5000 or code in [1004, 1005, 1006, 1015] or
              (code >= 1016 and code < 3000) or validateUtf8(payload[2 .. ^1]) != -1:
            return WebSocketResult(kind: wsFailure, error: "Invalid WebSocket close reason")
        return WebSocketResult(kind: wsClosed)
      of 9:
        ws.pongData = payload
        ws.pongState.store(psWaiting)
      of 10: discard
      else: return WebSocketResult(kind: wsFailure, error: "Unknown WebSocket control frame")
      continue
    case opcode
    of 0:
      if ws.fragmentOpcode == 0:
        return WebSocketResult(kind: wsFailure, error: "Unexpected WebSocket continuation")
    of 1, 2:
      if ws.fragmentOpcode != 0:
        return WebSocketResult(kind: wsFailure, error: "Unfinished WebSocket message")
      ws.fragmentOpcode = opcode
    else: return WebSocketResult(kind: wsFailure, error: "Unknown WebSocket opcode")
    if ws.fragments.len + payload.len > ws.maximum:
      return WebSocketResult(kind: wsFailure, error: "WebSocket message too large")
    ws.fragments.add payload
    if final:
      let messageOpcode = ws.fragmentOpcode
      ws.fragmentOpcode = 0
      let data = move(ws.fragments)
      if messageOpcode != 1 or validateUtf8(data) != -1:
        return WebSocketResult(kind: wsFailure, error: "Expected UTF-8 WebSocket text")
      return WebSocketResult(kind: wsMessage, data: data)

proc connectProgress(context: pointer, a, b, c, d: int64): cint {.cdecl.} =
  let connecting = cast[ptr Connecting](context)
  if interruptionRequested() or getMonoTime() >= connecting.deadline: 1 else: 0

proc closeNativeWebSocket*(ws: NativeWebSocket) =
  ## Invoke after joining every owned caller. Cleanup creates no background work.
  doAssert not ws.closed, "Native WebSocket already closed"
  ws.closed = true
  easy_cleanup(ws.handle)
  deinitLock(ws.ioLock)
  deinitLock(ws.sendLock)

proc connectNativeWebSocket*(url: string, deadline: MonoTime,
    maxMessageBytes: Positive): WebSocketConnection =
  if interruptionRequested(): return WebSocketConnection(kind: wsInterrupted)
  if getMonoTime() >= deadline: return WebSocketConnection(kind: wsDeadline)
  let parsed = parseUri(url)
  if parsed.scheme notin ["ws", "wss"] or parsed.hostname.len == 0 or
      parsed.username.len != 0 or parsed.password.len != 0 or parsed.anchor.len != 0 or
      url.anyIt(ord(it) <= 32 or ord(it) == 127):
    return WebSocketConnection(kind: wsFailure, error: "Invalid native WebSocket URL")
  var transport = parsed
  transport.scheme = if parsed.scheme == "wss": "https" else: "http"
  let ws = NativeWebSocket(handle: easy_init(), maximum: maxMessageBytes)
  doAssert ws.handle != nil
  initLock(ws.ioLock)
  initLock(ws.sendLock)
  var connecting = Connecting(deadline: deadline)
  var connected = false
  try:
    let transportUrl = $transport
    requireCurl(ws.handle.easy_setopt(OPT_URL, transportUrl.cstring))
    requireCurl(ws.handle.easy_setopt(OPT_CONNECT_ONLY, clong(1)))
    requireCurl(ws.handle.easy_setopt(OPT_HTTP_VERSION, clong(HTTP_VERSION_1_1)))
    requireCurl(ws.handle.easy_setopt(Protocols, clong(3)))
    requireCurl(ws.handle.easy_setopt(OPT_NOSIGNAL, clong(1)))
    requireCurl(ws.handle.easy_setopt(OPT_FOLLOWLOCATION, clong(0)))
    if existsEnv("SSL_CERT_FILE"):
      requireCurl(ws.handle.easy_setopt(OPT_CAINFO, getEnv("SSL_CERT_FILE").cstring))
    requireCurl(ws.handle.easy_setopt(OPT_PROGRESSDATA, connecting.addr))
    requireCurl(ws.handle.easy_setopt(OPT_NOPROGRESS, clong(0)))
    requireCurl(ws.handle.easy_setopt(ProgressFunction, connectProgress))
    let remaining = (deadline - getMonoTime()).inNanoseconds
    if remaining <= 0: return WebSocketConnection(kind: wsDeadline)
    let milliseconds = clong((remaining + 999_999) div 1_000_000)
    requireCurl(ws.handle.easy_setopt(TimeoutMs, milliseconds))
    requireCurl(ws.handle.easy_setopt(ConnectTimeoutMs, milliseconds))
    let code = ws.handle.easy_perform()
    if interruptionRequested(): return WebSocketConnection(kind: wsInterrupted)
    if getMonoTime() >= deadline or code == E_OPERATION_TIMEOUTED:
      return WebSocketConnection(kind: wsDeadline)
    if code != E_OK:
      return WebSocketConnection(kind: wsFailure, error: "WebSocket connection failed")
    requireCurl(ws.handle.easy_setopt(OPT_NOPROGRESS, clong(1)))
    requireCurl(ws.handle.easy_setopt(OPT_PROGRESSDATA, cast[pointer](nil)))
    requireCurl(ws.handle.easy_getinfo(ActiveSocket, ws.socket.addr))
    doAssert ws.socket >= 0
    let key = encode(urandom(16))
    var host = parsed.hostname
    if ':' in host: host = "[" & host & "]"
    if parsed.port.len > 0: host.add ":" & parsed.port
    var path = if parsed.path.len == 0: "/" else: parsed.path
    if parsed.query.len > 0: path.add "?" & parsed.query
    ws.pending = "GET " & path & " HTTP/1.1\r\nHost: " & host &
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " & key &
      "\r\nSec-WebSocket-Version: 13\r\n\r\n"
    let sent = ws.flushPending(deadline, ipPlayer)
    if sent.kind != wsReady: return WebSocketConnection(kind: sent.kind, error: sent.error)
    var endHeaders = ws.incoming.find("\r\n\r\n")
    while endHeaders < 0:
      if ws.incoming.len > 65536:
        return WebSocketConnection(kind: wsFailure, error: "WebSocket upgrade headers too large")
      let received = ws.receiveBytes(deadline, ipPlayer)
      if received.kind != wsReady:
        return WebSocketConnection(kind: received.kind, error: received.error)
      endHeaders = ws.incoming.find("\r\n\r\n")
    if endHeaders > 65536:
      return WebSocketConnection(kind: wsFailure, error: "WebSocket upgrade headers too large")
    let header = ws.incoming[0 ..< endHeaders]
    ws.incoming.delete(0 .. endHeaders + 3)
    let lines = header.split("\r\n")
    let status = lines[0].split(' ')
    if status.len < 2 or status[0] != "HTTP/1.1" or status[1] != "101":
      return WebSocketConnection(kind: wsFailure, error: "WebSocket upgrade rejected")
    var upgrade, connection, accept: string
    for index in 1 ..< lines.len:
      let colon = lines[index].find(':')
      if colon <= 0:
        return WebSocketConnection(kind: wsFailure, error: "Invalid WebSocket upgrade header")
      let name = lines[index][0 ..< colon].toLowerAscii
      let value = lines[index][colon + 1 .. ^1].strip
      case name
      of "sec-websocket-protocol", "sec-websocket-extensions":
        return WebSocketConnection(kind: wsFailure, error: "Unrequested WebSocket negotiation")
      of "upgrade":
        if upgrade.len > 0: return WebSocketConnection(kind: wsFailure, error: "Duplicate upgrade header")
        upgrade = value.toLowerAscii
      of "connection": connection.add "," & value.toLowerAscii
      of "sec-websocket-accept":
        if accept.len > 0: return WebSocketConnection(kind: wsFailure, error: "Duplicate accept header")
        accept = value
      else: discard
    let digest = Sha1Digest(secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    if upgrade != "websocket" or "upgrade" notin connection.split(',').mapIt(it.strip) or
        accept != encode(digest):
      return WebSocketConnection(kind: wsFailure, error: "Invalid WebSocket upgrade")
    connected = true
    return WebSocketConnection(kind: wsReady, socket: ws)
  finally:
    if not connected: closeNativeWebSocket(ws)

proc sendNativeText*(ws: NativeWebSocket, data: string,
    deadline: MonoTime): WebSocketResult =
  ws.sendFrame(1, data, deadline, ipPlayer)
proc receiveNativeText*(ws: NativeWebSocket,
    deadline: MonoTime): WebSocketResult =
  ws.receiveMessage(deadline, ipPlayer)
proc sendCleanupText*(ws: NativeWebSocket, data: string,
    cleanupDeadline: MonoTime): WebSocketResult =
  ws.sendFrame(1, data, cleanupDeadline, ipCleanup)
proc receiveCleanupText*(ws: NativeWebSocket,
    cleanupDeadline: MonoTime): WebSocketResult =
  ws.receiveMessage(cleanupDeadline, ipCleanup)
