import
  std/[monotimes, os, parseutils, strutils, times],
  pixie,
  sim, ../common/protocol, ../common/server

const
  SampleWidth = ScreenWidth
  SampleHeight = ScreenHeight
  DefaultCenterX = ButtonX + ButtonW div 2
  DefaultCenterY = ButtonY + ButtonH div 2
  DefaultRuns = 5
  Black = SpaceColor

type
  PositionCenter = object
    x: int
    y: int

  ScanCase = object
    center: PositionCenter
    cameraX: int
    cameraY: int
    view: Sprite

  ScanMatch = object
    found: bool
    exact: bool
    x: int
    y: int
    errors: int
    compared: int
    candidates: int

  BenchConfig = object
    center: PositionCenter
    runs: int
    maxErrors: int
    outputDir: string
    writeImages: bool

proc usage(): string =
  ## Returns command line help for the scan benchmark.
  "Usage:\n" &
    "  nim r among_them/bench_scan.nim -- [options]\n\n" &
    "Options:\n" &
    "  --center:x,y      PositionCenter to sample around.\n" &
    "  --runs:n          Number of timed scan runs.\n" &
    "  --max-errors:n    Stop once a match has at most this many errors.\n" &
    "  --out:dir         Write sample and marked map PNGs.\n" &
    "  --help            Show this help.\n"

proc fail(message: string) =
  ## Prints one error with usage and exits.
  stderr.writeLine("bench_scan: " & message)
  stderr.writeLine("")
  stderr.writeLine(usage())
  quit(1)

proc parsePair(text: string): PositionCenter =
  ## Parses an x,y integer pair.
  var
    index = 0
    value = 0
  let parsedX = parseInt(text, value, index)
  if parsedX == 0:
    fail("Expected a center like x,y.")
  result.x = value
  index += parsedX
  if index >= text.len or text[index] != ',':
    fail("Expected a center like x,y.")
  inc index
  let parsedY = parseInt(text, value, index)
  index += parsedY
  if parsedY == 0 or index != text.len:
    fail("Expected a center like x,y.")
  result.y = value

proc parsePositiveInt(text, name: string): int =
  ## Parses one positive integer option.
  if parseInt(text, result) != text.len or result <= 0:
    fail("Expected " & name & " to be a positive integer.")

proc parseNonNegativeInt(text, name: string): int =
  ## Parses one non-negative integer option.
  if parseInt(text, result) != text.len or result < 0:
    fail("Expected " & name & " to be a non-negative integer.")

proc parseConfig(): BenchConfig =
  ## Parses benchmark options.
  result.center = PositionCenter(x: DefaultCenterX, y: DefaultCenterY)
  result.runs = DefaultRuns
  result.maxErrors = 0
  result.outputDir = ""
  result.writeImages = false

  for arg in commandLineParams():
    if arg == "--":
      discard
    elif arg in ["-h", "--help", "help"]:
      echo usage()
      quit(0)
    elif arg.startsWith("--center:"):
      result.center = parsePair(arg["--center:".len .. ^1])
    elif arg.startsWith("--runs:"):
      result.runs = parsePositiveInt(arg["--runs:".len .. ^1], "runs")
    elif arg.startsWith("--max-errors:"):
      result.maxErrors = parseNonNegativeInt(
        arg["--max-errors:".len .. ^1],
        "max-errors"
      )
    elif arg.startsWith("--out:"):
      result.outputDir = arg["--out:".len .. ^1]
      result.writeImages = result.outputDir.len > 0
    else:
      fail("Unknown option: " & arg)

proc gameDir(): string =
  ## Returns the Among Them game directory.
  currentSourcePath().parentDir()

proc mapColor(mapPixels: openArray[uint8], x, y: int): uint8 =
  ## Returns a map color or black outside map bounds.
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    Black
  else:
    mapPixels[mapIndex(x, y)]

proc imageFromPixels(
  pixels: openArray[uint8],
  width,
  height: int
): Image =
  ## Builds a debug image from palette indexed pixels.
  result = newImage(width, height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result[x, y] = Palette[pixels[y * width + x] and 0x0f]

proc writeSprite(sprite: Sprite, path: string) =
  ## Writes one indexed sprite as a PNG image.
  createDir(path.splitFile.dir)
  imageFromPixels(sprite.pixels, sprite.width, sprite.height).writeFile(path)

proc writeMarkedMap(
  mapPixels: openArray[uint8],
  expectedX,
  expectedY,
  foundX,
  foundY: int,
  path: string
) =
  ## Writes the map with expected and found rectangles marked.
  let image = imageFromPixels(mapPixels, MapWidth, MapHeight)

  proc markRect(x, y: int, color: ColorRGBA) =
    ## Marks one clamped sample rectangle.
    for px in x ..< x + SampleWidth:
      if px >= 0 and px < MapWidth:
        if y >= 0 and y < MapHeight:
          image[px, y] = color
        let bottom = y + SampleHeight - 1
        if bottom >= 0 and bottom < MapHeight:
          image[px, bottom] = color
    for py in y ..< y + SampleHeight:
      if py >= 0 and py < MapHeight:
        if x >= 0 and x < MapWidth:
          image[x, py] = color
        let right = x + SampleWidth - 1
        if right >= 0 and right < MapWidth:
          image[right, py] = color

  markRect(expectedX, expectedY, rgba(255, 255, 255, 255))
  markRect(foundX, foundY, rgba(255, 64, 64, 255))
  createDir(path.splitFile.dir)
  image.writeFile(path)

proc loadMapPixels(): seq[uint8] =
  ## Loads the scaled Among Them map as palette indices.
  let oldDir = getCurrentDir()
  setCurrentDir(gameDir())
  try:
    loadPalette(clientDataDir() / "pallete.png")
    let (mapImage, _, _) = loadSkeld2Layers()
    result = newSeq[uint8](MapWidth * MapHeight)
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        result[mapIndex(x, y)] = nearestPaletteIndex(mapImage[x, y])
  finally:
    setCurrentDir(oldDir)

proc grabView(
  mapPixels: openArray[uint8],
  cameraX,
  cameraY: int
): Sprite =
  ## Grabs a 128 by 128 map view and fills outside bounds with black.
  result.width = SampleWidth
  result.height = SampleHeight
  result.pixels = newSeq[uint8](SampleWidth * SampleHeight)
  for sy in 0 ..< SampleHeight:
    for sx in 0 ..< SampleWidth:
      result.pixels[result.spriteIndex(sx, sy)] =
        mapPixels.mapColor(cameraX + sx, cameraY + sy)

proc buildScanCase(
  mapPixels: openArray[uint8],
  center: PositionCenter
): ScanCase =
  ## Builds one map scan case from a PositionCenter.
  result.center = center
  result.cameraX = center.x - SampleWidth div 2
  result.cameraY = center.y - SampleHeight div 2
  result.view = mapPixels.grabView(result.cameraX, result.cameraY)

proc scoreAt(
  mapPixels: openArray[uint8],
  view: Sprite,
  cameraX,
  cameraY,
  maxErrors: int
): tuple[errors: int, compared: int] =
  ## Counts differences between the view and one camera candidate.
  for sy in 0 ..< view.height:
    for sx in 0 ..< view.width:
      inc result.compared
      let viewColor = view.pixels[view.spriteIndex(sx, sy)]
      let expected = mapPixels.mapColor(cameraX + sx, cameraY + sy)
      if viewColor != expected:
        inc result.errors
        if result.errors > maxErrors:
          return

proc better(a, b: ScanMatch): bool =
  ## Returns true when a is a better partial scan match than b.
  if not b.found:
    return true
  if a.errors != b.errors:
    return a.errors < b.errors
  a.compared > b.compared

proc scanLeftToRight(
  mapPixels: openArray[uint8],
  view: Sprite,
  maxErrors: int
): ScanMatch =
  ## Scans every possible camera from left to right.
  let
    minX = -SampleWidth + 1
    maxX = MapWidth - 1
    minY = -SampleHeight + 1
    maxY = MapHeight - 1

  result.errors = high(int)
  for y in minY .. maxY:
    for x in minX .. maxX:
      inc result.candidates
      let score = mapPixels.scoreAt(view, x, y, maxErrors)
      let candidate = ScanMatch(
        found: true,
        exact: score.errors == 0,
        x: x,
        y: y,
        errors: score.errors,
        compared: score.compared,
        candidates: result.candidates
      )
      if candidate.better(result):
        result = candidate
      if score.errors <= maxErrors:
        result = candidate
        return

proc runBenchmark(
  mapPixels: openArray[uint8],
  scanCase: ScanCase,
  config: BenchConfig
): ScanMatch =
  ## Runs the brute force scan several times and prints timings.
  var
    totalMicros = 0'i64
    bestMicros = high(int64)
    worstMicros = 0'i64

  for i in 0 ..< config.runs:
    let start = getMonoTime()
    result = mapPixels.scanLeftToRight(scanCase.view, config.maxErrors)
    let
      finish = getMonoTime()
      elapsed = (finish - start).inMicroseconds
    totalMicros += elapsed
    bestMicros = min(bestMicros, elapsed)
    worstMicros = max(worstMicros, elapsed)
    echo "run ", i + 1, ": ", elapsed, " us, candidates=", result.candidates

  echo "avg: ", totalMicros div config.runs, " us"
  echo "best: ", bestMicros, " us"
  echo "worst: ", worstMicros, " us"

proc main() =
  ## Runs the map scan benchmark.
  let
    config = parseConfig()
    mapPixels = loadMapPixels()
    scanCase = mapPixels.buildScanCase(config.center)
    startTime = cpuTime()
    best = mapPixels.runBenchmark(scanCase, config)
    elapsed = cpuTime() - startTime

  echo "center: ", scanCase.center.x, ",", scanCase.center.y
  echo "expected camera: ", scanCase.cameraX, ",", scanCase.cameraY
  echo "found camera: ", best.x, ",", best.y
  echo "errors: ", best.errors, " compared=", best.compared
  echo "exact: ", best.exact
  echo "total cpu: ", formatFloat(elapsed, ffDecimal, 6), " s"

  if config.writeImages:
    let
      samplePath = config.outputDir / "scan_sample.png"
      mapPath = config.outputDir / "scan_map.png"
    scanCase.view.writeSprite(samplePath)
    mapPixels.writeMarkedMap(
      scanCase.cameraX,
      scanCase.cameraY,
      best.x,
      best.y,
      mapPath
    )
    echo "wrote: ", samplePath
    echo "wrote: ", mapPath

when isMainModule:
  main()
