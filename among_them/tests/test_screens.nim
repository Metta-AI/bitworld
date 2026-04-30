import
  std/[os, strutils, unittest],
  pixie,
  ../../common/protocol,
  ../sim

const
  GameDir = currentSourcePath.parentDir.parentDir
  TestDir = currentSourcePath.parentDir
  GoldenDir = TestDir / "goldens"
  ActualDir = TestDir / "actual"

type
  ScreenCase = object
    name: string
    pixels: seq[uint8]

proc updateGoldens(): bool =
  ## Returns whether golden PNGs should be updated.
  when defined(updateGoldens) or defined(updateScreenGoldens):
    result = true
  else:
    let
      update = getEnv("UPDATE_GOLDENS").toLowerAscii()
      updateAmong = getEnv("AMONG_THEM_UPDATE_GOLDENS").toLowerAscii()
    result = update in ["1", "true", "yes"] or
      updateAmong in ["1", "true", "yes"]

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc addPlayers(sim: var SimServer, count: int) =
  ## Adds test players to the simulation.
  for i in 0 ..< count:
    discard sim.addPlayer("player" & $(i + 1))

proc screenConfig(): GameConfig =
  ## Returns a deterministic config for screen goldens.
  result = defaultGameConfig()
  result.minPlayers = 8
  result.imposterCount = 2
  result.autoImposterCount = false
  result.roleRevealTicks = 0
  result.startWaitTicks = 5 * TargetFps
  result.voteTimerTicks = 600
  result.tasksPerPlayer = 1

proc initScreenSim(playerCount = 8): SimServer =
  ## Builds a deterministic screen-test simulation.
  result = initAmongThemForTest(screenConfig())
  result.addPlayers(playerCount)
  for i in 0 ..< result.players.len:
    result.players[i].role =
      if i < 2: Imposter else: Crewmate
    result.players[i].alive = true

proc renderedPixels(sim: var SimServer, frame: seq[uint8]): seq[uint8] =
  ## Returns framebuffer pixels after a frame builder runs.
  discard frame
  sim.fb.indices

proc spectatorScreen(): seq[uint8] =
  ## Renders the game-in-progress spectator screen.
  var sim = initScreenSim(8)
  sim.renderedPixels(sim.buildSpectatorFrame())

proc needMoreScreen(): seq[uint8] =
  ## Renders the lobby screen waiting for more players.
  var sim = initScreenSim(3)
  sim.config.minPlayers = 5
  sim.renderedPixels(sim.buildLobbyFrame(0))

proc gameStartingScreen(): seq[uint8] =
  ## Renders the lobby game-starting countdown screen.
  var sim = initScreenSim(5)
  sim.config.minPlayers = 5
  sim.startWaitTimer = sim.config.startWaitTicks
  sim.renderedPixels(sim.buildLobbyFrame(0))

proc voteScreen(): seq[uint8] =
  ## Renders the voting screen with votes and chat.
  var sim = initScreenSim(8)
  sim.startVote()
  sim.voteState.cursor[0] = sim.players.len
  sim.voteState.votes[0] = -2
  sim.voteState.votes[1] = 3
  sim.voteState.votes[2] = 3
  sim.voteState.votes[3] = 1
  sim.addVotingChat(0, "red sus")
  sim.addVotingChat(2, "body in nav")
  sim.addVotingChat(4, "skip maybe")
  sim.renderedPixels(sim.buildVoteFrame(0))

proc resultNoOneScreen(): seq[uint8] =
  ## Renders the vote result screen with no ejection.
  var sim = initScreenSim(8)
  sim.phase = VoteResult
  sim.voteState.ejectedPlayer = -1
  sim.renderedPixels(sim.buildResultFrame(0))

proc resultPlayerScreen(): seq[uint8] =
  ## Renders the vote result screen with one ejected player.
  var sim = initScreenSim(8)
  sim.phase = VoteResult
  sim.voteState.ejectedPlayer = 3
  sim.renderedPixels(sim.buildResultFrame(0))

proc victoryScreen(): seq[uint8] =
  ## Renders the crew victory screen.
  var sim = initScreenSim(8)
  sim.players[1].alive = false
  sim.finishGame(Crewmate)
  sim.renderedPixels(sim.buildGameOverFrame(0))

proc screenCases(): seq[ScreenCase] =
  ## Renders all golden-master screen cases.
  @[
    ScreenCase(name: "game_in_progress", pixels: spectatorScreen()),
    ScreenCase(name: "need_more", pixels: needMoreScreen()),
    ScreenCase(name: "game_starting", pixels: gameStartingScreen()),
    ScreenCase(name: "vote", pixels: voteScreen()),
    ScreenCase(name: "result_no_one", pixels: resultNoOneScreen()),
    ScreenCase(name: "result_player", pixels: resultPlayerScreen()),
    ScreenCase(name: "victory", pixels: victoryScreen())
  ]

proc pngBytes(pixels: openArray[uint8]): string =
  ## Encodes framebuffer pixels as a PNG blob.
  var image = newImage(ScreenWidth, ScreenHeight)
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      let index = pixels[y * ScreenWidth + x].int
      if index >= 0 and index < Palette.len:
        let swatch = Palette[index]
        image[x, y] = rgbx(swatch.r, swatch.g, swatch.b, swatch.a)
  image.encodeImage(PngFormat)

proc checkGolden(name: string, pixels: openArray[uint8], update: bool) =
  ## Updates or checks one screen golden PNG.
  let
    path = GoldenDir / (name & ".png")
    actualPath = ActualDir / (name & ".png")
    actual = pngBytes(pixels)
  if update:
    createDir(GoldenDir)
    writeFile(path, actual)
  else:
    require fileExists(path)
    let expected = readFile(path)
    if expected != actual:
      createDir(ActualDir)
      writeFile(actualPath, actual)
      checkpoint "actual written to " & actualPath
    check expected == actual

suite "screen goldens":
  test "screens match golden PNGs":
    let update = updateGoldens()
    for screen in screenCases():
      checkpoint screen.name
      checkGolden(screen.name, screen.pixels, update)
