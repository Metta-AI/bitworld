when not defined(evidencebotLibrary):
  proc drawOutline(sk: Silky, pos, size: Vec2, color: ColorRGBX, thickness = 1.0) =
    ## Draws an unfilled rectangle.
    sk.drawRect(pos, vec2(size.x, thickness), color)
    sk.drawRect(vec2(pos.x, pos.y + size.y - thickness), vec2(size.x, thickness), color)
    sk.drawRect(pos, vec2(thickness, size.y), color)
    sk.drawRect(vec2(pos.x + size.x - thickness, pos.y), vec2(thickness, size.y), color)

  proc drawLine(sk: Silky, a, b: Vec2, color: ColorRGBX) =
    ## Draws a simple pixel-like line.
    let
      dx = b.x - a.x
      dy = b.y - a.y
      steps = max(1, int(max(abs(dx), abs(dy)) / 4.0'f))
    for i in 0 .. steps:
      let t = i.float32 / steps.float32
      sk.drawRect(
        vec2(a.x + dx * t - 1.0'f, a.y + dy * t - 1.0'f),
        vec2(3, 3),
        color
      )

  proc taskStateColor(state: TaskState): ColorRGBX =
    ## Returns a map marker color for a task state.
    case state
    of TaskNotDoing:
      ViewerTask
    of TaskMaybe:
      ViewerTaskGuess
    of TaskMandatory:
      ViewerButton
    of TaskCompleted:
      ViewerMutedText

  proc crewmateOutlineColor(bot: Bot, colorIndex: int): ColorRGBX =
    ## Returns the debug outline color for one visible crewmate.
    if bot.knownImposterColor(colorIndex):
      ViewerImp
    else:
      ViewerCrew

  proc drawCrewmateFrameOutlines(
    sk: Silky,
    bot: Bot,
    x,
    y,
    scale: float32
  ) =
    ## Draws visible crewmate team outlines in screen space.
    for crewmate in bot.visibleCrewmates:
      sk.drawOutline(
        vec2(
          x + crewmate.x.float32 * scale,
          y + crewmate.y.float32 * scale
        ),
        vec2(
          bot.playerSprite.width.float32 * scale,
          bot.playerSprite.height.float32 * scale
        ),
        bot.crewmateOutlineColor(crewmate.colorIndex),
        2
      )

  proc drawCrewmateMapOutlines(
    sk: Silky,
    bot: Bot,
    x,
    y,
    scale: float32
  ) =
    ## Draws visible crewmate team outlines in map space.
    if not bot.localized:
      return
    for crewmate in bot.visibleCrewmates:
      let
        world = bot.visibleCrewmateWorld(crewmate)
        spriteX = world.x - SpriteDrawOffX
        spriteY = world.y - SpriteDrawOffY
      sk.drawOutline(
        vec2(x + spriteX.float32 * scale, y + spriteY.float32 * scale),
        vec2(
          bot.playerSprite.width.float32 * scale,
          bot.playerSprite.height.float32 * scale
        ),
        bot.crewmateOutlineColor(crewmate.colorIndex),
        2
      )

  proc drawFrameView(sk: Silky, bot: Bot, x, y: float32) =
    ## Draws the latest 128x128 game frame.
    let pixelScale = ViewerFrameScale
    sk.drawRect(
      vec2(x, y),
      vec2(ScreenWidth.float32 * pixelScale, ScreenHeight.float32 * pixelScale),
      ViewerPanelAlt
    )
    for py in 0 ..< ScreenHeight:
      for px in 0 ..< ScreenWidth:
        let index = bot.unpacked[py * ScreenWidth + px]
        sk.drawRect(
          vec2(x + px.float32 * pixelScale, y + py.float32 * pixelScale),
          vec2(pixelScale, pixelScale),
          sampleColor(index)
        )
    sk.drawCrewmateFrameOutlines(bot, x, y, pixelScale)
    if bot.interstitial:
      return
    let
      button = bot.sim.gameMap.button
      buttonX = button.x - bot.cameraX
      buttonY = button.y - bot.cameraY
    if buttonX + button.w >= 0 and buttonY + button.h >= 0 and
        buttonX < ScreenWidth and buttonY < ScreenHeight:
      sk.drawOutline(
        vec2(x + buttonX.float32 * pixelScale, y + buttonY.float32 * pixelScale),
        vec2(button.w.float32 * pixelScale, button.h.float32 * pixelScale),
        ViewerButton,
        2
      )
    sk.drawRect(
      vec2(
        x + PlayerScreenX.float32 * pixelScale - 3,
        y + PlayerScreenY.float32 * pixelScale - 3
      ),
      vec2(7, 7),
      ViewerPlayer
    )
    let playerPos = vec2(
      x + PlayerScreenX.float32 * pixelScale,
      y + PlayerScreenY.float32 * pixelScale
    )
    for dot in bot.radarDots:
      let dotPos = vec2(
        x + dot.x.float32 * pixelScale + pixelScale * 0.5,
        y + dot.y.float32 * pixelScale + pixelScale * 0.5
      )
      sk.drawLine(playerPos, dotPos, ViewerRadarLine)
      sk.drawRect(dotPos - vec2(4, 4), vec2(9, 9), ViewerTaskGuess)
    for task in bot.sim.tasks:
      let
        taskX = task.x - bot.cameraX
        taskY = task.y - bot.cameraY
        taskVisible = taskX + task.w >= 0 and taskY + task.h >= 0 and
          taskX < ScreenWidth and taskY < ScreenHeight
      if not taskVisible:
        continue
      let
        icon = bot.taskIconInspectRect(task)
        hasIcon = bot.taskIconVisibleFor(task)
        color =
          if hasIcon:
            ViewerPlayer
          else:
            ViewerTask
        taskPos = vec2(
          x + taskX.float32 * pixelScale,
          y + taskY.float32 * pixelScale
        )
        taskSize = vec2(
          task.w.float32 * pixelScale,
          task.h.float32 * pixelScale
        )
      sk.drawOutline(taskPos, taskSize, color, 2)
      if icon.x + icon.w >= 0 and icon.y + icon.h >= 0 and
          icon.x < ScreenWidth and icon.y < ScreenHeight:
        let
          iconPos = vec2(
            x + icon.x.float32 * pixelScale,
            y + icon.y.float32 * pixelScale
          )
          iconSize = vec2(
            icon.w.float32 * pixelScale,
            icon.h.float32 * pixelScale
          )
        sk.drawOutline(iconPos, iconSize, color, 2)
        sk.drawLine(
          taskPos + taskSize * 0.5,
          iconPos + iconSize * 0.5,
          color
        )
    for icon in bot.visibleTaskIcons:
      sk.drawOutline(
        vec2(
          x + icon.x.float32 * pixelScale,
          y + icon.y.float32 * pixelScale
        ),
        vec2(
          bot.taskSprite.width.float32 * pixelScale,
          bot.taskSprite.height.float32 * pixelScale
        ),
        ViewerButton,
        2
      )

  proc drawMapView(sk: Silky, bot: Bot, x, y: float32) =
    ## Draws the map, inferred viewport, and known task stations.
    let scale = ViewerMapScale
    sk.drawRect(
      vec2(x, y),
      vec2(MapWidth.float32 * scale, MapHeight.float32 * scale),
      ViewerUnknown
    )
    for my in countup(0, MapHeight - 1, 2):
      for mx in countup(0, MapWidth - 1, 2):
        let idx = mapIndexSafe(mx, my)
        let color =
          if bot.sim.wallMask[idx]:
            ViewerWall
          elif bot.sim.walkMask[idx]:
            ViewerWalk
          else:
            sampleColor(bot.sim.mapPixels[idx])
        sk.drawRect(
          vec2(x + mx.float32 * scale, y + my.float32 * scale),
          vec2(max(1.0'f, scale * 2), max(1.0'f, scale * 2)),
          color
        )
    if bot.interstitial:
      return
    for i in 0 ..< bot.sim.tasks.len:
      let
        task = bot.sim.tasks[i]
        center = task.taskCenter()
        state =
          if bot.taskStates.len == bot.sim.tasks.len:
            bot.taskStates[i]
          else:
            TaskNotDoing
      sk.drawRect(
        vec2(x + center.x.float32 * scale - 3, y + center.y.float32 * scale - 3),
        vec2(7, 7),
        taskStateColor(state)
      )
    if bot.taskStates.len == bot.sim.tasks.len:
      for i in 0 ..< bot.sim.tasks.len:
        let
          isRadarTask =
            bot.radarTasks.len == bot.sim.tasks.len and bot.radarTasks[i]
          isCheckoutTask =
            bot.checkoutTasks.len == bot.sim.tasks.len and bot.checkoutTasks[i]
        if bot.taskStates[i] != TaskMandatory and
            not isRadarTask and
            not isCheckoutTask:
          continue
        let
          center = bot.sim.tasks[i].taskCenter()
          color =
            if bot.taskStates[i] == TaskMandatory:
              taskStateColor(TaskMandatory)
            else:
              taskStateColor(TaskMaybe)
          pos = vec2(
            x + center.x.float32 * scale - 5,
            y + center.y.float32 * scale - 5
          )
        sk.drawOutline(pos, vec2(11, 11), color, 2)
        if bot.localized:
          sk.drawLine(
            vec2(
              x + bot.playerWorldX().float32 * scale,
              y + bot.playerWorldY().float32 * scale
            ),
            pos + vec2(5, 5),
            ViewerRadarLine
          )
    let button = bot.sim.gameMap.button
    sk.drawOutline(
      vec2(
        x + button.x.float32 * scale,
        y + button.y.float32 * scale
      ),
      vec2(button.w.float32 * scale, button.h.float32 * scale),
      ViewerButton,
      1
    )
    if bot.localized:
      sk.drawOutline(
        vec2(x + bot.cameraX.float32 * scale, y + bot.cameraY.float32 * scale),
        vec2(ScreenWidth.float32 * scale, ScreenHeight.float32 * scale),
        ViewerViewport,
        1
      )
      sk.drawRect(
        vec2(
          x + bot.playerWorldX().float32 * scale - 2,
          y + bot.playerWorldY().float32 * scale - 2
        ),
        vec2(5, 5),
        ViewerPlayer
      )
      sk.drawCrewmateMapOutlines(bot, x, y, scale)
    if bot.homeSet:
      sk.drawOutline(
        vec2(x + bot.homeX.float32 * scale - 5, y + bot.homeY.float32 * scale - 5),
        vec2(10, 10),
        ViewerButton,
        1
      )
    if bot.hasGoal:
      sk.drawRect(
        vec2(x + bot.goalX.float32 * scale - 4, y + bot.goalY.float32 * scale - 4),
        vec2(9, 9),
        ViewerTask
      )
    if bot.path.len > 0:
      var previous = vec2(
        x + bot.playerWorldX().float32 * scale,
        y + bot.playerWorldY().float32 * scale
      )
      for i in countup(0, bot.path.high, 8):
        let current = vec2(
          x + bot.path[i].x.float32 * scale,
          y + bot.path[i].y.float32 * scale
        )
        sk.drawLine(previous, current, ViewerPath)
        previous = current
      if bot.hasGoal:
        sk.drawLine(
          previous,
          vec2(x + bot.goalX.float32 * scale, y + bot.goalY.float32 * scale),
          ViewerPath
        )
    if bot.hasPathStep:
      sk.drawRect(
        vec2(
          x + bot.pathStep.x.float32 * scale - 2,
          y + bot.pathStep.y.float32 * scale - 2
        ),
        vec2(5, 5),
        ViewerButton
      )

  proc initViewerApp(): ViewerApp =
    ## Opens the diagnostic viewer window.
    result = ViewerApp()
    result.window = newWindow(
      title = "Among Them Bot Viewer",
      size = ivec2(ViewerWindowWidth, ViewerWindowHeight),
      style = Decorated,
      visible = true
    )
    makeContextCurrent(result.window)
    when not defined(useDirectX):
      loadExtensions()
    result.silky = newSilky(result.window, atlasPath())

  proc pumpViewer(
    viewer: ViewerApp,
    bot: Bot,
    connected: bool,
    url: string
  ) =
    ## Pumps and renders one viewer frame.
    if viewer.isNil:
      return
    pollEvents()
    if viewer.window.buttonPressed[KeyEscape]:
      viewer.window.closeRequested = true
    if viewer.window.closeRequested:
      return
    let
      frameSize = viewer.window.size
      framePos = vec2(ViewerMargin, ViewerMargin + 28)
      mapPos = vec2(
        framePos.x + ScreenWidth.float32 * ViewerFrameScale + 24,
        ViewerMargin + 28
      )
      mapSize = vec2(MapWidth.float32 * ViewerMapScale, MapHeight.float32 * ViewerMapScale)
      infoPos = vec2(ViewerMargin, framePos.y + ScreenHeight.float32 * ViewerFrameScale + 28)
      infoSize = vec2(frameSize.x.float32 - ViewerMargin * 2, 300)
      sk = viewer.silky
    sk.beginUI(viewer.window, frameSize)
    sk.clearScreen(ViewerBackground)
    discard sk.drawText("Default", "Among Them Bot Viewer", vec2(ViewerMargin, ViewerMargin), ViewerText)
    discard sk.drawText("Default", "Live frame", vec2(framePos.x, framePos.y - 18), ViewerMutedText)
    discard sk.drawText("Default", "Map lock", vec2(mapPos.x, mapPos.y - 18), ViewerMutedText)
    sk.drawRect(
      framePos - vec2(8, 8),
      vec2(ScreenWidth.float32 * ViewerFrameScale + 16, ScreenHeight.float32 * ViewerFrameScale + 16),
      ViewerPanel
    )
    sk.drawRect(mapPos - vec2(8, 8), mapSize + vec2(16, 16), ViewerPanel)
    sk.drawRect(infoPos - vec2(8, 8), infoSize + vec2(16, 16), ViewerPanel)
    sk.drawFrameView(bot, framePos.x, framePos.y)
    sk.drawMapView(bot, mapPos.x, mapPos.y)
    let goalText =
      if bot.hasGoal:
        let ready =
          bot.goalIndex >= 0 and
          bot.goalIndex < bot.sim.tasks.len and
          bot.taskReadyAtGoal(bot.goalIndex, bot.goalX, bot.goalY)
        "goal: " & bot.goalName &
          " dist=" & $heuristic(
            bot.playerWorldX(),
            bot.playerWorldY(),
            bot.goalX,
            bot.goalY
          ) &
          " ready=" & $ready & "\n"
      else:
        "goal: none\n"
    let infoText =
      "intent: " & bot.intent & "\n" &
      "room: " & bot.roomName() & "\n" &
      "timing sprite scans: " & $bot.spriteScanMicros & "us (" &
        $(bot.spriteScanMicros div 1000) & "ms)\n" &
      "timing localize local: " & $bot.localizeLocalMicros & "us (" &
        $(bot.localizeLocalMicros div 1000) & "ms)\n" &
      "timing localize patch: " & $bot.localizePatchMicros & "us (" &
        $(bot.localizePatchMicros div 1000) & "ms)\n" &
      "timing localize spiral: " & $bot.localizeSpiralMicros & "us (" &
        $(bot.localizeSpiralMicros div 1000) & "ms)\n" &
      "timing pathing: " & $bot.astarMicros & "us (" &
        $(bot.astarMicros div 1000) & "ms)\n" &
      "client tick: " & $bot.frameTick & "\n" &
      "BUTTONS HELD: " & inputMaskSummary(bot.lastMask) & "\n" &
      "timing center: " & $bot.centerMicros & "us (" &
        $(bot.centerMicros div 1000) & "ms)\n" &
      "frames buffered: " & $bot.frameBufferLen &
        " dropped=" & $bot.framesDropped &
        " total=" & $bot.skippedFrames & "\n" &
      "interstitial text: " &
        (if bot.interstitialText.len > 0: bot.interstitialText else: "none") &
        "\n" &
      "lock: " & cameraLockName(bot.cameraLock) & " score=" & $bot.cameraScore & "\n" &
      "role: " & roleName(bot.role) &
        " self=" & playerColorName(bot.selfColorIndex) &
        " ghost=" & $bot.isGhost &
        " ghost icon frames=" & $bot.ghostIconFrames &
        " kill ready=" & $bot.imposterKillReady &
        " imp goal=" & $bot.imposterGoalIndex & "\n" &
      "known imps: " & bot.knownImposterSummary() & "\n" &
      "voting: " & $bot.voting &
        " count=" & $bot.votePlayerCount &
        " listen=" & $max(0, bot.frameTick - bot.voteStartTick) &
        " cursor=" & bot.voteTargetName(bot.voteCursor) &
        " target=" & bot.voteTargetName(bot.voteTarget) & "\n" &
      "votes: " & bot.voteSummary() & "\n" &
      "vote chat sus: " & playerColorName(bot.voteChatSusColor) &
        " text=" & bot.voteChatText & "\n" &
      "camera: (" & $bot.cameraX & ", " & $bot.cameraY & ")\n" &
      "player: (" & $bot.playerWorldX() & ", " & $bot.playerWorldY() & ")\n" &
      "home: " & (
        if bot.homeSet:
          "(" & $bot.homeX & ", " & $bot.homeY & ")"
        else:
          "unset"
      ) & " started=" & $bot.gameStarted & "\n" &
      "velocity: (" & $bot.velocityX & ", " & $bot.velocityY & ")\n" &
      "crewmates masked: " & $bot.visibleCrewmates.len &
        " bodies=" & $bot.visibleBodies.len &
        " ghosts=" & $bot.visibleGhosts.len & "\n" &
      "suspect: " & bot.suspectSummary() & "\n" &
      "radar dots: " & $bot.radarDots.len &
        " radar tasks=" & $bot.radarTaskCount() &
        " checkout=" & $bot.checkoutTaskCount() &
        " task icons=" & $bot.visibleTaskIcons.len & "\n" &
      "tasks mandatory=" & $bot.taskStateCount(TaskMandatory) &
        " completed=" & $bot.taskStateCount(TaskCompleted) & "\n" &
      goalText &
      "path pixels: " & $bot.path.len & "\n" &
      "desired: " & inputMaskSummary(bot.desiredMask) & "\n" &
      "controller: " & inputMaskSummary(bot.controllerMask) & "\n" &
      "stuck: " & $bot.stuckFrames & " jiggle=" & $bot.jiggleTicks & "\n" &
      "last thought: " & (
        if bot.lastThought.len > 0:
          bot.lastThought
        else:
          "waiting"
      ) & "\n" &
      "status: " & (if connected: "connected" else: "reconnecting") & "\n" &
      "url: " & url
    discard sk.drawText("Default", infoText, infoPos, ViewerText, infoSize.x, infoSize.y)
    sk.endUi()
    viewer.window.swapBuffers()

  proc viewerOpen(viewer: ViewerApp): bool =
    ## Returns true when the diagnostic viewer should keep running.
    viewer.isNil or not viewer.window.closeRequested

  proc queryEscape(value: string): string =
    ## Escapes a small string for use in a websocket query parameter.
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

  proc acceptPlayerMessage(
    ws: WebSocket,
    message: Message,
    queuedFrames: var seq[string]
  ) =
    ## Handles one websocket message while filling the local frame queue.
    case message.kind
    of BinaryMessage:
      if message.data.len == ProtocolBytes:
        queuedFrames.add(message.data)
    of Ping:
      ws.send(message.data, Pong)
    of TextMessage, Pong:
      discard

  proc receiveLatestFrame(ws: WebSocket, bot: var Bot, gui: bool): bool =
    ## Receives frames and only drops them under high backlog.
    if bot.queuedFrames.len == 0:
      let firstMessage = ws.receiveMessage(if gui: 10 else: -1)
      if firstMessage.isNone:
        bot.frameBufferLen = 0
        bot.framesDropped = 0
        return false
      ws.acceptPlayerMessage(firstMessage.get, bot.queuedFrames)

    var drained = 0
    while drained < MaxFrameDrain:
      let message = ws.receiveMessage(0)
      if message.isNone:
        break
      ws.acceptPlayerMessage(message.get, bot.queuedFrames)
      inc drained

    if bot.queuedFrames.len == 0:
      bot.frameBufferLen = 0
      bot.framesDropped = 0
      return false

    var
      frame = ""
      frameAdvance = 1
    bot.framesDropped = 0
    if bot.queuedFrames.len >= FrameDropThreshold:
      bot.framesDropped = bot.queuedFrames.len - 1
      frameAdvance = bot.queuedFrames.len
      frame = bot.queuedFrames[^1]
      bot.queuedFrames.setLen(0)
    else:
      frame = bot.queuedFrames[0]
      bot.queuedFrames.delete(0)

    bot.frameBufferLen = bot.queuedFrames.len
    bot.skippedFrames += bot.framesDropped
    if bot.framesDropped > 0:
      echo "frames dropped: ", bot.framesDropped,
        " buffered=", frameAdvance,
        " total=", bot.skippedFrames,
        " tick=", bot.frameTick + frameAdvance
    bot.frameTick += frameAdvance
    blobToBytes(frame, bot.packed)
    unpack4bpp(bot.packed, bot.unpacked)
    true

  proc runBot(
    host = DefaultHost,
    port = PlayerDefaultPort,
    gui = false,
    name = "",
    mapPath = ""
  ) =
    ## Connects to an Among Them server and processes player frames.
    var bot = initBot(mapPath)
    let url =
      if name.len > 0:
        "ws://" & host & ":" & $port & WebSocketPath &
          "?name=" & name.queryEscape()
      else:
        "ws://" & host & ":" & $port & WebSocketPath
    var
      viewer =
        if gui: initViewerApp()
        else: nil
      connected = false
    while viewer.viewerOpen():
      try:
        let ws = newWebSocket(url)
        var lastMask = 0xff'u8
        bot.queuedFrames.setLen(0)
        bot.frameBufferLen = 0
        bot.framesDropped = 0
        connected = true
        while viewer.viewerOpen():
          if gui:
            viewer.pumpViewer(bot, connected, url)
            if not viewer.viewerOpen():
              ws.close()
              break
          if not ws.receiveLatestFrame(bot, gui):
            continue
          let nextMask = bot.decideNextMask()
          bot.lastMask = nextMask
          if nextMask != lastMask:
            ws.send(blobFromMask(nextMask), BinaryMessage)
            lastMask = nextMask
          if bot.interstitial and
              bot.pendingChat.len > 0 and
              not bot.interstitialText.isGameOverText():
            ws.send(blobFromChat(bot.pendingChat), BinaryMessage)
            bot.pendingChat = ""
      except Exception:
        connected = false
        if gui:
          let reconnectStart = getMonoTime()
          while viewer.viewerOpen() and
              (getMonoTime() - reconnectStart).inMilliseconds < 250:
            viewer.pumpViewer(bot, connected, url)
            sleep(10)
        else:
          sleep(250)
