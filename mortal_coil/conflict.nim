import std/[random, strutils]
import protocol, server, soul, choose, data, output, render_utils

const
  ConflictTitleTicks* = 24 * 3
  ConflictDescTicks* = 24 * 10
  ConflictSceneReadTicks* = 24 * 10
  ConflictSceneAcceptTicks* = 24 * 1
  ConflictOutcomeTicks* = 24 * 10
  ConflictRecountLineTicks* = 12  # half second per line at 24fps
  ConflictRecountHoldTicks* = 24  # 1 second after last line
  ConflictRecountLines* = 7  # name, burden, party burden, reward, party reward, separator, power
  ConflictResolutionTicks* = 24 * 10
  ConflictMaxRounds* = 3
  BackgroundColor = 0'u8
  EffectColor = 3'u8

proc randomizeSchemes(conflictState: var ConflictState, rng: var Rand) =
  for i in 0 ..< 4:
    conflictState.schemes[i].risk = rng.rand(2)
    conflictState.schemes[i].bearer = RiskTarget(rng.rand(1))
    conflictState.schemes[i].rewarded = RiskTarget(rng.rand(1))

proc startConflictSceneTurn(conflictState: var ConflictState) =
  conflictState.sceneState = SceneState(step: SceneGazing)
  conflictState.sceneTimer = 1

proc startConflictChoices*(players: seq[Player], rng: var Rand,
    conflictState: var ConflictState, currentTurn: var int) =
  randomizeSchemes(conflictState, rng)
  conflictState.roundResults = @[]
  conflictState.sceneTurnOrder = @[]
  for i in 0 ..< players.len:
    conflictState.sceneTurnOrder.add(i)
  rng.shuffle(conflictState.sceneTurnOrder)
  conflictState.sceneTurnIndex = 0
  currentTurn = conflictState.sceneTurnOrder[0]
  startConflictSceneTurn(conflictState)

proc generateConflictSceneOpts(players: seq[Player], currentTurn: int,
    world: World, conflict: Conflict, chatLog: seq[ChatEntry],
    conflictState: var ConflictState) =
  let player = players[currentTurn]
  let scene = player.soul.generateConflictOptions(
    world, conflict, conflictState.schemes, chatLogStrings(chatLog))
  conflictState.sceneState.header = scene.header
  conflictState.sceneState.choice = initChoice(
    @[scene.options[0], scene.options[1], scene.options[2], scene.options[3]], "Do nothing.")
  conflictState.sceneState.step = SceneReading
  conflictState.sceneTimer = ConflictSceneReadTicks

proc effectPrefix(scheme: ChoiceScheme): string =
  "Risk " & $scheme.risk

proc renderConflictChoices*(fb: var Framebuffer, players: seq[Player],
    currentTurn: int, conflictState: ConflictState) =
  fb.clearFrame(BackgroundColor)
  let player = players[currentTurn]
  let color = uint8(player.colorIndex)
  let prefix = player.name & "'s turn:"
  fb.drawText(prefix, TextMargin, 4, color)

  var choicesY = 4 + font.height + 4
  if conflictState.sceneState.header.len > 0:
    let headerY = 4 + font.height + 2
    let maxWidth = ScreenWidth - TextMargin * 2
    let maxHeaderChars = fitChars(conflictState.sceneState.header, maxWidth * 2)
    let header = if conflictState.sceneState.header.len > maxHeaderChars:
        conflictState.sceneState.header[0 ..< maxHeaderChars]
      else:
        conflictState.sceneState.header
    let rows = fb.drawTextWrapped(header, TextMargin, headerY, 8)
    choicesY = headerY + rows * 8 + 2

  let showCursor = player.kind == PlayerHuman and conflictState.sceneState.step == SceneReading
  let ctx = conflictState.sceneState.choice
  let textX = TextMargin + 8
  var y = choicesY

  for i in 0 ..< ctx.options.len:
    let selected = ctx.state >= ChoiceSelected and ctx.selected == i
    let cursored = showCursor and ctx.cursor == i
    if selected or cursored:
      fb.fillRect(TextMargin, y, 6, 6, color)
    else:
      fb.fillRect(TextMargin + 1, y + 1, 4, 4, color)

    let ep = effectPrefix(conflictState.schemes[i])
    fb.drawText(ep, textX, y, EffectColor)
    let padding = ' '.repeat(ep.len + 1)
    let fullText = padding & ctx.options[i]
    let rows = fb.drawTextWrapped(fullText, textX, y, 8)

    if selected:
      let frameX = TextMargin - 2
      let frameY = y - 2
      let frameW = ScreenWidth - TextMargin * 2 + 4
      let frameH = rows * 8 + 3
      fb.fillRect(frameX, frameY, frameW, 1, color)
      fb.fillRect(frameX, frameY + frameH - 1, frameW, 1, color)
      fb.fillRect(frameX, frameY, 1, frameH, color)
      fb.fillRect(frameX + frameW - 1, frameY, 1, frameH, color)
    y += rows * 8 + 2

  if ctx.extraOption.len > 0 and y + font.height <= ScreenHeight:
    let extraIdx = ctx.options.len
    let selectedExtra = ctx.state >= ChoiceSelected and ctx.selected >= extraIdx
    let cursoredExtra = showCursor and ctx.cursor >= extraIdx
    if selectedExtra or cursoredExtra:
      fb.fillRect(TextMargin, y, 6, 6, color)
    else:
      fb.fillRect(TextMargin + 1, y + 1, 4, 4, color)
    fb.drawText(ctx.extraOption, textX, y)

proc renderConflict*(fb: var Framebuffer, players: seq[Player],
    currentTurn: int, conflictState: ConflictState, conflict: Conflict,
    chapter: int) =
  fb.clearFrame(0)
  let chapterLabel = "Chapter " & $chapter
  case conflictState.step
  of ConflictGazing:
    let x1 = (ScreenWidth - textW(chapterLabel)) div 2
    let y1 = (ScreenHeight - font.height) div 2
    fb.drawText(chapterLabel, x1, y1, 5)
  of ConflictTitle:
    let line2 = conflict.title
    let x1 = (ScreenWidth - textW(chapterLabel)) div 2
    let x2 = (ScreenWidth - textW(line2)) div 2
    let y1 = (ScreenHeight - font.height * 2 - 2) div 2
    let y2 = y1 + font.height + 2
    fb.drawText(chapterLabel, x1, y1, 5)
    fb.drawText(line2, x2, y2, 5)
  of ConflictDescription:
    let maxWidth = ScreenWidth - TextMargin * 2
    let lineCount = wrapLineCount(conflict.description, maxWidth)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.drawTextWrapped(conflict.description, TextMargin, startY, 8, 5)
  of ConflictChoices:
    fb.renderConflictChoices(players, currentTurn, conflictState)
  of ConflictOutcome:
    let maxWidth = ScreenWidth - TextMargin * 2
    let lineCount = wrapLineCount(conflictState.outcome, maxWidth)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.drawTextWrapped(conflictState.outcome, TextMargin, startY, 8, 5)
  of ConflictRecount:
    if conflictState.recountPlayer < conflictState.roundResults.len:
      let r = conflictState.roundResults[conflictState.recountPlayer]
      let player = players[r.playerIndex]
      let color = uint8(player.colorIndex)
      let lineH = font.height + 2
      let totalH = ConflictRecountLines * lineH
      let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
      let x = TextMargin
      let visibleLines = conflictState.recountLine + 1

      if visibleLines >= 1:
        fb.drawText(player.name & ":", x, startY, color)
      if visibleLines >= 2:
        fb.drawText("  -" & $r.burdenTaken & " burden taken", x, startY + lineH, EffectColor)
      if visibleLines >= 3:
        fb.drawText("  -" & $r.partyBurden & " party burden", x, startY + lineH * 2, EffectColor)
      if visibleLines >= 4:
        fb.drawText("  +" & $r.rewardEarned & " reward earned", x, startY + lineH * 3, EffectColor)
      if visibleLines >= 5:
        fb.drawText("  +" & $r.partyReward & " party reward", x, startY + lineH * 4, EffectColor)
      if visibleLines >= 6:
        fb.drawText("  ----------", x, startY + lineH * 5, WhiteColor)
      if visibleLines >= 7:
        let total = r.powerBefore - r.burdenTaken - r.partyBurden + r.rewardEarned + r.partyReward
        fb.drawText("  " & $total & " power", x, startY + lineH * 6, color)
  of ConflictResolution:
    let maxWidth = ScreenWidth - TextMargin * 2
    let lineCount = wrapLineCount(conflictState.resolution, maxWidth)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.drawTextWrapped(conflictState.resolution, TextMargin, startY, 8, 5)

type
  ConflictStepResult* = enum
    ConflictContinue
    ConflictDone

proc stepConflict*(players: var seq[Player], currentTurn: var int,
    conflictState: var ConflictState, conflictTimer: var int,
    conflict: var Conflict, world: World, situation: Situation,
    chatLog: var seq[ChatEntry], rng: var Rand,
    inputs, prevInputs: seq[InputState], chapter: int): ConflictStepResult =
  dec conflictTimer

  if conflictState.step == ConflictGazing and conflictTimer <= 0:
    conflict = players[0].soul.generateConflict(world, situation, chatLogStrings(chatLog))
    conflictState.step = ConflictTitle
    conflictTimer = ConflictTitleTicks

  elif conflictState.step == ConflictTitle and conflictTimer <= 0:
    conflictState.step = ConflictDescription
    conflictTimer = ConflictDescTicks
    logConflict(chapter, conflict.title, conflict.description)

  elif conflictState.step == ConflictDescription and conflictTimer <= 0:
    conflictState.step = ConflictChoices
    startConflictChoices(players, rng, conflictState, currentTurn)

  elif conflictState.step == ConflictChoices:
    dec conflictState.sceneTimer
    let turnPlayer = players[currentTurn]
    let turnIsHuman = turnPlayer.kind == PlayerHuman
    let turnPrev = if currentTurn < prevInputs.len: prevInputs[currentTurn]
                   else: InputState()
    let turnCur = if currentTurn < inputs.len: inputs[currentTurn]
                  else: InputState()
    let turnInput = released(turnCur, turnPrev)

    if conflictState.sceneState.step == SceneGazing and conflictState.sceneTimer <= 0:
      generateConflictSceneOpts(players, currentTurn, world, conflict, chatLog, conflictState)

    elif conflictState.sceneState.step == SceneReading and
        conflictState.sceneState.choice.state == ChoiceReading:
      if turnIsHuman:
        conflictState.sceneState.choice.handleChoiceInput(turnInput)
        players[currentTurn].cursor = conflictState.sceneState.choice.cursor
        if conflictState.sceneState.choice.state == ChoiceSelected:
          conflictState.sceneTimer = ConflictSceneAcceptTicks
      elif conflictState.sceneTimer <= 0:
        let pick = rng.rand(conflictState.sceneState.choice.optionCount() - 1)
        conflictState.sceneState.choice.selected = pick
        conflictState.sceneState.choice.state = ChoiceSelected
        conflictState.sceneTimer = ConflictSceneAcceptTicks

    elif conflictState.sceneState.choice.state == ChoiceSelected and conflictState.sceneTimer <= 0:
      let sel = conflictState.sceneState.choice.selected
      let actionText = if sel < conflictState.sceneState.choice.options.len:
          conflictState.sceneState.choice.options[sel]
        else:
          "Do nothing."
      let scheme = if sel < 4: conflictState.schemes[sel]
                   else: ChoiceScheme(risk: 0, bearer: TargetSelf, rewarded: TargetSelf)
      let riskValue = max(1, scheme.risk)
      case scheme.bearer
      of TargetSelf:
        case scheme.rewarded
        of TargetSelf: players[currentTurn].individuality += riskValue
        of TargetOthers: players[currentTurn].cooperativity += riskValue
      of TargetOthers:
        case scheme.rewarded
        of TargetSelf: players[currentTurn].exploitativity += riskValue
        of TargetOthers: players[currentTurn].vicariousness += riskValue
      conflictState.roundResults.add(PlayerRoundResult(
        playerIndex: currentTurn,
        powerBefore: players[currentTurn].power,
        risk: scheme.risk,
        bearer: scheme.bearer,
        rewarded: scheme.rewarded,
      ))
      logConflictAction(players[currentTurn], actionText)
      chatLog.add(ChatEntry(
        name: players[currentTurn].name,
        colorIndex: uint8(players[currentTurn].colorIndex),
        text: actionText
      ))
      conflictState.sceneTurnIndex += 1
      if conflictState.sceneTurnIndex >= conflictState.sceneTurnOrder.len:
        conflictState.round += 1
        var playerNames: seq[string]
        for r in conflictState.roundResults:
          playerNames.add(players[r.playerIndex].name)
        let outcomeResult = players[0].soul.generateConflictOutcome(
          world, conflict, conflictState.round - 1, ConflictMaxRounds, playerNames, chatLogStrings(chatLog))
        conflictState.outcome = outcomeResult.narration
        let partySize = players.len
        for i in 0 ..< conflictState.roundResults.len:
          let score = if i < outcomeResult.scores.len: outcomeResult.scores[i].score else: 0
          conflictState.roundResults[i].choiceResult = score
          let risk = conflictState.roundResults[i].risk
          if conflictState.roundResults[i].bearer == TargetSelf:
            conflictState.roundResults[i].burdenTaken = max(1, risk)
          else:
            conflictState.roundResults[i].partyBurden = max(1, risk div partySize)
          if conflictState.roundResults[i].rewarded == TargetSelf:
            conflictState.roundResults[i].rewardEarned = max(1, risk) * (score + 1)
          else:
            conflictState.roundResults[i].partyReward = max(1, risk div partySize) * (score + 1)
        conflictState.step = ConflictOutcome
        conflictTimer = ConflictOutcomeTicks
        logConflictOutcome(conflictState.round - 1, outcomeResult.narration,
          conflictState.roundResults, players)
      else:
        currentTurn = conflictState.sceneTurnOrder[conflictState.sceneTurnIndex]
        startConflictSceneTurn(conflictState)

  elif conflictState.step == ConflictOutcome and conflictTimer <= 0:
    conflictState.recountPlayer = 0
    conflictState.recountLine = 0
    conflictState.step = ConflictRecount
    conflictTimer = ConflictRecountLineTicks

  elif conflictState.step == ConflictRecount and conflictTimer <= 0:
    conflictState.recountLine += 1
    if conflictState.recountLine >= ConflictRecountLines:
      echo "RECOUNT: player=", conflictState.recountPlayer, " results.len=", conflictState.roundResults.len
      let r = conflictState.roundResults[conflictState.recountPlayer]
      players[r.playerIndex].power += -r.burdenTaken - r.partyBurden + r.rewardEarned + r.partyReward
      conflictState.recountPlayer += 1
      if conflictState.recountPlayer >= conflictState.roundResults.len:
        conflictState.roundResults = @[]
        if conflictState.round >= ConflictMaxRounds:
          let resolution = players[0].soul.generateConflictResolution(
            world, conflict, chatLogStrings(chatLog))
          conflictState.resolution = resolution
          conflictState.step = ConflictResolution
          conflictTimer = ConflictResolutionTicks
          logConflictResolution(resolution)
        else:
          conflictState.step = ConflictChoices
          startConflictChoices(players, rng, conflictState, currentTurn)
      else:
        conflictState.recountLine = 0
        conflictTimer = ConflictRecountLineTicks
    elif conflictState.recountLine == ConflictRecountLines - 1:
      conflictTimer = ConflictRecountHoldTicks
    else:
      conflictTimer = ConflictRecountLineTicks

  elif conflictState.step == ConflictResolution and conflictTimer <= 0:
    return ConflictDone

  ConflictContinue
