import
  std/[os, unittest],
  ../sim,
  ../texts,
  ../../common/pixelfonts,
  ../../common/protocol,
  ../../common/server

const
  GameDir = currentSourcePath.parentDir.parentDir
  RootDir = GameDir.parentDir

type TextCase = object
  text: string
  x: int
  y: int

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc loadTestAsciiSprites(): PixelFont =
  ## Loads the Among Them tiny ASCII font for text OCR tests.
  loadPalette(RootDir / "clients" / "data" / "pallete.png")
  loadAsciiSprites(GameDir / "tiny5.aseprite")

proc renderText(
  asciiSprites: PixelFont,
  text: string,
  x,
  y: int
): seq[uint8] =
  ## Draws one text sample to a fresh 128 by 128 framebuffer.
  var fb = initFramebuffer()
  fb.clearFrame(SpaceColor)
  fb.blitAsciiText(asciiSprites, text, x, y)
  fb.indices

proc assertTextRoundTrip(
  asciiSprites: PixelFont,
  sample: TextCase
) =
  ## Checks that rendered text can be read back from pixels.
  checkpoint sample.text
  require sample.x + asciiSprites.asciiTextWidth(sample.text) <= ScreenWidth
  require sample.y + asciiSprites.height <= ScreenHeight

  let
    frame = renderText(asciiSprites, sample.text, sample.x, sample.y)
    found = frame.findAsciiText(asciiSprites, sample.text)
    read = frame.readAsciiRun(
      asciiSprites,
      sample.x,
      sample.y,
      sample.text.len
    )

  check found.found
  check found.x == sample.x
  check found.y == sample.y
  check read == sample.text

proc addPlayers(sim: var SimServer, count: int) =
  ## Adds test players to the simulation.
  for i in 0 ..< count:
    discard sim.addPlayer("player" & $(i + 1))

proc votingChatY(playerCount: int): int =
  ## Returns the first text y coordinate in the voting chat panel.
  let
    cols = min(playerCount, 8)
    rows = (playerCount + cols - 1) div cols
    skipY = 2 + rows * 17 + 1
  skipY + 11

proc usefulChatLine(line: string): bool =
  ## Returns true when a scanned chat line is usable text.
  var
    letters = 0
    unknown = 0
  for ch in line:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'}:
      inc letters
    elif ch == '?':
      inc unknown
  letters >= 2 and unknown * 2 <= max(1, line.len)

proc scanVotingChatRows(
  frame: openArray[uint8],
  asciiSprites: PixelFont,
  startY: int
): seq[string] =
  ## Scans voting chat rows the same way the player does.
  var previous = ""
  var previousY = low(int)
  for y in startY ..< ScreenHeight - 6:
    let line = frame.readAsciiRun(
      asciiSprites,
      VoteChatTextX,
      y,
      VoteChatCharsPerLine
    )
    if not line.usefulChatLine():
      continue
    if line == previous and y - previousY <= 2:
      continue
    result.add(line)
    previous = line
    previousY = y

suite "ascii text":
  test "round trips":
    let
      asciiSprites = loadTestAsciiSprites()
      cases = [
        TextCase(text: "red sus", x: 0, y: 0),
        TextCase(text: "body in nav", x: 21, y: 48),
        TextCase(text: "pink saw blue", x: 7, y: 83),
        TextCase(text: "light blue sus", x: 30, y: 14),
        TextCase(text: "where?", x: 72, y: 119),
        TextCase(text: "red, sus!", x: 12, y: 101)
      ]
    for sample in cases:
      assertTextRoundTrip(asciiSprites, sample)

  test "voting chat round trips":
    var config = defaultGameConfig()
    config.minPlayers = 8
    config.tasksPerPlayer = 1
    var sim = initAmongThemForTest(config)
    sim.addPlayers(8)
    sim.startVote()
    let messages = [
      "red sus",
      "body in nav",
      "blue covered red",
      "green did tasks",
      "yellow saw lime",
      "skip maybe"
    ]
    for i, message in messages:
      sim.addVotingChat(i, message)
    discard sim.buildVoteFrame(0)

    let
      y = votingChatY(sim.players.len)
      scanned = sim.fb.indices.scanVotingChatRows(sim.asciiSprites, y)
      first = sim.fb.indices.readAsciiRun(
        sim.asciiSprites,
        VoteChatTextX,
        y,
        VoteChatCharsPerLine
      )
      second = sim.fb.indices.readAsciiRun(
        sim.asciiSprites,
        VoteChatTextX,
        y + 13,
        VoteChatCharsPerLine
      )

    check first == "red sus"
    check second == "body in nav"
    check scanned == @messages

  test "dark background is ignored":
    var sim = initAmongThemForTest(defaultGameConfig())
    let text = "red sus"
    sim.clearInterstitialFrame()
    check not sim.fb.indices.findAsciiText(sim.asciiSprites, text).found
    sim.fb.blitAsciiText(sim.asciiSprites, text, 13, 47)
    let
      found = sim.fb.indices.findAsciiText(sim.asciiSprites, text)
      line = sim.fb.indices.readAsciiRun(
        sim.asciiSprites,
        found.x,
        found.y,
        text.len
      )
    check found.found
    check line == text

  test "chat wrap drops leading space":
    let
      font = loadTestAsciiSprites()
      message = "hi there i am not that bad i did all that and this thing"
      first = font.sliceChatLine(message, 0)
      second = font.sliceChatLine(message, 1)
    check first.len > 15
    check font.textWidth(first) <= VoteChatTextPixels
    require second.len > 0
    check second[0] != ' '
    check font.chatLineCount(message) >= 2

    let trailingSpace = "short trailing "
    check font.chatLineCount(trailingSpace) == 1
