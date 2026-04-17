import client, server, windy
import std/monotimes

const TargetFps = 24.0

when isMainModule:
  var
    app = initClient()
    sim = initSimServer()
    lastTick = getMonoTime()

  while app.windowOpen:
    pollEvents()
    if app.window.buttonPressed[KeyEscape]:
      app.window.closeRequested = true
    sim.step(app.captureInput())
    app.drawFramebuffer(sim.buildFramePacket())
    runFrameLimiter(TargetFps, lastTick)
