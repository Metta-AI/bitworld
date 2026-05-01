## Websocket runner: connection, frame draining, mask emission, chat
## flushing, reconnect loop, viewer lifecycle, trace writer attachment,
## optional LLM-mock harness wiring.
##
## Phase 1 port from v2:4709-4840. The viewer (`--gui`) shipped with
## Phase 2; closing the window or pressing Esc terminates the bot
## cleanly. Trace writer attachment + auto frames-dump shipped with
## Phase 5 (TRACING.md). The optional `--llm-mock:PATH` flag is wired
## here under `when defined(modTalksLlm)` so test runs can exercise the
## LLM state machine without making real provider calls (Sprint 3.1).

when not defined(modulabotLibrary):
  import std/[json, monotimes, options, os, times]
  import whisky

  import protocol
  import ../../../sim                  # WebSocketPath

  import ../types
  import ../frame  # unpack4bpp
  import ../bot
  import ../ascii  # for isGameOverText
  import ../trace
  when defined(modTalksLlm):
    import ../llm  # llmMockEnable — optional LLM-mock plumbing
  import viewer    # initViewerApp / pumpViewer / viewerOpen

  const
    FrameDropThreshold = 32
      ## When the queued frame backlog reaches this size, drop all but
      ## the latest frame to catch up. Prevents the bot from steering
      ## on stale percepts under load.
    MaxFrameDrain = 128
      ## Hard cap on per-tick non-blocking message reads, so the
      ## runner can't get stuck draining a runaway stream.

  proc queryEscape(value: string): string =
    ## URL-escapes a string for use as a websocket query parameter.
    const Hex = "0123456789ABCDEF"
    for ch in value:
      if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
          ch in {'-', '_', '.', '~'}:
        result.add(ch)
      else:
        let byte = ord(ch)
        result.add('%')
        result.add(Hex[(byte shr 4) and 0x0f])
        result.add(Hex[byte and 0x0f])

  proc acceptPlayerMessage(ws: WebSocket, message: Message,
                          queuedFrames: var seq[string]) =
    case message.kind
    of BinaryMessage:
      if message.data.len == ProtocolBytes:
        queuedFrames.add(message.data)
    of Ping:
      ws.send(message.data, Pong)
    of TextMessage, Pong:
      discard

  proc receiveLatestFrame(ws: WebSocket, bot: var Bot, gui: bool): bool =
    ## Drains the websocket up to `MaxFrameDrain` messages, picks the
    ## latest frame from the queue, advances `bot.frameTick` by the
    ## number of frames consumed, and unpacks into `bot.io.unpacked`.
    ##
    ## When `gui` is true, the initial blocking receive uses a 10 ms
    ## timeout so the GUI thread can stay responsive between frames.
    if bot.io.queuedFrames.len == 0:
      let firstMessage = ws.receiveMessage(if gui: 10 else: -1)
      if firstMessage.isNone:
        bot.io.frameBufferLen = 0
        bot.io.framesDropped = 0
        return false
      ws.acceptPlayerMessage(firstMessage.get, bot.io.queuedFrames)

    var drained = 0
    while drained < MaxFrameDrain:
      let message = ws.receiveMessage(0)
      if message.isNone:
        break
      ws.acceptPlayerMessage(message.get, bot.io.queuedFrames)
      inc drained

    if bot.io.queuedFrames.len == 0:
      bot.io.frameBufferLen = 0
      bot.io.framesDropped = 0
      return false

    var
      frame = ""
      frameAdvance = 1
    bot.io.framesDropped = 0
    if bot.io.queuedFrames.len >= FrameDropThreshold:
      bot.io.framesDropped = bot.io.queuedFrames.len - 1
      frameAdvance = bot.io.queuedFrames.len
      frame = bot.io.queuedFrames[^1]
      bot.io.queuedFrames.setLen(0)
    else:
      frame = bot.io.queuedFrames[0]
      bot.io.queuedFrames.delete(0)

    bot.io.frameBufferLen = bot.io.queuedFrames.len
    bot.io.skippedFrames += bot.io.framesDropped
    if bot.io.framesDropped > 0:
      echo "frames dropped: ", bot.io.framesDropped,
        " buffered=", frameAdvance,
        " total=", bot.io.skippedFrames,
        " tick=", bot.frameTick + frameAdvance
    bot.frameTick += frameAdvance
    blobToBytes(frame, bot.io.packed)
    unpack4bpp(bot.io.packed, bot.io.unpacked)
    true

  proc dumpFrame(file: File, unpacked: openArray[uint8]) =
    ## Writes one captured unpacked frame. Format:
    ##   ScreenWidth*ScreenHeight (= 16384) bytes per frame.
    ## The mask isn't recorded — the parity harness re-derives it by
    ## running each bot on the captured frame, which is the whole
    ## point: real-frame parity should compare what *each* bot decides
    ## given the same percept, not what one bot already decided.
    discard file.writeBuffer(unsafeAddr unpacked[0], unpacked.len)

  proc runBot*(host: string; port: int; gui: bool; name: string;
               mapPath: string; framesPath: string = "";
               traceDir: string = ""; traceLevel: TraceLevel = tlDecisions;
               traceSnapshotPeriod: int = 120; traceMeta: string = "";
               traceFramesDump: bool = true;
               llmMockPath: string = "") =
    ## Connects to an Among Them server and processes frames in a
    ## reconnect loop. When `gui` is true, opens the diagnostic
    ## viewer window; pressing Esc or closing the window terminates
    ## the bot cleanly.
    ##
    ## `framesPath` (`--frames:<file>`): when non-empty, writes every
    ## received unpacked frame to `<file>`. Used to capture real-game
    ## frames for offline parity testing.
    ##
    ## `traceDir` (`--trace-dir:<path>`): when non-empty, opens a
    ## structured trace under that root. See TRACING.md.
    ##
    ## `llmMockPath` (`--llm-mock:<file>`): enables the mock-LLM
    ## harness (Sprint 3.1). Requires `-d:modTalksLlm`; warned
    ## and ignored otherwise. Mutually exclusive with the real
    ## provider — when set, `llmEnable` is called against the
    ## mock fixture instead of the Python-side enable path.
    let paths = defaultPaths(mapPath)
    var bot = initBot(paths)

    # LLM-mock harness (Sprint 3.1). Enabled only when built with
    # `-d:modTalksLlm` AND `--llm-mock:PATH` was passed. The bot's
    # LLM state machine becomes active and consumes scripted
    # responses from the fixture file instead of making real
    # Bedrock / Anthropic calls.
    if llmMockPath.len > 0:
      when defined(modTalksLlm):
        try:
          llmMockEnable(bot, llmMockPath)
          echo "modulabot: llm-mock loaded from ", llmMockPath,
               " entries=", bot.llm.mock.entries.len
        except CatchableError as err:
          echo "modulabot: failed to load --llm-mock fixture: ",
               err.msg
      else:
        echo "modulabot: --llm-mock specified but this build lacks ",
             "-d:modTalksLlm; ignoring"
    var dumpFile: File = nil
    var effectiveFramesPath = framesPath
    # If tracing is on and no explicit --frames was passed, default to
    # capturing into the session directory. Replay tools resolve this
    # via manifest.config.frames_dump_path.
    if traceDir.len > 0 and traceFramesDump and effectiveFramesPath.len == 0:
      let sessionDir = traceDir / (if name.len > 0: name else: "modulabot")
      try:
        createDir(sessionDir)
      except IOError, OSError:
        discard
      effectiveFramesPath = sessionDir / "frames.bin"
    if effectiveFramesPath.len > 0:
      try:
        dumpFile = open(effectiveFramesPath, fmWrite)
        echo "modulabot: capturing frames to ", effectiveFramesPath
      except IOError:
        echo "modulabot: failed to open frame dump path ",
          effectiveFramesPath, ", continuing without capture"
        dumpFile = nil
    defer:
      if dumpFile != nil:
        dumpFile.close()

    # Trace writer setup. The seed is the one that initBot used; we
    # don't currently surface it back from initBot so we record 0
    # (meaning "clock-derived"). When `--seed` plumbing is added this
    # field can be populated authoritatively.
    if traceDir.len > 0:
      let configJson = $(%*{
        "host":      host,
        "port":      port,
        "map":       mapPath,
        "name":      name,
        "transport": "websocket"
      })
      bot.trace = openTrace(
        rootDir        = traceDir,
        botName        = (if name.len > 0: name else: "modulabot"),
        level          = traceLevel,
        snapshotPeriod = traceSnapshotPeriod,
        captureFrames  = (effectiveFramesPath.len > 0),
        harnessMeta    = traceMeta,
        masterSeed     = 0,
        framesPath     = effectiveFramesPath,
        configJson     = configJson
      )
      bot.trace.beginRound(bot, isMidRound = true)
      echo "modulabot: tracing to ", traceDir,
           " level=", traceLevel,
           " session=", bot.trace.sessionId
    defer:
      if not bot.trace.isNil:
        try:
          bot.trace.closeTrace(bot, "process_exit")
        except CatchableError:
          discard
    var viewerApp: ViewerApp =
      if gui: initViewerApp(paths.atlasPath)
      else: nil
    var connected = false
    let url =
      if name.len > 0:
        "ws://" & host & ":" & $port & WebSocketPath &
          "?name=" & name.queryEscape()
      else:
        "ws://" & host & ":" & $port & WebSocketPath
    while viewerApp.viewerOpen():
      try:
        let ws = newWebSocket(url)
        var lastMask = 0xff'u8
        bot.io.queuedFrames.setLen(0)
        bot.io.frameBufferLen = 0
        bot.io.framesDropped = 0
        connected = true
        while viewerApp.viewerOpen():
          if gui:
            viewerApp.pumpViewer(bot, connected, url)
            if not viewerApp.viewerOpen():
              ws.close()
              break
          if not ws.receiveLatestFrame(bot, gui):
            continue
          let nextMask = bot.decideNextMask()
          bot.io.lastMask = nextMask
          if dumpFile != nil:
            dumpFile.dumpFrame(bot.io.unpacked)
          if nextMask != lastMask:
            ws.send(blobFromMask(nextMask), BinaryMessage)
            lastMask = nextMask
          if bot.percep.interstitial and
              bot.chat.pendingChat.len > 0 and
              not bot.percep.interstitialText.isGameOverText():
            let chatText = bot.chat.pendingChat
            ws.send(blobFromChat(chatText), BinaryMessage)
            bot.chat.pendingChat = ""
            if not bot.trace.isNil:
              try:
                bot.trace.emitChatSent(bot, chatText)
              except CatchableError:
                discard
      except Exception:
        connected = false
        if gui:
          # Pump the GUI for ~250 ms so the viewer stays responsive
          # while we wait to reconnect.
          let reconnectStart = getMonoTime()
          while viewerApp.viewerOpen() and
              (getMonoTime() - reconnectStart).inMilliseconds < 250:
            viewerApp.pumpViewer(bot, connected, url)
            sleep(10)
        else:
          sleep(250)
