import bitworld/protocol, bitworld/server, render_utils

type
  ChoiceState* = enum
    ChoiceReading
    ChoiceSelected

  ChoiceCtx* = object
    options*: seq[string]
    extraOption*: string
    cursor*: int
    selected*: int
    state*: ChoiceState

proc initChoice*(options: seq[string], extraOption: string = ""): ChoiceCtx =
  result.options = options
  result.extraOption = extraOption
  result.cursor = 0
  result.selected = -1
  result.state = ChoiceReading

proc optionCount*(ctx: ChoiceCtx): int =
  result = ctx.options.len
  if ctx.extraOption.len > 0:
    inc result

proc renderChoices*(fb: var Framebuffer, ctx: ChoiceCtx, color: uint8,
    showCursor: bool, showFrame: bool = true, startY: int = 14): int =
  let textX = TextMargin + 8
  var y = startY

  for i in 0 ..< ctx.options.len:
    let selected = ctx.state >= ChoiceSelected and ctx.selected == i
    let cursored = showCursor and ctx.cursor == i
    if selected or cursored:
      fb.fillRect(TextMargin, y, 6, 6, color)
    else:
      fb.fillRect(TextMargin + 1, y + 1, 4, 4, color)
    let lines = fb.drawTextWrapped(ctx.options[i], textX, y, 8, WhiteColor)
    if selected and showFrame:
      let frameX = TextMargin - 2
      let frameY = y - 2
      let frameW = ScreenWidth - TextMargin * 2 + 4
      let frameH = lines * 8 + 2
      fb.fillRect(frameX, frameY, frameW, 1, color)
      fb.fillRect(frameX, frameY + frameH - 1, frameW, 1, color)
      fb.fillRect(frameX, frameY, 1, frameH, color)
      fb.fillRect(frameX + frameW - 1, frameY, 1, frameH, color)
    y += lines * 8 + 2

  if ctx.extraOption.len > 0 and y + font.height <= ScreenHeight:
    let extraIdx = ctx.options.len
    let selectedExtra = ctx.state >= ChoiceSelected and ctx.selected >= extraIdx
    let cursoredExtra = showCursor and ctx.cursor >= extraIdx
    if selectedExtra or cursoredExtra:
      fb.fillRect(TextMargin, y, 6, 6, color)
    else:
      fb.fillRect(TextMargin + 1, y + 1, 4, 4, color)
    fb.drawText(ctx.extraOption, textX, y)
    y += font.height + 4

  y

proc handleChoiceInput*(ctx: var ChoiceCtx, input: InputState) =
  if ctx.state != ChoiceReading:
    return
  let maxIdx = ctx.optionCount() - 1
  if input.down:
    ctx.cursor = min(ctx.cursor + 1, maxIdx)
  elif input.up:
    ctx.cursor = max(ctx.cursor - 1, 0)
  elif input.attack:
    ctx.selected = ctx.cursor
    ctx.state = ChoiceSelected
