import
  std/[os, strutils],
  pixie

type
  ResourceError* = object of ValueError
    ## Raised when a resource file cannot be parsed.

  ResourceRect* = ref object
    ## A named resource rectangle with integer bounds and color.
    name*: string
    x*, y*, w*, h*: int
    color*: ColorRGBA

  ResourceRectDraft = ref object
    name: string
    x, y, w, h: int
    hasX, hasY, hasW, hasH: bool
    color: ColorRGBA
    hasColor: bool

proc trimResourceValue(value: string): string =
  ## Strips whitespace and one optional trailing semicolon.
  result = value.strip()
  if result.endsWith(";"):
    result.setLen(result.len - 1)
    result = result.strip()

proc parseResourcePx(value, fieldName: string): int =
  ## Parses one whole-pixel resource value.
  let clean = value.trimResourceValue()
  if not clean.endsWith("px"):
    raise newException(
      ResourceError,
      "Invalid " & fieldName & " resource value: " & value & "."
    )
  let number = clean[0 ..< clean.len - 2].strip()
  try:
    result = parseInt(number)
  except ValueError:
    raise newException(
      ResourceError,
      "Invalid " & fieldName & " resource value: " & value & "."
    )

proc hexValue(ch: char): int =
  ## Converts one hexadecimal digit to an integer value.
  case ch
  of '0' .. '9':
    ord(ch) - ord('0')
  of 'a' .. 'f':
    ord(ch) - ord('a') + 10
  of 'A' .. 'F':
    ord(ch) - ord('A') + 10
  else:
    -1

proc hexByte(value: string, index: int): uint8 =
  ## Parses one byte from two hexadecimal digits.
  let
    hi = hexValue(value[index])
    lo = hexValue(value[index + 1])
  if hi < 0 or lo < 0:
    raise newException(
      ResourceError,
      "Invalid resource color: " & value & "."
    )
  uint8(hi * 16 + lo)

proc parseHexColor(value: string): ColorRGBA =
  ## Parses one six-digit resource hex color.
  let clean = value.trimResourceValue()
  if clean.len != 7 or clean[0] != '#':
    raise newException(ResourceError, "Invalid resource color: " & value & ".")
  rgba(clean.hexByte(1), clean.hexByte(3), clean.hexByte(5), 255)

proc parseColorByte(value, fieldName: string): uint8 =
  ## Parses one decimal color channel.
  try:
    let parsed = parseInt(value.strip())
    if parsed < 0 or parsed > 255:
      raise newException(ValueError, "out of byte range")
    uint8(parsed)
  except ValueError:
    raise newException(
      ResourceError,
      "Invalid " & fieldName & " resource color channel: " & value & "."
    )

proc alphaByte(value: string): uint8 =
  ## Parses one decimal alpha channel.
  try:
    let parsed = parseFloat(value.strip())
    let scaled =
      if parsed <= 1.0:
        int(parsed * 255.0 + 0.5)
      else:
        int(parsed + 0.5)
    uint8(max(0, min(255, scaled)))
  except ValueError:
    raise newException(
      ResourceError,
      "Invalid alpha resource color channel: " & value & "."
    )

proc parseRgbaColor(value: string): ColorRGBA =
  ## Parses one CSS rgba or rgb resource color.
  let
    clean = value.trimResourceValue()
    lower = clean.toLowerAscii()
    isRgba = lower.startsWith("rgba(") and clean.endsWith(")")
    isRgb = lower.startsWith("rgb(") and clean.endsWith(")")
  if not isRgba and not isRgb:
    raise newException(ResourceError, "Invalid resource color: " & value & ".")
  let
    prefixLen = if isRgba: 5 else: 4
    inner = clean[prefixLen ..< clean.len - 1]
    parts = inner.split(",")
  if (isRgba and parts.len != 4) or (isRgb and parts.len != 3):
    raise newException(ResourceError, "Invalid resource color: " & value & ".")
  rgba(
    parseColorByte(parts[0], "red"),
    parseColorByte(parts[1], "green"),
    parseColorByte(parts[2], "blue"),
    if isRgba: alphaByte(parts[3]) else: 255'u8
  )

proc parseResourceColor(value: string): ColorRGBA =
  ## Parses one CSS-like resource color value.
  let clean = value.trimResourceValue()
  if clean.startsWith("#"):
    return parseHexColor(clean)
  if clean.toLowerAscii().startsWith("rgb"):
    return parseRgbaColor(clean)
  let hash = clean.find('#')
  if hash >= 0 and hash + 7 <= clean.len:
    return parseHexColor(clean[hash ..< hash + 7])
  raise newException(ResourceError, "Invalid resource color: " & value & ".")

proc parseResourceName(line: string): string =
  ## Parses one resource block name comment.
  let text = line.strip()
  if text.len < 4 or not text.startsWith("/*") or not text.endsWith("*/"):
    return
  text[2 ..< text.len - 2].strip()

proc splitResourceProperty(line: string): tuple[key, value: string] =
  ## Splits one resource property line into a key and value.
  let
    text = line.strip()
    colon = text.find(':')
  if colon < 0:
    return
  result.key = text[0 ..< colon].strip().toLowerAscii()
  if colon + 1 < text.len:
    result.value = text[colon + 1 ..< text.len].strip()

proc addResourceRect(
  rects: var seq[ResourceRect],
  draft: ResourceRectDraft
) =
  ## Appends one complete rectangle draft.
  if draft == nil:
    return
  if draft.name.len == 0 or
      not draft.hasX or
      not draft.hasY or
      not draft.hasW or
      not draft.hasH or
      not draft.hasColor:
    return
  if draft.w <= 0 or draft.h <= 0:
    return
  rects.add ResourceRect(
    name: draft.name,
    x: draft.x,
    y: draft.y,
    w: draft.w,
    h: draft.h,
    color: draft.color
  )

proc parseResourceRects*(
  data: string,
  source = ""
): seq[ResourceRect] =
  ## Parses complete named rectangle blocks from resource text.
  var
    draft = ResourceRectDraft()
    lineNumber = 0
  for line in data.splitLines():
    inc lineNumber
    try:
      let name = line.parseResourceName()
      if name.len > 0:
        result.addResourceRect(draft)
        draft = ResourceRectDraft(name: name)
        continue
      let property = line.splitResourceProperty()
      if property.key.len == 0:
        continue
      case property.key
      of "width":
        draft.w = parseResourcePx(property.value, "width")
        draft.hasW = true
      of "height":
        draft.h = parseResourcePx(property.value, "height")
        draft.hasH = true
      of "left":
        draft.x = parseResourcePx(property.value, "left")
        draft.hasX = true
      of "top":
        draft.y = parseResourcePx(property.value, "top")
        draft.hasY = true
      of "background", "border":
        draft.color = parseResourceColor(property.value)
        draft.hasColor = true
      else:
        discard
    except ResourceError as e:
      let prefix =
        if source.len > 0:
          source & ":" & $lineNumber & ": "
        else:
          "line " & $lineNumber & ": "
      raise newException(ResourceError, prefix & e.msg)
  result.addResourceRect(draft)

proc loadResourceRects*(path: string): seq[ResourceRect] =
  ## Loads complete named rectangle blocks from one resource file.
  if not fileExists(path):
    return @[]
  parseResourceRects(readFile(path), path)
