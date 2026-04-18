import pixie
import std/os

const
  CellSize = 6
  SheetColumns = 16
  SheetRows = 4
  SheetWidth = SheetColumns * CellSize
  SheetHeight = SheetRows * CellSize

proc rootDir(): string =
  currentSourcePath().parentDir.parentDir

proc clientDataDir(): string =
  rootDir() / "client" / "data"

proc bigAdventureDataDir(): string =
  rootDir() / "big_adventure" / "data"

proc fancyCookoutDataDir(): string =
  rootDir() / "fancy_cookout" / "data"

proc sheetPath(): string =
  fancyCookoutDataDir() / "spritesheet.png"

proc loadPaletteColors(path: string): array[16, ColorRGBA] =
  let image = readImage(path)
  for x in 0 ..< result.len:
    result[x] = image[x, 0]

proc glyphColor(palette: array[16, ColorRGBA], ch: char): ColorRGBA =
  case ch
  of '.': rgbx(0, 0, 0, 0).rgba()
  of 'f': palette[3]
  of 'g': palette[2]
  of 'c': palette[1]
  of 't': palette[11]
  of 'd': palette[5]
  of 'm': palette[6]
  of 'n': palette[12]
  of 's': palette[8]
  of 'w': palette[14]
  of 'r': palette[9]
  of 'u': palette[13]
  of 'p': palette[10]
  else:
    raise newException(ValueError, "Unsupported glyph: " & $ch)

proc drawPattern(
  image: Image,
  palette: array[16, ColorRGBA],
  cellX, cellY: int,
  pattern: openArray[string]
) =
  let
    originX = cellX * CellSize
    originY = cellY * CellSize
  for y, row in pattern:
    for x, ch in row:
      image[originX + x, originY + y] = glyphColor(palette, ch)

proc blitImageCell(sheet, source: Image, cellX, cellY: int) =
  let
    originX = cellX * CellSize
    originY = cellY * CellSize
  for y in 0 ..< min(CellSize, source.height):
    for x in 0 ..< min(CellSize, source.width):
      let pixel = source[x, y]
      if pixel.a > 0:
        sheet[originX + x, originY + y] = pixel

proc cellFromStrip(path: string, index: int): Image =
  let strip = readImage(path)
  strip.subImage(index * CellSize, 0, CellSize, CellSize)

proc createFancyCookoutSheet() =
  createDir(fancyCookoutDataDir())

  let
    palette = loadPaletteColors(clientDataDir() / "pallete.png")
    sheet = newImage(SheetWidth, SheetHeight)
  sheet.fill(rgbx(0, 0, 0, 0))

  sheet.drawPattern(palette, 0, 0, [
    "ffffff",
    "fgffff",
    "ffffff",
    "ffffgf",
    "ffffff",
    "ffffff"
  ])

  sheet.drawPattern(palette, 1, 0, [
    "ffgfff",
    "gffffg",
    "ffffff",
    "ffggff",
    "ffffff",
    "gfffff"
  ])

  sheet.drawPattern(palette, 2, 0, [
    "tttttt",
    "tcccct",
    "tcccct",
    "tcccct",
    "tcccct",
    "cccccc"
  ])

  sheet.drawPattern(palette, 3, 0, [
    "tttttt",
    "tuuuct",
    "tcddct",
    "tcdmct",
    "tcccct",
    "cccccc"
  ])

  sheet.drawPattern(palette, 4, 0, [
    "tttttt",
    "trccrt",
    "trnnrt",
    "trccrt",
    "trccrt",
    "cccccc"
  ])

  sheet.drawPattern(palette, 5, 0, [
    "tttttt",
    "tsssst",
    "tswwst",
    "tswwst",
    "tsssst",
    "cccccc"
  ])

  sheet.drawPattern(palette, 6, 0, [
    "......",
    ".dddd.",
    ".d..d.",
    ".dm.d.",
    ".dddd.",
    "......"
  ])

  sheet.drawPattern(palette, 7, 0, [
    "......",
    ".nnnn.",
    ".n..n.",
    ".n..n.",
    ".nnnn.",
    "......"
  ])

  sheet.drawPattern(palette, 8, 0, [
    "......",
    "......",
    "......",
    "......",
    ".p....",
    "......"
  ])

  sheet.drawPattern(palette, 9, 0, [
    "......",
    "......",
    "......",
    "......",
    ".pp...",
    "......"
  ])

  sheet.drawPattern(palette, 10, 0, [
    "......",
    "......",
    "......",
    "......",
    ".ppp..",
    "......"
  ])

  sheet.drawPattern(palette, 11, 0, [
    "......",
    "......",
    "......",
    "......",
    ".pppp.",
    "......"
  ])

  sheet.blitImageCell(readImage(bigAdventureDataDir() / "player.png"), 12, 0)

  for digit in 0 ..< 10:
    sheet.blitImageCell(cellFromStrip(bigAdventureDataDir() / "numbers.png", digit), digit, 1)

  for letter in 0 ..< 31:
    let
      cellX = letter mod SheetColumns
      cellY = 2 + letter div SheetColumns
    sheet.blitImageCell(cellFromStrip(bigAdventureDataDir() / "letters.png", letter), cellX, cellY)

  sheet.writeFile(sheetPath())
  echo "Wrote ", sheetPath()

when isMainModule:
  createFancyCookoutSheet()
