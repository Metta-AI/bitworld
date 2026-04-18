import pixie
import std/os

const
  CellSize = 12
  SheetColumns = 12
  SheetRows = 3
  SheetWidth = SheetColumns * CellSize
  SheetHeight = SheetRows * CellSize

type
  PaletteColors = array[16, ColorRGBA]

proc rootDir(): string =
  currentSourcePath().parentDir.parentDir

proc clientDataDir(): string =
  rootDir() / "client" / "data"

proc fancyCookoutDataDir(): string =
  rootDir() / "fancy_cookout" / "data"

proc sheetPath(): string =
  fancyCookoutDataDir() / "spritesheet.png"

proc loadPaletteColors(path: string): PaletteColors =
  let image = readImage(path)
  for x in 0 ..< result.len:
    result[x] = image[x, 0]

proc transparentColor(): ColorRGBA =
  rgbx(0, 0, 0, 0).rgba()

proc setCellPixel(sheet: Image, cellX, cellY, px, py: int, color: ColorRGBA) =
  if px < 0 or py < 0 or px >= CellSize or py >= CellSize:
    return
  sheet[cellX * CellSize + px, cellY * CellSize + py] = color

proc fillCell(sheet: Image, cellX, cellY: int, color: ColorRGBA) =
  for py in 0 ..< CellSize:
    for px in 0 ..< CellSize:
      sheet.setCellPixel(cellX, cellY, px, py, color)

proc fillRect(
  sheet: Image,
  cellX, cellY, px, py, width, height: int,
  color: ColorRGBA
) =
  for drawY in py ..< py + height:
    for drawX in px ..< px + width:
      sheet.setCellPixel(cellX, cellY, drawX, drawY, color)

proc outlineRect(
  sheet: Image,
  cellX, cellY, px, py, width, height: int,
  color: ColorRGBA
) =
  for drawX in px ..< px + width:
    sheet.setCellPixel(cellX, cellY, drawX, py, color)
    sheet.setCellPixel(cellX, cellY, drawX, py + height - 1, color)
  for drawY in py ..< py + height:
    sheet.setCellPixel(cellX, cellY, px, drawY, color)
    sheet.setCellPixel(cellX, cellY, px + width - 1, drawY, color)

proc drawFloor(sheet: Image, palette: PaletteColors, cellX, cellY, variant: int) =
  let
    grout = palette[1]
    warmLight = palette[11]
    warmBase = palette[3]
    herbTint = palette[2]

  sheet.fillCell(cellX, cellY, warmBase)
  sheet.fillRect(cellX, cellY, 0, 0, 6, 6, if variant == 0: warmLight else: warmBase)
  sheet.fillRect(cellX, cellY, 6, 0, 6, 6, if variant == 0: warmBase else: warmLight)
  sheet.fillRect(cellX, cellY, 0, 6, 6, 6, if variant == 0: warmBase else: warmLight)
  sheet.fillRect(cellX, cellY, 6, 6, 6, 6, if variant == 0: warmLight else: warmBase)

  for px in 0 ..< CellSize:
    sheet.setCellPixel(cellX, cellY, px, 5, grout)
    sheet.setCellPixel(cellX, cellY, px, 6, grout)
  for py in 0 ..< CellSize:
    sheet.setCellPixel(cellX, cellY, 5, py, grout)
    sheet.setCellPixel(cellX, cellY, 6, py, grout)

  let specks =
    if variant == 0:
      @[(1, 2), (3, 4), (8, 1), (10, 3), (2, 8), (9, 10)]
    else:
      @[(2, 1), (4, 3), (7, 2), (10, 5), (1, 9), (8, 8), (10, 10)]
  for (px, py) in specks:
    sheet.setCellPixel(cellX, cellY, px, py, herbTint)

proc drawCounterBody(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  let
    darkWood = palette[5]
    topWood = palette[11]
    face = palette[3]
    handle = palette[1]
  sheet.fillCell(cellX, cellY, darkWood)
  sheet.fillRect(cellX, cellY, 0, 0, CellSize, 3, topWood)
  sheet.fillRect(cellX, cellY, 1, 3, CellSize - 2, 8, face)
  sheet.fillRect(cellX, cellY, 2, 4, 3, 6, darkWood)
  sheet.fillRect(cellX, cellY, 7, 4, 3, 6, darkWood)
  sheet.fillRect(cellX, cellY, 3, 5, 1, 4, handle)
  sheet.fillRect(cellX, cellY, 8, 5, 1, 4, handle)
  sheet.fillRect(cellX, cellY, 0, 11, CellSize, 1, handle)
  sheet.outlineRect(cellX, cellY, 0, 0, CellSize, CellSize, handle)

proc drawDirtyReturn(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.drawCounterBody(palette, cellX, cellY)
  let
    tray = palette[1]
    dish = palette[5]
    splash = palette[9]
  sheet.fillRect(cellX, cellY, 2, 4, 8, 5, tray)
  sheet.outlineRect(cellX, cellY, 1, 3, 10, 7, palette[11])
  sheet.fillRect(cellX, cellY, 3, 5, 6, 3, dish)
  sheet.fillRect(cellX, cellY, 5, 4, 2, 1, splash)
  sheet.fillRect(cellX, cellY, 4, 9, 4, 1, splash)

proc drawCleanRack(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.drawCounterBody(palette, cellX, cellY)
  let
    rack = palette[1]
    plate = palette[14]
    shine = palette[12]
  sheet.fillRect(cellX, cellY, 2, 3, 8, 1, rack)
  sheet.fillRect(cellX, cellY, 2, 6, 8, 1, rack)
  sheet.fillRect(cellX, cellY, 2, 9, 8, 1, rack)
  sheet.fillRect(cellX, cellY, 3, 4, 6, 4, plate)
  sheet.outlineRect(cellX, cellY, 3, 4, 6, 4, shine)
  sheet.fillRect(cellX, cellY, 5, 5, 2, 1, shine)

proc drawWashStation(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  let
    steel = palette[14]
    steelDark = palette[1]
    water = palette[12]
    foam = palette[0]
  sheet.fillCell(cellX, cellY, steelDark)
  sheet.fillRect(cellX, cellY, 1, 1, 10, 10, steel)
  sheet.fillRect(cellX, cellY, 2, 3, 8, 6, water)
  sheet.fillRect(cellX, cellY, 3, 4, 6, 4, palette[13])
  sheet.fillRect(cellX, cellY, 4, 1, 1, 3, steelDark)
  sheet.fillRect(cellX, cellY, 7, 1, 1, 3, steelDark)
  sheet.fillRect(cellX, cellY, 4, 1, 4, 1, steelDark)
  sheet.fillRect(cellX, cellY, 3, 5, 1, 1, foam)
  sheet.fillRect(cellX, cellY, 8, 6, 1, 1, foam)
  sheet.outlineRect(cellX, cellY, 1, 1, 10, 10, steelDark)

proc drawCuttingBoard(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, palette[5])
  sheet.fillRect(cellX, cellY, 1, 1, 10, 10, palette[11])
  sheet.fillRect(cellX, cellY, 3, 3, 6, 6, palette[3])
  sheet.fillRect(cellX, cellY, 8, 2, 2, 2, palette[1])
  sheet.outlineRect(cellX, cellY, 1, 1, 10, 10, palette[1])

proc drawHotStation(
  sheet: Image,
  palette: PaletteColors,
  cellX, cellY: int,
  flameColor, accentColor: ColorRGBA
) =
  sheet.fillCell(cellX, cellY, palette[1])
  sheet.fillRect(cellX, cellY, 1, 1, 10, 10, palette[5])
  sheet.fillRect(cellX, cellY, 2, 2, 8, 4, palette[3])
  sheet.fillRect(cellX, cellY, 2, 7, 8, 3, palette[11])
  sheet.fillRect(cellX, cellY, 3, 3, 2, 2, flameColor)
  sheet.fillRect(cellX, cellY, 7, 3, 2, 2, flameColor)
  sheet.fillRect(cellX, cellY, 5, 6, 2, 1, accentColor)
  sheet.outlineRect(cellX, cellY, 1, 1, 10, 10, palette[0])

proc drawChef(
  sheet: Image,
  palette: PaletteColors,
  cellX, cellY: int,
  coatColor, trimColor, hairColor: ColorRGBA
) =
  sheet.fillCell(cellX, cellY, transparentColor())
  sheet.fillRect(cellX, cellY, 2, 0, 8, 2, palette[14])
  sheet.fillRect(cellX, cellY, 3, 2, 6, 1, palette[14])
  sheet.fillRect(cellX, cellY, 3, 2, 6, 1, hairColor)
  sheet.fillRect(cellX, cellY, 3, 3, 6, 4, palette[13])
  sheet.fillRect(cellX, cellY, 2, 5, 1, 3, palette[13])
  sheet.fillRect(cellX, cellY, 9, 5, 1, 3, palette[13])
  sheet.fillRect(cellX, cellY, 3, 6, 6, 4, coatColor)
  sheet.fillRect(cellX, cellY, 4, 6, 4, 4, palette[14])
  sheet.fillRect(cellX, cellY, 5, 6, 2, 4, trimColor)
  sheet.fillRect(cellX, cellY, 3, 10, 2, 2, palette[1])
  sheet.fillRect(cellX, cellY, 7, 10, 2, 2, palette[1])
  sheet.fillRect(cellX, cellY, 4, 4, 1, 1, palette[0])
  sheet.fillRect(cellX, cellY, 7, 4, 1, 1, palette[0])
  sheet.fillRect(cellX, cellY, 5, 5, 2, 1, palette[9])

proc drawPlate(
  sheet: Image,
  palette: PaletteColors,
  cellX, cellY: int,
  centerColor, garnishColor: ColorRGBA
) =
  sheet.fillCell(cellX, cellY, transparentColor())
  sheet.fillRect(cellX, cellY, 2, 2, 8, 8, palette[14])
  sheet.outlineRect(cellX, cellY, 2, 2, 8, 8, palette[12])
  sheet.fillRect(cellX, cellY, 4, 4, 4, 4, centerColor)
  sheet.fillRect(cellX, cellY, 5, 3, 2, 1, garnishColor)
  sheet.fillRect(cellX, cellY, 4, 8, 4, 1, garnishColor)

proc drawLeaf(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, transparentColor())
  sheet.fillRect(cellX, cellY, 3, 4, 6, 4, palette[2])
  sheet.fillRect(cellX, cellY, 2, 5, 8, 2, palette[3])
  sheet.fillRect(cellX, cellY, 6, 2, 1, 2, palette[11])
  sheet.fillRect(cellX, cellY, 4, 8, 4, 1, palette[1])

proc drawTomato(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, transparentColor())
  sheet.fillRect(cellX, cellY, 3, 3, 6, 6, palette[9])
  sheet.outlineRect(cellX, cellY, 3, 3, 6, 6, palette[5])
  sheet.fillRect(cellX, cellY, 5, 2, 2, 2, palette[2])
  sheet.fillRect(cellX, cellY, 4, 4, 1, 1, palette[14])

proc drawChoppedGreens(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, transparentColor())
  for (px, py) in @[(2, 7), (4, 5), (5, 8), (7, 6), (8, 8), (6, 4), (3, 9), (9, 5)]:
    sheet.fillRect(cellX, cellY, px, py, 2, 2, palette[2])
    sheet.setCellPixel(cellX, cellY, px + 1, py, palette[3])

proc drawChoppedTomato(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, transparentColor())
  for (px, py) in @[(2, 7), (4, 5), (7, 6), (8, 8), (5, 9), (6, 4)]:
    sheet.fillRect(cellX, cellY, px, py, 2, 2, palette[9])
    sheet.setCellPixel(cellX, cellY, px + 1, py, palette[14])

proc drawSalad(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, transparentColor())
  sheet.fillRect(cellX, cellY, 2, 7, 8, 3, palette[14])
  sheet.outlineRect(cellX, cellY, 2, 7, 8, 3, palette[12])
  sheet.fillRect(cellX, cellY, 3, 5, 6, 3, palette[2])
  sheet.fillRect(cellX, cellY, 4, 4, 4, 2, palette[3])
  sheet.fillRect(cellX, cellY, 4, 6, 2, 1, palette[9])
  sheet.fillRect(cellX, cellY, 7, 5, 1, 1, palette[9])

proc drawSteak(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, transparentColor())
  sheet.fillRect(cellX, cellY, 3, 4, 6, 5, palette[9])
  sheet.outlineRect(cellX, cellY, 3, 4, 6, 5, palette[5])
  sheet.fillRect(cellX, cellY, 5, 5, 2, 2, palette[14])
  sheet.fillRect(cellX, cellY, 8, 6, 1, 1, palette[11])

proc drawSkewer(sheet: Image, palette: PaletteColors, cellX, cellY: int) =
  sheet.fillCell(cellX, cellY, transparentColor())
  sheet.fillRect(cellX, cellY, 2, 6, 8, 1, palette[11])
  sheet.fillRect(cellX, cellY, 3, 5, 2, 3, palette[9])
  sheet.fillRect(cellX, cellY, 6, 5, 2, 3, palette[2])
  sheet.fillRect(cellX, cellY, 8, 5, 1, 3, palette[12])

proc createFancyCookoutSheet() =
  createDir(fancyCookoutDataDir())

  let
    palette = loadPaletteColors(clientDataDir() / "pallete.png")
    sheet = newImage(SheetWidth, SheetHeight)
  sheet.fill(transparentColor())

  sheet.drawFloor(palette, 0, 0, 0)
  sheet.drawFloor(palette, 1, 0, 1)
  sheet.drawCounterBody(palette, 2, 0)
  sheet.drawDirtyReturn(palette, 3, 0)
  sheet.drawCleanRack(palette, 4, 0)
  sheet.drawWashStation(palette, 5, 0)
  sheet.drawCuttingBoard(palette, 6, 0)
  sheet.drawHotStation(palette, 7, 0, palette[10], palette[14])
  sheet.drawHotStation(palette, 8, 0, palette[9], palette[10])
  sheet.drawHotStation(palette, 9, 0, palette[2], palette[11])
  sheet.drawCounterBody(palette, 10, 0)
  sheet.drawCounterBody(palette, 11, 0)

  sheet.drawChef(palette, 0, 1, palette[12], palette[9], palette[5])
  sheet.drawChef(palette, 1, 1, palette[9], palette[10], palette[1])
  sheet.drawChef(palette, 2, 1, palette[2], palette[11], palette[5])
  sheet.drawChef(palette, 3, 1, palette[10], palette[12], palette[1])

  sheet.drawPlate(palette, 0, 2, palette[5], palette[9])
  sheet.drawPlate(palette, 1, 2, palette[14], palette[12])
  sheet.drawLeaf(palette, 2, 2)
  sheet.drawTomato(palette, 3, 2)
  sheet.drawChoppedGreens(palette, 4, 2)
  sheet.drawChoppedTomato(palette, 5, 2)
  sheet.drawSalad(palette, 6, 2)
  sheet.drawSteak(palette, 7, 2)
  sheet.drawSkewer(palette, 8, 2)
  sheet.drawPlate(palette, 9, 2, palette[2], palette[9])
  sheet.drawPlate(palette, 10, 2, palette[10], palette[11])
  sheet.drawPlate(palette, 11, 2, palette[12], palette[14])

  sheet.writeFile(sheetPath())
  echo "Wrote ", sheetPath()

when isMainModule:
  createFancyCookoutSheet()
