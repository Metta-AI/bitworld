import
  std/os,
  ../among_them/sim,
  ../among_them/texts,
  ../common/pixelfonts,
  ../common/protocol,
  ../common/server

const RootDir = currentSourcePath.parentDir.parentDir

type TextCase = object
  text: string
  x: int
  y: int

proc initAmongThemForTest(config: GameConfig): SimServer =
  ## Initializes Among Them from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(RootDir / "among_them")
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc loadTestAsciiSprites(): PixelFont =
  ## Loads the Among Them tiny ASCII font for text OCR tests.
  loadPalette(RootDir / "clients" / "data" / "pallete.png")
  loadAsciiSprites(RootDir / "among_them" / "tiny5.aseprite")

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
  doAssert sample.x + asciiSprites.asciiTextWidth(sample.text) <= ScreenWidth,
    "test text should fit on the screen"
  doAssert sample.y + asciiSprites.height <= ScreenHeight,
    "test text should fit vertically"

  let
    frame = renderText(asciiSprites, sample.text, sample.x, sample.y)
    found = frame.findAsciiText(asciiSprites, sample.text)
    read = frame.readAsciiRun(
      asciiSprites,
      sample.x,
      sample.y,
      sample.text.len
    )

  doAssert found.found, "OCR should find text: " & sample.text
  doAssert found.x == sample.x,
    "OCR should find the expected x for " & sample.text
  doAssert found.y == sample.y,
    "OCR should find the expected y for " & sample.text
  doAssert read == sample.text,
    "OCR should read " & sample.text & ", got " & read

proc testAsciiTextRoundTrips() =
  ## Tests text OCR at several screen locations.
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

proc testVotingChatTextRoundTrip() =
  ## Tests OCR on chat text inside a rendered voting frame.
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

  doAssert first == "red sus", "first chat line should survive voting UI"
  doAssert second == "body in nav", "second chat line should survive voting UI"
  doAssert scanned == @messages,
    "voting chat scan should preserve six visible messages"

proc testChatWrapDropsLeadingSpace() =
  ## Tests that wrapped chat lines do not start with split spaces.
  let
    font = loadTestAsciiSprites()
    message = "hi there i am not that bad i did all that and this thing"
    first = font.sliceChatLine(message, 0)
    second = font.sliceChatLine(message, 1)
  doAssert first.len > 15,
    "first wrapped chat line should use the tiny font width"
  doAssert font.textWidth(first) <= VoteChatTextPixels,
    "first wrapped chat line should fit the screen width"
  doAssert second.len > 0 and second[0] != ' ',
    "second wrapped chat line should skip the split space"
  doAssert font.chatLineCount(message) >= 2,
    "wrapped chat should count only visible lines"

  let trailingSpace = "short trailing "
  doAssert font.chatLineCount(trailingSpace) == 1,
    "trailing split spaces should not create an empty line"

testAsciiTextRoundTrips()
testVotingChatTextRoundTrip()
testChatWrapDropsLeadingSpace()
echo "All tests passed"
