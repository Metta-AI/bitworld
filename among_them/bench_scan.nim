import
  std/[algorithm, monotimes, os, parseutils, strutils, times],
  pixie,
  sim, ../common/protocol, ../common/server

const
  SampleWidth = ScreenWidth
  SampleHeight = ScreenHeight
  SampleOffX = SampleWidth div 2
  SampleOffY = SampleHeight div 2
  VirtualHeight = MapHeight + SampleHeight - 1
  HashBase = 16777619'u64
  HashBaseY = 1099511628211'u64
  HashSalt = 0x9e3779b97f4a7c15'u64
  Black = SpaceColor
  PatchSize = 8
  PatchGridW = SampleWidth div PatchSize
  PatchGridH = SampleHeight div PatchSize
  PatchSlots = PatchGridW * PatchGridH
  PatchMapWidth = MapWidth + SampleWidth - PatchSize
  PatchMapHeight = MapHeight + SampleHeight - PatchSize
  DefaultPatchStep = 1
  DefaultMaxPatchMatches = 4096
  DefaultDetails = 16
  DefaultOutput = "scan_unknown.png"
  DefaultPatchOutput = "scan_patch_unknown.png"

type
  BenchConfig = object
    details: int
    outputPath: string
    patchOutputPath: string
    patchStep: int
    maxPatchMatches: int

  HashEntry = object
    hash: uint64
    index: int
    patchId: int

  ScanStats = object
    centers: int
    wrong: int
    ambiguous: int
    missing: int
    hashMicros: int64
    checkMicros: int64

  ScanReport = object
    stats: ScanStats
    ambiguous: seq[bool]

  PatchStats = object
    centers: int
    wrong: int
    tied: int
    minTrueVotes: int
    minWinningVotes: int
    maxWrongVotes: int
    buildMicros: int64
    sweepMicros: int64

  PatchReport = object
    stats: PatchStats
    wrong: seq[bool]

proc `<`(a, b: HashEntry): bool =
  ## Orders hash entries by hash and scan order.
  if a.hash == b.hash:
    if a.patchId == b.patchId:
      a.index < b.index
    else:
      a.patchId < b.patchId
  else:
    a.hash < b.hash

proc usage(): string =
  ## Returns command line help for the map-wide scan benchmark.
  "Usage:\n" &
    "  nim r among_them/bench_scan.nim -- [options]\n\n" &
    "Options:\n" &
    "  --details:n    Print up to n wrong or ambiguous centers.\n" &
    "  --out:path     Write red ambiguous pixels to this PNG.\n" &
    "  --patch-out:path  Write red patch-vote failures to this PNG.\n" &
    "  --patch-step:n    Use every nth 8x8 patch slot.\n" &
    "  --max-patch-matches:n  Skip patch groups larger than n.\n" &
    "  --help         Show this help.\n"

proc fail(message: string) =
  ## Prints one error with usage and exits.
  stderr.writeLine("bench_scan: " & message)
  stderr.writeLine("")
  stderr.writeLine(usage())
  quit(1)

proc gameDir(): string =
  ## Returns the Among Them game directory.
  currentSourcePath().parentDir()

proc parseConfig(): BenchConfig =
  ## Parses command line options.
  result.details = DefaultDetails
  result.outputPath = gameDir() / DefaultOutput
  result.patchOutputPath = gameDir() / DefaultPatchOutput
  result.patchStep = DefaultPatchStep
  result.maxPatchMatches = DefaultMaxPatchMatches
  for arg in commandLineParams():
    if arg == "--":
      discard
    elif arg in ["-h", "--help", "help"]:
      echo usage()
      quit(0)
    elif arg.startsWith("--details:"):
      let text = arg["--details:".len .. ^1]
      if parseInt(text, result.details) != text.len or
          result.details < 0:
        fail("Expected details to be a non-negative integer.")
    elif arg.startsWith("--out:"):
      result.outputPath = arg["--out:".len .. ^1]
    elif arg.startsWith("--patch-out:"):
      result.patchOutputPath = arg["--patch-out:".len .. ^1]
    elif arg.startsWith("--patch-step:"):
      let text = arg["--patch-step:".len .. ^1]
      if parseInt(text, result.patchStep) != text.len or
          result.patchStep <= 0:
        fail("Expected patch-step to be a positive integer.")
    elif arg.startsWith("--max-patch-matches:"):
      let text = arg["--max-patch-matches:".len .. ^1]
      if parseInt(text, result.maxPatchMatches) != text.len or
          result.maxPatchMatches <= 0:
        fail("Expected max-patch-matches to be a positive integer.")
    else:
      fail("Unknown option: " & arg)

proc mapColor(mapPixels: openArray[uint8], x, y: int): uint8 =
  ## Returns a map color or black outside map bounds.
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    Black
  else:
    mapPixels[mapIndex(x, y)]

proc virtualColor(mapPixels: openArray[uint8], vx, vy: int): uint8 =
  ## Returns one pixel from the padded virtual scan image.
  mapPixels.mapColor(vx - SampleOffX, vy - SampleOffY)

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

proc hashToken(color: uint8): uint64 =
  ## Converts one palette index into a hash token.
  uint64(color) + 1'u64

proc rowToken(rowHash: uint64): uint64 =
  ## Converts one row hash into a vertical hash token.
  rowHash + HashSalt

proc powWrap(base: uint64, exponent: int): uint64 =
  ## Returns base to exponent using wrapping arithmetic.
  result = 1'u64
  for i in 0 ..< exponent:
    result = result * base

proc buildRowHashes(mapPixels: openArray[uint8]): seq[uint64] =
  ## Builds rolling hashes for every 128-pixel scan row.
  result = newSeq[uint64](VirtualHeight * MapWidth)
  let removePow = powWrap(HashBase, SampleWidth - 1)
  for vy in 0 ..< VirtualHeight:
    var hash = 0'u64
    for sx in 0 ..< SampleWidth:
      hash = hash * HashBase +
        hashToken(mapPixels.virtualColor(sx, vy))
    result[vy * MapWidth] = hash
    for cx in 1 ..< MapWidth:
      let
        oldToken = hashToken(mapPixels.virtualColor(cx - 1, vy))
        newToken = hashToken(
          mapPixels.virtualColor(cx + SampleWidth - 1, vy)
        )
      hash = (hash - oldToken * removePow) * HashBase + newToken
      result[vy * MapWidth + cx] = hash

proc buildViewHashes(mapPixels: openArray[uint8]): seq[HashEntry] =
  ## Builds one hash entry for every possible map center.
  let
    rowHashes = mapPixels.buildRowHashes()
    removePow = powWrap(HashBaseY, SampleHeight - 1)
  result = newSeq[HashEntry](MapWidth * MapHeight)
  for cx in 0 ..< MapWidth:
    var hash = 0'u64
    for sy in 0 ..< SampleHeight:
      hash = hash * HashBaseY +
        rowToken(rowHashes[sy * MapWidth + cx])
    result[cx] = HashEntry(hash: hash, index: cx, patchId: 0)
    for cy in 1 ..< MapHeight:
      let
        oldToken = rowToken(rowHashes[(cy - 1) * MapWidth + cx])
        newToken = rowToken(
          rowHashes[(cy + SampleHeight - 1) * MapWidth + cx]
        )
      hash = (hash - oldToken * removePow) * HashBaseY + newToken
      result[cy * MapWidth + cx] = HashEntry(
        hash: hash,
        index: cy * MapWidth + cx,
        patchId: 0
      )
  result.sort()

proc centerX(index: int): int =
  ## Returns the center X coordinate for one scan index.
  index mod MapWidth

proc centerY(index: int): int =
  ## Returns the center Y coordinate for one scan index.
  index div MapWidth

proc printCenter(prefix: string, source, guess, matches: int) =
  ## Prints one wrong or ambiguous scan result.
  echo prefix,
    " center=", source.centerX(), ",", source.centerY(),
    " guess=", guess.centerX(), ",", guess.centerY(),
    " matches=", matches

proc imageFromMap(mapPixels: openArray[uint8]): Image =
  ## Builds a debug image from the current map pixels.
  result = newImage(MapWidth, MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      result[x, y] = Palette[mapPixels[mapIndex(x, y)] and 0x0f]

proc writeUnknownMap(
  mapPixels: openArray[uint8],
  ambiguous: openArray[bool],
  path: string
) =
  ## Writes a map-sized PNG with ambiguous centers marked red.
  let image = imageFromMap(mapPixels)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      if ambiguous[mapIndex(x, y)]:
        image[x, y] = rgba(255, 0, 0, 255)
  createDir(path.splitFile.dir)
  image.writeFile(path)

proc patchSquareHashAt(
  mapPixels: openArray[uint8],
  vx,
  vy: int
): uint64 =
  ## Builds one exact 8 by 8 patch hash in virtual coordinates.
  result = 14695981039346656037'u64
  for y in 0 ..< PatchSize:
    for x in 0 ..< PatchSize:
      result = result * HashBase +
        hashToken(mapPixels.virtualColor(vx + x, vy + y))

proc selectedPatchIds(patchStep: int): seq[int] =
  ## Returns the 8 by 8 patch slots used by the vote benchmark.
  for py in countup(0, PatchGridH - 1, patchStep):
    for px in countup(0, PatchGridW - 1, patchStep):
      result.add(py * PatchGridW + px)

proc buildPatchHashes(
  mapPixels: openArray[uint8]
): seq[HashEntry] =
  ## Builds one hash for every 8 by 8 square in the padded map.
  result = newSeq[HashEntry](PatchMapWidth * PatchMapHeight)
  var i = 0
  for vy in 0 ..< PatchMapHeight:
    for vx in 0 ..< PatchMapWidth:
      result[i] = HashEntry(
        hash: mapPixels.patchSquareHashAt(vx, vy),
        index: vy * PatchMapWidth + vx,
        patchId: 0
      )
      inc i
  result.sort()

proc findHashRange(
  entries: openArray[HashEntry],
  hash: uint64
): tuple[first, last: int] =
  ## Returns the sorted range with a matching hash.
  var
    lo = 0
    hi = entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if entries[mid].hash < hash:
      lo = mid + 1
    else:
      hi = mid
  result.first = lo
  hi = entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if entries[mid].hash > hash:
      hi = mid
    else:
      lo = mid + 1
  result.last = lo

proc testPatchVotes(
  mapPixels: openArray[uint8],
  entries: openArray[HashEntry],
  patchIds: openArray[int],
  maxPatchMatches: int,
  detailLimit: int
): PatchReport =
  ## Tests whether 8 by 8 patch votes identify every map center.
  result.stats.centers = MapWidth * MapHeight
  result.stats.minTrueVotes = high(int)
  result.stats.minWinningVotes = high(int)
  result.wrong = newSeq[bool](MapWidth * MapHeight)
  var
    votes = newSeq[uint16](MapWidth * MapHeight)
    touched = newSeq[int]()
    detailCount = 0

  template addVote(index: int) =
    ## Adds one vote and remembers touched centers.
    if votes[index] == 0:
      touched.add(index)
    votes[index] = votes[index] + 1

  for cy in 0 ..< MapHeight:
    for cx in 0 ..< MapWidth:
      let source = cy * MapWidth + cx
      touched.setLen(0)
      for patchId in patchIds:
        let
          localX = patchId mod PatchGridW * PatchSize
          localY = patchId div PatchGridW * PatchSize
          hash = mapPixels.patchSquareHashAt(cx + localX, cy + localY)
          range = findHashRange(entries, hash)
        if range.last - range.first > maxPatchMatches:
          continue
        for i in range.first ..< range.last:
          let
            vx = entries[i].index mod PatchMapWidth
            vy = entries[i].index div PatchMapWidth
            voteX = vx - localX
            voteY = vy - localY
          if voteX >= 0 and voteY >= 0 and
              voteX < MapWidth and voteY < MapHeight:
            addVote(voteY * MapWidth + voteX)

      var
        best = -1
        bestVotes = -1
        tieCount = 0
      for index in touched:
        let count = votes[index].int
        if count > bestVotes or
            (count == bestVotes and index < best):
          best = index
          bestVotes = count
          tieCount = 1
        elif count == bestVotes:
          inc tieCount
        if index != source:
          result.stats.maxWrongVotes = max(
            result.stats.maxWrongVotes,
            count
          )
      let trueVotes = votes[source].int
      result.stats.minTrueVotes = min(result.stats.minTrueVotes, trueVotes)
      result.stats.minWinningVotes = min(
        result.stats.minWinningVotes,
        bestVotes
      )
      if best != source:
        inc result.stats.wrong
        result.wrong[source] = true
        if detailCount < detailLimit:
          printCenter("patch wrong", source, best, bestVotes)
          inc detailCount
      elif tieCount > 1:
        inc result.stats.tied
        result.wrong[source] = true
        if detailCount < detailLimit:
          printCenter("patch tied", source, best, bestVotes)
          inc detailCount
      for index in touched:
        votes[index] = 0

proc writePatchUnknownMap(
  mapPixels: openArray[uint8],
  report: PatchReport,
  path: string
) =
  ## Writes a map-sized PNG with patch-vote failures marked red.
  mapPixels.writeUnknownMap(report.wrong, path)

proc checkHashes(
  entries: openArray[HashEntry],
  detailLimit: int
): ScanReport =
  ## Checks every center and counts wrong first guesses by hash group.
  result.stats.centers = MapWidth * MapHeight
  result.ambiguous = newSeq[bool](MapWidth * MapHeight)
  var detailCount = 0
  var start = 0
  while start < entries.len:
    var stop = start + 1
    while stop < entries.len and entries[stop].hash == entries[start].hash:
      inc stop
    if stop - start > 1:
      let
        first = entries[start].index
        matches = stop - start
      result.stats.ambiguous += matches
      result.stats.wrong += matches - 1
      for i in start ..< stop:
        let source = entries[i].index
        result.ambiguous[source] = true
        if source != first and detailCount < detailLimit:
          printCenter("wrong", source, first, matches)
          inc detailCount
        if detailCount < detailLimit:
          printCenter("ambiguous", source, first, matches)
          inc detailCount
    start = stop

proc main() =
  ## Runs the whole-map scan benchmark.
  let
    config = parseConfig()
    mapPixels = loadMapPixels()

  let hashStart = getMonoTime()
  let entries = mapPixels.buildViewHashes()
  let hashFinish = getMonoTime()

  let checkStart = getMonoTime()
  var report = checkHashes(entries, config.details)
  let checkFinish = getMonoTime()
  var stats = report.stats
  stats.hashMicros = (hashFinish - hashStart).inMicroseconds
  stats.checkMicros = (checkFinish - checkStart).inMicroseconds
  mapPixels.writeUnknownMap(report.ambiguous, config.outputPath)

  let patchIds = selectedPatchIds(config.patchStep)
  let patchBuildStart = getMonoTime()
  let patchEntries = mapPixels.buildPatchHashes()
  let patchBuildFinish = getMonoTime()

  let patchSweepStart = getMonoTime()
  var patchReport = mapPixels.testPatchVotes(
    patchEntries,
    patchIds,
    config.maxPatchMatches,
    config.details
  )
  let patchSweepFinish = getMonoTime()
  patchReport.stats.buildMicros =
    (patchBuildFinish - patchBuildStart).inMicroseconds
  patchReport.stats.sweepMicros =
    (patchSweepFinish - patchSweepStart).inMicroseconds
  mapPixels.writePatchUnknownMap(patchReport, config.patchOutputPath)

  echo "full view scan"
  echo "centers scanned: ", stats.centers
  echo "wrong guesses: ", stats.wrong
  echo "ambiguous centers: ", stats.ambiguous
  echo "missing centers: ", stats.missing
  echo "hash time: ", stats.hashMicros, " us"
  echo "check time: ", stats.checkMicros, " us"
  echo "total scan time: ", stats.hashMicros + stats.checkMicros, " us"
  echo "center range x: 0 .. ", MapWidth - 1
  echo "center range y: 0 .. ", MapHeight - 1
  echo "camera range x: ", -SampleOffX, " .. ", MapWidth - 1 - SampleOffX
  echo "camera range y: ", -SampleOffY, " .. ", MapHeight - 1 - SampleOffY
  echo "wrote unknown map: ", config.outputPath
  echo ""
  echo "8x8 patch vote scan"
  echo "patch slots available: ", PatchSlots
  echo "patch slots used: ", patchIds.len
  echo "patch step: ", config.patchStep
  echo "max patch matches: ", config.maxPatchMatches
  echo "centers scanned: ", patchReport.stats.centers
  echo "wrong guesses: ", patchReport.stats.wrong
  echo "tied guesses: ", patchReport.stats.tied
  echo "min true votes: ", patchReport.stats.minTrueVotes
  echo "min winning votes: ", patchReport.stats.minWinningVotes
  echo "max wrong votes: ", patchReport.stats.maxWrongVotes
  echo "patch hash time: ", patchReport.stats.buildMicros, " us"
  echo "patch sweep time: ", patchReport.stats.sweepMicros, " us"
  echo "patch total time: ",
    patchReport.stats.buildMicros + patchReport.stats.sweepMicros,
    " us"
  echo "wrote patch unknown map: ", config.patchOutputPath

when isMainModule:
  main()
