import std/[json, monotimes, os, strutils, times]
import libcurl
import bitworld/[native_stop, native_websocket]
type Sender = tuple[socket: ptr NativeWebSocket, status: ptr WebSocketKind, count, bytes, deadlineMs: int]
proc sendMany(argument: Sender) {.thread.} =
  let deadline = getMonoTime() + initDuration(milliseconds = argument.deadlineMs)
  for index in 0 ..< argument.count:
    let sent = argument.socket[].sendNativeText((if argument.bytes > 0: repeat('x', argument.bytes) else: $index), deadline)
    argument.status[] = sent.kind
    if sent.kind != wsReady: return
proc main() =
  installNativeStopHandlers()
  let mode = paramStr(2)
  let started = getMonoTime()
  let connected = connectNativeWebSocket(paramStr(1), started + initDuration(milliseconds = 600), 16 * 1024 * 1024)
  echo $(%*{"connect": $connected.kind, "error": connected.error, "curl_version": $libcurl.version(),
    "elapsed_ms": (getMonoTime() - started).inMilliseconds})
  if connected.kind != wsReady: quit(0)
  let socket = connected.socket
  defer: closeNativeWebSocket(socket)
  proc report(value: WebSocketResult) =
    echo $(%*{"kind": $value.kind, "data": value.data,
      "elapsed_ms": (getMonoTime() - started).inMilliseconds})
  if mode == "resume":
    report(socket.receiveNativeText(getMonoTime() + initDuration(milliseconds = 80)))
    report(socket.receiveNativeText(getMonoTime() + initDuration(milliseconds = 600)))
  elif mode == "signal":
    report(socket.receiveNativeText(getMonoTime() + initDuration(seconds = 5)))
    let deadline = getMonoTime() + initDuration(milliseconds = 600)
    report(socket.sendCleanupText("stopped", deadline))
    report(socket.receiveCleanupText(deadline))
    report(socket.receiveCleanupText(deadline))
  elif mode == "large":
    let received = socket.receiveNativeText(getMonoTime() + initDuration(seconds = 2))
    if received.kind == wsMessage:
      let metadata = parseJson(received.data)
      echo $(%*{"kind": $received.kind, "token_count": metadata["prompt_token_ids"].len,
        "bytes": received.data.len})
    else: report(received)
  elif mode == "concurrent":
    var owned = socket
    var status: WebSocketKind
    var thread: Thread[Sender]
    createThread(thread, sendMany, (owned.addr, status.addr, 100, 0, 2000))
    var count = 0
    let deadline = getMonoTime() + initDuration(seconds = 2)
    for index in 0 ..< 100:
      let received = socket.receiveNativeText(deadline)
      doAssert received.kind == wsMessage and received.data == $index
      inc count
    joinThread(thread)
    echo $(%*{"kind": $status, "messages": count})
  elif mode == "alternating":
    var owned = socket
    var status: WebSocketKind
    var thread: Thread[Sender]
    let deadline = getMonoTime() + initDuration(seconds = 4)
    for index in 0 ..< 20:
      createThread(thread, sendMany, (owned.addr, status.addr, 1, 128, 2000))
      joinThread(thread)
      doAssert status == wsReady
      # The sender's thread heap is gone before the main owner sends/pongs.
      doAssert socket.sendCleanupText("stopped", deadline).kind == wsReady
      let received = socket.receiveCleanupText(deadline)
      doAssert received.kind == wsMessage and received.data == "received"
    echo $(%*{"kind": $status, "messages": 20})
  elif mode == "partial-exited-worker":
    var owned = socket
    var status: WebSocketKind
    var thread: Thread[Sender]
    createThread(thread, sendMany, (owned.addr, status.addr, 1, 8 * 1024 * 1024, 80))
    joinThread(thread)
    doAssert status == wsDeadline
    let deadline = getMonoTime() + initDuration(seconds = 4)
    report(socket.sendCleanupText("stopped", deadline))
    report(socket.receiveCleanupText(deadline))
  elif mode == "pong-timeout":
    var owned = socket
    var status: WebSocketKind
    var thread: Thread[Sender]
    createThread(thread, sendMany, (owned.addr, status.addr, 1, 8 * 1024 * 1024, 2000))
    report(socket.receiveNativeText(getMonoTime() + initDuration(milliseconds = 250)))
    joinThread(thread)
    doAssert status == wsReady
    report(socket.receiveNativeText(getMonoTime() + initDuration(seconds = 2)))
  elif mode == "partial-send":
    report(socket.sendNativeText(repeat('x', 8 * 1024 * 1024), getMonoTime() + initDuration(milliseconds = 80)))
    let deadline = getMonoTime() + initDuration(seconds = 4)
    report(socket.sendCleanupText("stopped", deadline))
    report(socket.receiveCleanupText(deadline))
  else:
    report(socket.receiveNativeText(getMonoTime() + initDuration(milliseconds = 600)))
main()
