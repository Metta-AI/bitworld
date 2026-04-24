import pixie
import std/[os, tables]

const
  DefaultPaletteFile = "Arne16toPico8.png"

proc usage(): string =
  "Usage:\n" &
    "  ptswap <input_image> <output_image>\n" &
    "  ptswap <palette_swap_image> <input_image> <output_image>\n\n" &
    "The palette swap image uses the top row as source colors and the bottom row as target colors.\n" &
    "With two arguments, ptswap uses " & DefaultPaletteFile & " beside the tool."

proc die(message: string) =
  stderr.writeLine("ptswap: " & message)
  stderr.writeLine("")
  stderr.writeLine(usage())
  quit(1)

proc colorKey(color: ColorRGBX): uint32 =
  (uint32(color.r) shl 24) or
    (uint32(color.g) shl 16) or
    (uint32(color.b) shl 8) or
    uint32(color.a)

proc sameColor(a, b: ColorRGBX): bool =
  a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a

proc defaultPalettePath(): string =
  let candidates = [
    getAppDir() / DefaultPaletteFile,
    getCurrentDir() / "tools" / DefaultPaletteFile,
    getCurrentDir() / DefaultPaletteFile
  ]

  for candidate in candidates:
    if fileExists(candidate):
      return candidate

  candidates[0]

proc loadPaletteSwaps(path: string): Table[uint32, ColorRGBX] =
  if not fileExists(path):
    raise newException(IOError, "Missing palette swap image: " & path)

  let image = readImage(path)
  if image.width < 1 or image.height < 2:
    raise newException(
      IOError,
      "Palette swap image must be at least 1x2 pixels: " & path
    )

  let targetY = image.height - 1
  for x in 0 ..< image.width:
    let
      source = image[x, 0]
      target = image[x, targetY]
      key = colorKey(source)

    if result.hasKey(key) and not result[key].sameColor(target):
      raise newException(
        ValueError,
        "Palette swap image maps source color at column " & $x &
          " to more than one target color."
      )

    result[key] = target

proc swapImage(
  palettePath: string,
  inputPath: string,
  outputPath: string
): tuple[pixelsChanged, colorsMapped: int] =
  let swaps = loadPaletteSwaps(palettePath)
  if swaps.len == 0:
    raise newException(ValueError, "Palette swap image did not contain any colors.")

  if not fileExists(inputPath):
    raise newException(IOError, "Missing input image: " & inputPath)

  let image = readImage(inputPath)
  for pixel in image.data.mitems:
    let key = colorKey(pixel)
    if swaps.hasKey(key):
      pixel = swaps[key]
      inc result.pixelsChanged

  let outputDir = outputPath.splitFile.dir
  if outputDir.len > 0:
    createDir(outputDir)

  image.writeFile(outputPath)
  result.colorsMapped = swaps.len

proc main() =
  let args = commandLineParams()
  if args.len == 1 and args[0] in ["-h", "--help", "help"]:
    echo usage()
    return

  var palettePath, inputPath, outputPath: string
  case args.len
  of 2:
    palettePath = defaultPalettePath()
    inputPath = args[0]
    outputPath = args[1]
  of 3:
    palettePath = args[0]
    inputPath = args[1]
    outputPath = args[2]
  else:
    die("Expected 2 or 3 arguments.")

  try:
    let stats = swapImage(palettePath, inputPath, outputPath)
    echo "Palette: ", palettePath
    echo "Input:   ", inputPath
    echo "Output:  ", outputPath
    echo "Mapped ", stats.colorsMapped, " colors and swapped ", stats.pixelsChanged, " pixels."
  except CatchableError as error:
    die(error.msg)

when isMainModule:
  main()
