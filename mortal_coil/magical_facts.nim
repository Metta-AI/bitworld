import std/random
import protocol, server, soul, choose, data, output, render_utils

const
  FactReadTicks* = 24 * 3
  FactAcceptTicks* = 24 * 1
  BackgroundColor = 1'u8

proc generateFactOptions*(players: seq[Player], currentTurn: int,
    world: World, chatLog: seq[ChatEntry], factChoice: var FactChoice, factTimer: var int) =
  let player = players[currentTurn]
  let chatStrings = chatLogStrings(chatLog)
  let facts = player.soul.generateFacts(world, chatStrings)
  factChoice.choice = initChoice(@[facts[0], facts[1], facts[2]], "skip")
  factChoice.step = FactReading
  factTimer = FactReadTicks

proc startFactTurn*(factChoice: var FactChoice, factTimer: var int) =
  factChoice = FactChoice(step: FactGazing)
  factTimer = 1

proc renderGazing*(fb: var Framebuffer, letterSprites: seq[Sprite]) =
  fb.clearFrame(0)
  let line1 = "gazing into"
  let line2 = "the void"
  let x1 = (ScreenWidth - line1.len * CharWidth) div 2
  let x2 = (ScreenWidth - line2.len * CharWidth) div 2
  let y1 = (ScreenHeight - CharHeight * 2 - 2) div 2
  let y2 = y1 + CharHeight + 2
  fb.blitTextTinted(letterSprites, line1, x1, y1, 9)
  fb.blitTextTinted(letterSprites, line2, x2, y2, 9)

proc renderVoteBox(fb: var Framebuffer, letterSprites: seq[Sprite],
    x, y, w, h: int, vote: Vote, color: uint8) =
  fb.fillRect(x, y, w, 1, color)
  fb.fillRect(x, y + h - 1, w, 1, color)
  fb.fillRect(x, y, 1, h, color)
  fb.fillRect(x + w - 1, y, 1, h, color)
  case vote
  of VotePending:
    let passX = x + (w - 4 * CharWidth) div 2
    fb.blitText(letterSprites, "pass", passX, y + 2)
    let vetoX = x + (w - 4 * CharWidth) div 2
    fb.blitText(letterSprites, "veto", vetoX, y + 9)
  of VotePass:
    let passX = x + (w - 4 * CharWidth) div 2
    fb.blitTextTinted(letterSprites, "pass", passX, y + 5, color)
  of VoteVeto:
    let vetoX = x + (w - 4 * CharWidth) div 2
    fb.blitTextTinted(letterSprites, "veto", vetoX, y + 5, color)

proc renderVotePanel(fb: var Framebuffer, letterSprites: seq[Sprite],
    players: seq[Player], currentTurn: int, factChoice: FactChoice) =
  let voterCount = players.len - 1
  if voterCount <= 0:
    return
  let boxH = 16
  let twoCols = voterCount > 3
  if twoCols:
    let gap = 2
    let colW = (ScreenWidth - TextMargin * 2 - gap) div 2
    let rows = (voterCount + 1) div 2
    let totalH = rows * (boxH + 2)
    var startY = ScreenHeight - totalH
    var col = 0
    var row = 0
    for i in 0 ..< players.len:
      if i == currentTurn:
        continue
      let x = TextMargin + col * (colW + gap)
      let y = startY + row * (boxH + 2)
      if y + boxH > ScreenHeight:
        break
      let color = uint8(players[i].colorIndex)
      fb.renderVoteBox(letterSprites, x, y, colW, boxH, factChoice.votes[i], color)
      col += 1
      if col >= 2:
        col = 0
        row += 1
  else:
    let boxW = ScreenWidth - TextMargin * 2
    let totalH = voterCount * (boxH + 2)
    var voteY = ScreenHeight - totalH
    for i in 0 ..< players.len:
      if i == currentTurn:
        continue
      if voteY + boxH > ScreenHeight:
        break
      let color = uint8(players[i].colorIndex)
      fb.renderVoteBox(letterSprites, TextMargin, voteY, boxW, boxH, factChoice.votes[i], color)
      voteY += boxH + 2

proc renderFactChoices*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], players: seq[Player], currentTurn: int,
    factChoice: FactChoice) =
  fb.clearFrame(BackgroundColor)
  let player = players[currentTurn]
  let color = uint8(player.colorIndex)
  let voting = factChoice.step in {FactVoting, FactVoteResult}
  let suffix = if voting: " proposal" else: " choose"
  let nameX = TextMargin
  fb.blitTextTinted(letterSprites, digitSprites, player.name, nameX, 4, color)
  let suffixX = nameX + player.name.len * CharWidth
  fb.blitText(letterSprites, digitSprites, suffix, suffixX, 4)

  let showCursor = player.kind == PlayerHuman and factChoice.step == FactReading
  let y = renderChoices(fb, letterSprites, digitSprites,
    factChoice.choice, color, showCursor, voting)

  if voting:
    fb.renderVotePanel(letterSprites, players, currentTurn, factChoice)
  else:
    let tokenText = "power " & $player.power
    let tokenX = (ScreenWidth - tokenText.len * CharWidth) div 2
    let tokenY = y + (ScreenHeight - y - CharHeight) div 2
    fb.blitTextTinted(letterSprites, digitSprites, tokenText, tokenX, tokenY, color)

proc entryLineCount*(entry: ChatEntry): int =
  let maxNameChars = min(entry.name.len, charsFromX(TextMargin) - 1)
  let textX = TextMargin + (maxNameChars + 1) * CharWidth
  let maxTextChars = charsFromX(textX)
  if maxTextChars <= 0 or entry.text.len == 0:
    return 1
  result = 1
  var pos = maxTextChars
  let wrapChars = charsFromX(TextMargin)
  while pos < entry.text.len:
    inc result
    pos += wrapChars

proc renderFactChat*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], chatLog: seq[ChatEntry], chatScroll: int) =
  fb.clearFrame(BackgroundColor)
  fb.blitText(letterSprites, "magical facts", TextMargin, 4)

  var scroll = chatScroll
  if scroll >= chatLog.len:
    scroll = max(0, chatLog.len - 1)

  let startY = 14
  let availableLines = (ScreenHeight - startY) div 8
  let endIdx = min(scroll + 1, chatLog.len)

  var startIdx = endIdx
  var totalLines = 0
  while startIdx > 0:
    let lines = entryLineCount(chatLog[startIdx - 1])
    if totalLines + lines > availableLines:
      break
    totalLines += lines
    dec startIdx

  var y = startY
  for i in startIdx ..< endIdx:
    if y + CharHeight > ScreenHeight:
      break
    let entry = chatLog[i]
    let maxNameChars = min(entry.name.len, charsFromX(TextMargin) - 1)
    let displayName = entry.name[0 ..< maxNameChars]
    fb.blitTextTinted(letterSprites, digitSprites, displayName, TextMargin, y, entry.colorIndex)
    let textX = TextMargin + (maxNameChars + 1) * CharWidth
    let maxTextChars = charsFromX(textX)
    if maxTextChars > 0 and entry.text.len > 0:
      let firstLine = if entry.text.len > maxTextChars: entry.text[0 ..< maxTextChars] else: entry.text
      fb.blitText(letterSprites, digitSprites, firstLine, textX, y)
      y += 8
      var pos = maxTextChars
      let wrapChars = charsFromX(TextMargin)
      while pos < entry.text.len:
        if y + CharHeight > ScreenHeight:
          break
        let lineLen = min(entry.text.len - pos, wrapChars)
        let line = entry.text[pos ..< pos + lineLen]
        fb.blitText(letterSprites, digitSprites, line, TextMargin, y)
        pos += lineLen
        y += 8
    else:
      y += 8

proc renderFact*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], players: seq[Player], currentTurn: int,
    factChoice: FactChoice, chatLog: seq[ChatEntry], chatScroll: int) =
  case factChoice.step
  of FactGazing:
    fb.renderGazing(letterSprites)
  of FactReading, FactSelected, FactVoting, FactVoteResult:
    fb.renderFactChoices(letterSprites, digitSprites, players, currentTurn, factChoice)
  of FactShowChat:
    fb.renderFactChat(letterSprites, digitSprites, chatLog, chatScroll)

type
  FactsStepResult* = enum
    FactsContinue
    FactsDone

proc stepMagicalFacts*(players: var seq[Player], currentTurn: var int,
    factChoice: var FactChoice, factTimer: var int,
    chatLog: var seq[ChatEntry], chatScroll: var int,
    chatConfirmed: var seq[bool], chatInterrupted: var seq[bool],
    world: World, rng: var Rand,
    inputs, prevInputs: seq[InputState]): FactsStepResult =
  dec factTimer
  let turnPlayer = players[currentTurn]
  let turnIsHuman = turnPlayer.kind == PlayerHuman
  let turnPrev = if currentTurn < prevInputs.len: prevInputs[currentTurn]
                 else: InputState()
  let turnCur = if currentTurn < inputs.len: inputs[currentTurn]
                else: InputState()
  let turnInput = released(turnCur, turnPrev)

  if factChoice.step == FactGazing and factTimer <= 0:
    generateFactOptions(players, currentTurn, world, chatLog, factChoice, factTimer)

  elif factChoice.step == FactVoting:
    var allVoted = true
    for i in 0 ..< factChoice.votes.len:
      if factChoice.votes[i] == VotePending:
        if players[i].kind == PlayerHuman:
          let voterPrev = if i < prevInputs.len: prevInputs[i] else: InputState()
          let voterCur = if i < inputs.len: inputs[i] else: InputState()
          let voterRel = released(voterCur, voterPrev)
          if voterRel.attack:
            factChoice.votes[i] = VotePass
          elif voterRel.b:
            factChoice.votes[i] = VoteVeto
          else:
            allVoted = false
        else:
          dec factChoice.voteTimers[i]
          if factChoice.voteTimers[i] <= 0:
            if rng.rand(3) <= 1:
              factChoice.votes[i] = VotePass
            else:
              factChoice.votes[i] = VoteVeto
          else:
            allVoted = false
    if allVoted:
      factChoice.step = FactVoteResult
      factChoice.voteResultTimer = FactAcceptTicks

  elif factChoice.step == FactVoteResult:
    dec factChoice.voteResultTimer
    if factChoice.voteResultTimer <= 0:
      var vetoCount = 0
      for v in factChoice.votes:
        if v == VoteVeto:
          inc vetoCount
      let player = players[currentTurn]
      let factText = factChoice.choice.options[factChoice.choice.selected]
      logFactOutcome(players, currentTurn, factText, factChoice.votes)
      let passed = vetoCount * 2 < factChoice.votes.len
      if not passed:
        chatLog.add(ChatEntry(
          name: player.name,
          colorIndex: uint8(player.colorIndex),
          text: "vetoed"
        ))
      else:
        players[currentTurn].power -= 1
        chatLog.add(ChatEntry(
          name: player.name,
          colorIndex: uint8(player.colorIndex),
          text: factText
        ))
      factChoice.step = FactShowChat
      chatScroll = chatLog.len - 1
      chatConfirmed = newSeq[bool](players.len)
      chatInterrupted = newSeq[bool](players.len)
      factTimer = FactAcceptTicks * 4

  elif factChoice.step == FactReading:
    if turnIsHuman:
      factChoice.choice.handleChoiceInput(turnInput)
      players[currentTurn].cursor = factChoice.choice.cursor
      if factChoice.choice.state == ChoiceSelected:
        factChoice.step = FactSelected
        factTimer = FactAcceptTicks
    elif factTimer <= 0:
      let pick = rng.rand(3)
      factChoice.choice.selected = pick
      factChoice.choice.state = ChoiceSelected
      factChoice.step = FactSelected
      factTimer = FactAcceptTicks

  elif factChoice.step == FactSelected:
    if factTimer > 0:
      discard
    elif factChoice.choice.selected >= 0 and factChoice.choice.selected < 3:
      factChoice.step = FactVoting
      factChoice.votes = @[]
      factChoice.voteTimers = @[]
      for i in 0 ..< players.len:
        if i == currentTurn:
          factChoice.votes.add(VotePass)
          factChoice.voteTimers.add(0)
        else:
          factChoice.votes.add(VotePending)
          factChoice.voteTimers.add(24 * (rng.rand(3) + 1))
    else:
      let player = players[currentTurn]
      logFactSkipped(player.name)
      chatLog.add(ChatEntry(
        name: player.name,
        colorIndex: uint8(player.colorIndex),
        text: "skip"
      ))
      factChoice.step = FactShowChat
      chatScroll = chatLog.len - 1
      chatConfirmed = newSeq[bool](players.len)
      chatInterrupted = newSeq[bool](players.len)
      factTimer = FactAcceptTicks * 4

  elif factChoice.step == FactShowChat:
    for i in 0 ..< players.len:
      if players[i].kind == PlayerBot:
        if factTimer <= 0:
          chatConfirmed[i] = true
      else:
        let cur = if i < inputs.len: inputs[i] else: InputState()
        let prev = if i < prevInputs.len: prevInputs[i] else: InputState()
        let rel = released(cur, prev)
        if rel.down:
          chatScroll = min(chatScroll + 1, max(0, chatLog.len - 1))
          chatInterrupted[i] = true
        elif rel.up:
          chatScroll = max(chatScroll - 1, 0)
          chatInterrupted[i] = true
        elif rel.attack and chatInterrupted[i]:
          chatConfirmed[i] = true
        if factTimer <= 0 and not chatInterrupted[i]:
          chatConfirmed[i] = true
    var allConfirmed = true
    for i in 0 ..< players.len:
      if not chatConfirmed[i]:
        allConfirmed = false
        break
    if allConfirmed:
      currentTurn += 1
      if currentTurn >= players.len:
        return FactsDone
      startFactTurn(factChoice, factTimer)

  FactsContinue
