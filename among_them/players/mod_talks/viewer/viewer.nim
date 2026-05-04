## Debug GUI: live framebuffer view, map view, status panel.
##
## Phase 2 port from v2:4229-4707. Behavior preserved verbatim modulo
## sub-record renames (`bot.cameraX` → `bot.percep.cameraX` etc).
##
## Gated by `when not defined(modulabotLibrary)` because it depends on
## `silky/whisky/windy` which aren't available in shared-library
## builds. The whole subdirectory is unused for FFI/library targets.
##
## ## Layout
##
## Three panels in a single window:
##   - Top-left: live 128×128 frame at 4× scale, with crewmate / task
##     overlays and radar-dot lines.
##   - Top-right: full map at 1.25× scale, with viewport rectangle,
##     task-state markers, A* path overlay, home marker, goal marker.
##   - Bottom: ~30 lines of status text (intent, role, voting state,
##     timing micros, suspect summary, etc).

when not defined(modulabotLibrary):
  import pixie
  import vmath
  import silky
  import windy

  import protocol
  import ../../../sim

  import ../types
  import ../geometry
  import ../frame
  import ../path           ## heuristic
  import ../tasks          ## taskIconInspectRect / taskIconVisibleFor /
                            ## taskReadyAtGoal / taskStateCount /
                            ## radarTaskCount / checkoutTaskCount
  import ../voting         ## voteSummary, voteTargetName
  import ../evidence       ## knownImposterColor, playerColorName,
                            ## knownImposterSummary, suspectSummary
  import ../diag           ## roleName, cameraLockName, inputMaskSummary

  # ---------------------------------------------------------------------
  # Constants (module-local per Q9 — viewer-only colors / sizes)
  # ---------------------------------------------------------------------

  const
    ViewerWindowWidth = 1820
    ViewerWindowHeight = 1060
    ViewerMargin = 16.0'f
    ViewerFrameScale = 4.0'f
    ViewerMapScale = 1.25'f
    ViewerBackground = rgbx(17, 20, 28, 255)
    ViewerPanel = rgbx(33, 38, 50, 255)
    ViewerPanelAlt = rgbx(25, 30, 41, 255)
    ViewerText = rgbx(226, 231, 240, 255)
    ViewerMutedText = rgbx(146, 155, 172, 255)
    ViewerViewport = rgbx(142, 193, 255, 180)
    ViewerButton = rgbx(255, 196, 88, 255)
    ViewerPlayer = rgbx(120, 255, 170, 255)
    ViewerCrew = rgbx(82, 168, 255, 255)
    ViewerImp = rgbx(255, 84, 96, 255)
    ViewerTask = rgbx(255, 132, 146, 255)
    ViewerTaskGuess = rgbx(255, 220, 92, 255)
    ViewerRadarLine = rgbx(255, 220, 92, 210)
    ViewerPath = rgbx(119, 218, 255, 230)
    ViewerWalk = rgbx(46, 61, 75, 255)
    ViewerWall = rgbx(86, 50, 56, 255)
    ViewerUnknown = rgbx(22, 26, 36, 255)

  # ---------------------------------------------------------------------
  # Viewer app state
  # ---------------------------------------------------------------------

  type
    ViewerApp* = ref object
      window*: Window
      silky*: Silky

  # ---------------------------------------------------------------------
  # Drawing primitives
  # ---------------------------------------------------------------------

  proc drawOutline(sk: Silky, pos, size: Vec2, color: ColorRGBX,
                  thickness = 1.0'f) =
    sk.drawRect(pos, vec2(size.x, thickness), color)
    sk.drawRect(vec2(pos.x, pos.y + size.y - thickness),
                vec2(size.x, thickness), color)
    sk.drawRect(pos, vec2(thickness, size.y), color)
    sk.drawRect(vec2(pos.x + size.x - thickness, pos.y),
                vec2(thickness, size.y), color)

  proc drawLine(sk: Silky, a, b: Vec2, color: ColorRGBX) =
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
    case state
    of TaskNotDoing: ViewerTask
    of TaskMaybe: ViewerTaskGuess
    of TaskMandatory: ViewerButton
    of TaskCompleted: ViewerMutedText

  proc crewmateOutlineColor(bot: Bot, colorIndex: int): ColorRGBX =
    if bot.knownImposterColor(colorIndex):
      ViewerImp
    else:
      ViewerCrew

  # ---------------------------------------------------------------------
  # Frame-space drawers (top-left panel)
  # ---------------------------------------------------------------------

  proc drawCrewmateFrameOutlines(sk: Silky, bot: Bot,
                                x, y, scale: float32) =
    for crewmate in bot.percep.visibleCrewmates:
      sk.drawOutline(
        vec2(x + crewmate.x.float32 * scale,
             y + crewmate.y.float32 * scale),
        vec2(bot.sprites.player.width.float32 * scale,
             bot.sprites.player.height.float32 * scale),
        bot.crewmateOutlineColor(crewmate.colorIndex),
        2
      )

  proc drawFrameView(sk: Silky, bot: Bot, x, y: float32) =
    let pixelScale = ViewerFrameScale
    sk.drawRect(
      vec2(x, y),
      vec2(ScreenWidth.float32 * pixelScale,
           ScreenHeight.float32 * pixelScale),
      ViewerPanelAlt
    )
    for py in 0 ..< ScreenHeight:
      for px in 0 ..< ScreenWidth:
        let index = bot.io.unpacked[py * ScreenWidth + px]
        sk.drawRect(
          vec2(x + px.float32 * pixelScale, y + py.float32 * pixelScale),
          vec2(pixelScale, pixelScale),
          sampleColor(index)
        )
    sk.drawCrewmateFrameOutlines(bot, x, y, pixelScale)
    if bot.percep.interstitial:
      return
    let
      button = bot.sim.gameMap.button
      buttonX = button.x - bot.percep.cameraX
      buttonY = button.y - bot.percep.cameraY
    if buttonX + button.w >= 0 and buttonY + button.h >= 0 and
        buttonX < ScreenWidth and buttonY < ScreenHeight:
      sk.drawOutline(
        vec2(x + buttonX.float32 * pixelScale,
             y + buttonY.float32 * pixelScale),
        vec2(button.w.float32 * pixelScale, button.h.float32 * pixelScale),
        ViewerButton,
        2
      )
    sk.drawRect(
      vec2(x + PlayerScreenX.float32 * pixelScale - 3,
           y + PlayerScreenY.float32 * pixelScale - 3),
      vec2(7, 7),
      ViewerPlayer
    )
    let playerPos = vec2(
      x + PlayerScreenX.float32 * pixelScale,
      y + PlayerScreenY.float32 * pixelScale
    )
    for dot in bot.percep.radarDots:
      let dotPos = vec2(
        x + dot.x.float32 * pixelScale + pixelScale * 0.5,
        y + dot.y.float32 * pixelScale + pixelScale * 0.5
      )
      sk.drawLine(playerPos, dotPos, ViewerRadarLine)
      sk.drawRect(dotPos - vec2(4, 4), vec2(9, 9), ViewerTaskGuess)
    for task in bot.sim.tasks:
      let
        taskX = task.x - bot.percep.cameraX
        taskY = task.y - bot.percep.cameraY
        taskVisible = taskX + task.w >= 0 and taskY + task.h >= 0 and
          taskX < ScreenWidth and taskY < ScreenHeight
      if not taskVisible:
        continue
      let
        icon = bot.taskIconInspectRect(task)
        hasIcon = bot.taskIconVisibleFor(task)
        color = if hasIcon: ViewerPlayer else: ViewerTask
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
    for icon in bot.percep.visibleTaskIcons:
      sk.drawOutline(
        vec2(x + icon.x.float32 * pixelScale,
             y + icon.y.float32 * pixelScale),
        vec2(bot.sprites.task.width.float32 * pixelScale,
             bot.sprites.task.height.float32 * pixelScale),
        ViewerButton,
        2
      )

  # ---------------------------------------------------------------------
  # Map-space drawers (top-right panel)
  # ---------------------------------------------------------------------

  proc drawCrewmateMapOutlines(sk: Silky, bot: Bot,
                              x, y, scale: float32) =
    if not bot.percep.localized:
      return
    for crewmate in bot.percep.visibleCrewmates:
      let
        world = bot.percep.visibleCrewmateWorld(crewmate)
        spriteX = world.x - SpriteDrawOffX
        spriteY = world.y - SpriteDrawOffY
      sk.drawOutline(
        vec2(x + spriteX.float32 * scale, y + spriteY.float32 * scale),
        vec2(bot.sprites.player.width.float32 * scale,
             bot.sprites.player.height.float32 * scale),
        bot.crewmateOutlineColor(crewmate.colorIndex),
        2
      )

  proc drawMapView(sk: Silky, bot: Bot, x, y: float32) =
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
          if bot.sim.wallMask[idx]: ViewerWall
          elif bot.sim.walkMask[idx]: ViewerWalk
          else: sampleColor(bot.sim.mapPixels[idx])
        sk.drawRect(
          vec2(x + mx.float32 * scale, y + my.float32 * scale),
          vec2(max(1.0'f, scale * 2), max(1.0'f, scale * 2)),
          color
        )
    if bot.percep.interstitial:
      return
    for i in 0 ..< bot.sim.tasks.len:
      let
        task = bot.sim.tasks[i]
        center = task.taskCenter()
        state =
          if bot.tasks.states.len == bot.sim.tasks.len:
            bot.tasks.states[i]
          else:
            TaskNotDoing
      sk.drawRect(
        vec2(x + center.x.float32 * scale - 3,
             y + center.y.float32 * scale - 3),
        vec2(7, 7),
        taskStateColor(state)
      )
    if bot.tasks.states.len == bot.sim.tasks.len:
      for i in 0 ..< bot.sim.tasks.len:
        let
          isRadarTask = bot.tasks.radar.len == bot.sim.tasks.len and
            bot.tasks.radar[i]
          isCheckoutTask = bot.tasks.checkout.len == bot.sim.tasks.len and
            bot.tasks.checkout[i]
        if bot.tasks.states[i] != TaskMandatory and
            not isRadarTask and not isCheckoutTask:
          continue
        let
          center = bot.sim.tasks[i].taskCenter()
          color =
            if bot.tasks.states[i] == TaskMandatory:
              taskStateColor(TaskMandatory)
            else:
              taskStateColor(TaskMaybe)
          pos = vec2(x + center.x.float32 * scale - 5,
                     y + center.y.float32 * scale - 5)
        sk.drawOutline(pos, vec2(11, 11), color, 2)
        if bot.percep.localized:
          sk.drawLine(
            vec2(x + bot.percep.playerWorldX().float32 * scale,
                 y + bot.percep.playerWorldY().float32 * scale),
            pos + vec2(5, 5),
            ViewerRadarLine
          )
    let button = bot.sim.gameMap.button
    sk.drawOutline(
      vec2(x + button.x.float32 * scale,
           y + button.y.float32 * scale),
      vec2(button.w.float32 * scale, button.h.float32 * scale),
      ViewerButton,
      1
    )
    if bot.percep.localized:
      sk.drawOutline(
        vec2(x + bot.percep.cameraX.float32 * scale,
             y + bot.percep.cameraY.float32 * scale),
        vec2(ScreenWidth.float32 * scale, ScreenHeight.float32 * scale),
        ViewerViewport,
        1
      )
      sk.drawRect(
        vec2(x + bot.percep.playerWorldX().float32 * scale - 2,
             y + bot.percep.playerWorldY().float32 * scale - 2),
        vec2(5, 5),
        ViewerPlayer
      )
      sk.drawCrewmateMapOutlines(bot, x, y, scale)
    if bot.percep.homeSet:
      sk.drawOutline(
        vec2(x + bot.percep.homeX.float32 * scale - 5,
             y + bot.percep.homeY.float32 * scale - 5),
        vec2(10, 10),
        ViewerButton,
        1
      )
    if bot.goal.has:
      sk.drawRect(
        vec2(x + bot.goal.x.float32 * scale - 4,
             y + bot.goal.y.float32 * scale - 4),
        vec2(9, 9),
        ViewerTask
      )
    if bot.goal.path.len > 0:
      var previous = vec2(
        x + bot.percep.playerWorldX().float32 * scale,
        y + bot.percep.playerWorldY().float32 * scale
      )
      for i in countup(0, bot.goal.path.high, 8):
        let current = vec2(
          x + bot.goal.path[i].x.float32 * scale,
          y + bot.goal.path[i].y.float32 * scale
        )
        sk.drawLine(previous, current, ViewerPath)
        previous = current
      if bot.goal.has:
        sk.drawLine(
          previous,
          vec2(x + bot.goal.x.float32 * scale,
               y + bot.goal.y.float32 * scale),
          ViewerPath
        )
    if bot.goal.hasPathStep:
      sk.drawRect(
        vec2(x + bot.goal.pathStep.x.float32 * scale - 2,
             y + bot.goal.pathStep.y.float32 * scale - 2),
        vec2(5, 5),
        ViewerButton
      )

  # ---------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------

  proc initViewerApp*(atlasPath: string): ViewerApp =
    ## Opens the diagnostic viewer window. `atlasPath` should match
    ## `bot.paths.atlasPath` — usually `bitworld/clients/dist/atlas.png`.
    result = ViewerApp()
    result.window = newWindow(
      title = "Modulabot Viewer",
      size = ivec2(ViewerWindowWidth, ViewerWindowHeight),
      style = Decorated,
      visible = true
    )
    makeContextCurrent(result.window)
    when not defined(useDirectX):
      loadExtensions()
    result.silky = newSilky(result.window, atlasPath)

  proc viewerOpen*(viewer: ViewerApp): bool =
    ## True when the viewer is nil (headless mode) or its window is
    ## still alive. Used by the runner's outer reconnect loop.
    viewer.isNil or not viewer.window.closeRequested

  proc pumpViewer*(viewer: ViewerApp, bot: Bot, connected: bool,
                  url: string) =
    ## Pumps Windy events and renders one viewer frame. No-op when
    ## `viewer` is nil.
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
      mapSize = vec2(MapWidth.float32 * ViewerMapScale,
                     MapHeight.float32 * ViewerMapScale)
      infoPos = vec2(ViewerMargin,
                     framePos.y + ScreenHeight.float32 * ViewerFrameScale + 28)
      infoSize = vec2(frameSize.x.float32 - ViewerMargin * 2, 300)
      sk = viewer.silky
    sk.beginUI(viewer.window, frameSize)
    sk.clearScreen(ViewerBackground)
    discard sk.drawText("Default", "Modulabot Viewer",
                        vec2(ViewerMargin, ViewerMargin), ViewerText)
    discard sk.drawText("Default", "Live frame",
                        vec2(framePos.x, framePos.y - 18), ViewerMutedText)
    discard sk.drawText("Default", "Map lock",
                        vec2(mapPos.x, mapPos.y - 18), ViewerMutedText)
    sk.drawRect(
      framePos - vec2(8, 8),
      vec2(ScreenWidth.float32 * ViewerFrameScale + 16,
           ScreenHeight.float32 * ViewerFrameScale + 16),
      ViewerPanel
    )
    sk.drawRect(mapPos - vec2(8, 8), mapSize + vec2(16, 16), ViewerPanel)
    sk.drawRect(infoPos - vec2(8, 8), infoSize + vec2(16, 16), ViewerPanel)
    sk.drawFrameView(bot, framePos.x, framePos.y)
    sk.drawMapView(bot, mapPos.x, mapPos.y)
    let goalText =
      if bot.goal.has:
        let ready =
          bot.goal.index >= 0 and
          bot.goal.index < bot.sim.tasks.len and
          bot.taskReadyAtGoal(bot.goal.index, bot.goal.x, bot.goal.y)
        "goal: " & bot.goal.name &
          " dist=" & $heuristic(
            bot.percep.playerWorldX(),
            bot.percep.playerWorldY(),
            bot.goal.x,
            bot.goal.y
          ) &
          " ready=" & $ready & "\n"
      else:
        "goal: none\n"
    let infoText =
      "intent: " & bot.diag.intent & "\n" &
      "room: " & bot.percep.roomName(bot.sim) & "\n" &
      "timing sprite scans: " & $bot.perf.spriteScanMicros & "us (" &
        $(bot.perf.spriteScanMicros div 1000) & "ms)\n" &
      "timing localize local: " & $bot.perf.localizeLocalMicros & "us (" &
        $(bot.perf.localizeLocalMicros div 1000) & "ms)\n" &
      "timing localize patch: " & $bot.perf.localizePatchMicros & "us (" &
        $(bot.perf.localizePatchMicros div 1000) & "ms)\n" &
      "timing localize spiral: " & $bot.perf.localizeSpiralMicros & "us (" &
        $(bot.perf.localizeSpiralMicros div 1000) & "ms)\n" &
      "timing pathing: " & $bot.perf.astarMicros & "us (" &
        $(bot.perf.astarMicros div 1000) & "ms)\n" &
      "client tick: " & $bot.frameTick & "\n" &
      "BUTTONS HELD: " & inputMaskSummary(bot.io.lastMask) & "\n" &
      "timing center: " & $bot.perf.centerMicros & "us (" &
        $(bot.perf.centerMicros div 1000) & "ms)\n" &
      "frames buffered: " & $bot.io.frameBufferLen &
        " dropped=" & $bot.io.framesDropped &
        " total=" & $bot.io.skippedFrames & "\n" &
      "interstitial text: " &
        (if bot.percep.interstitialText.len > 0:
           bot.percep.interstitialText else: "none") & "\n" &
      "lock: " & cameraLockName(bot.percep.cameraLock) &
        " score=" & $bot.percep.cameraScore & "\n" &
      "role: " & roleName(bot.role) &
        " self=" & playerColorName(bot.identity.selfColor) &
        " ghost=" & $bot.isGhost &
        " ghost icon frames=" & $bot.ghostIconFrames &
        " kill ready=" & $bot.imposter.killReady &
        " imp goal=" & $bot.imposter.goalIndex & "\n" &
      "known imps: " & bot.knownImposterSummary() & "\n" &
      "voting: " & $bot.voting.active &
        " count=" & $bot.voting.playerCount &
        " listen=" & $max(0, bot.frameTick - bot.voting.startTick) &
        " cursor=" & bot.voteTargetName(bot.voting.cursor) &
        " target=" & bot.voteTargetName(bot.voting.target) & "\n" &
      "votes: " & bot.voteSummary() & "\n" &
      "vote chat sus: " & playerColorName(bot.voting.chatSusColor) &
        " text=" & bot.voting.chatText & "\n" &
      "camera: (" & $bot.percep.cameraX & ", " & $bot.percep.cameraY & ")\n" &
      "player: (" & $bot.percep.playerWorldX() & ", " &
        $bot.percep.playerWorldY() & ")\n" &
      "home: " & (
        if bot.percep.homeSet:
          "(" & $bot.percep.homeX & ", " & $bot.percep.homeY & ")"
        else:
          "unset"
      ) & " started=" & $bot.percep.gameStarted & "\n" &
      "velocity: (" & $bot.motion.velocityX & ", " &
        $bot.motion.velocityY & ")\n" &
      "crewmates masked: " & $bot.percep.visibleCrewmates.len &
        " bodies=" & $bot.percep.visibleBodies.len &
        " ghosts=" & $bot.percep.visibleGhosts.len & "\n" &
      "suspect: " & bot.suspectSummary() & "\n" &
      "radar dots: " & $bot.percep.radarDots.len &
        " radar tasks=" & $bot.radarTaskCount() &
        " checkout=" & $bot.checkoutTaskCount() &
        " task icons=" & $bot.percep.visibleTaskIcons.len & "\n" &
      "tasks mandatory=" & $bot.taskStateCount(TaskMandatory) &
        " completed=" & $bot.taskStateCount(TaskCompleted) & "\n" &
      goalText &
      "path pixels: " & $bot.goal.path.len & "\n" &
      "desired: " & inputMaskSummary(bot.motion.desiredMask) & "\n" &
      "controller: " & inputMaskSummary(bot.motion.controllerMask) & "\n" &
      "stuck: " & $bot.motion.stuckFrames &
        " jiggle=" & $bot.motion.jiggleTicks & "\n" &
      "last thought: " & (
        if bot.diag.lastThought.len > 0:
          bot.diag.lastThought
        else:
          "waiting"
      ) & "\n" &
      "status: " & (if connected: "connected" else: "reconnecting") & "\n" &
      "url: " & url
    discard sk.drawText("Default", infoText, infoPos, ViewerText,
                        infoSize.x, infoSize.y)
    sk.endUi()
    viewer.window.swapBuffers()
