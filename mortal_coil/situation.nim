import std/random
import protocol, server, soul, choose, data, output, render_utils

const
  SituationTitleTicks* = 24 * 3
  SituationDescTicks* = 24 * 10
  SceneReadTicks* = 24 * 10
  SceneAcceptTicks* = 24 * 1
  BackgroundColor = 1'u8

proc generateSceneOpts(players: seq[Player], currentTurn: int,
    world: World, situation: Situation, chatLog: seq[ChatEntry],
    sceneState: var SceneState, sceneTimer: var int) =
  let player = players[currentTurn]
  let opts = player.soul.generateSceneOptions(world, situation, chatLogStrings(chatLog))
  sceneState.choice = initChoice(@[opts[0], opts[1], opts[2], opts[3]], "do nothing")
  sceneState.step = SceneReading
  sceneTimer = SceneReadTicks

proc startSceneTurn*(sceneState: var SceneState, sceneTimer: var int) =
  sceneState = SceneState(step: SceneGazing)
  sceneTimer = 1

proc startSceneChoices*(players: seq[Player], rng: var Rand,
    sceneTurnOrder: var seq[int], sceneTurnIndex: var int,
    currentTurn: var int, sceneState: var SceneState, sceneTimer: var int) =
  sceneTurnOrder = @[]
  for i in 0 ..< players.len:
    sceneTurnOrder.add(i)
  rng.shuffle(sceneTurnOrder)
  sceneTurnIndex = 0
  currentTurn = sceneTurnOrder[0]
  startSceneTurn(sceneState, sceneTimer)

proc renderSceneChoices*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], players: seq[Player], currentTurn: int,
    sceneState: SceneState) =
  fb.clearFrame(BackgroundColor)
  let player = players[currentTurn]
  let color = uint8(player.colorIndex)
  let nameX = TextMargin
  fb.blitTextTinted(letterSprites, digitSprites, player.name, nameX, 4, color)
  let suffixX = nameX + player.name.len * CharWidth
  fb.blitText(letterSprites, digitSprites, " act", suffixX, 4)

  let showCursor = player.kind == PlayerHuman and sceneState.step == SceneReading
  discard renderChoices(fb, letterSprites, digitSprites,
    sceneState.choice, color, showCursor)

proc renderSituation*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], players: seq[Player], currentTurn: int,
    situationStep: SituationStep, situation: Situation, sceneState: SceneState) =
  fb.clearFrame(0)
  case situationStep
  of SituationGazing:
    let line1 = "situation"
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight) div 2
    fb.blitTextTinted(letterSprites, line1, x1, y1, 5)
  of SituationTitle:
    let line1 = "situation"
    let line2 = situation.title
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let x2 = (ScreenWidth - line2.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight * 2 - 2) div 2
    let y2 = y1 + CharHeight + 2
    fb.blitTextTinted(letterSprites, line1, x1, y1, 5)
    fb.blitTextTinted(letterSprites, digitSprites, line2, x2, y2, 5)
  of SituationDescription:
    let maxChars = charsFromX(TextMargin)
    let lineCount = max(1, (situation.description.len + maxChars - 1) div maxChars)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.blitTextWrappedTinted(letterSprites, digitSprites, situation.description, TextMargin, startY, 8, 5)
  of SituationChoices:
    fb.renderSceneChoices(letterSprites, digitSprites, players, currentTurn, sceneState)

type
  SituationStepResult* = enum
    SituationContinue
    SituationToEnd
    SituationToFacts

proc stepSituation*(players: var seq[Player], currentTurn: var int,
    situationStep: var SituationStep, situationTimer: var int,
    situation: var Situation, situations: var seq[Situation],
    sceneState: var SceneState, sceneTimer: var int,
    sceneTurnOrder: var seq[int], sceneTurnIndex: var int,
    world: World, chatLog: var seq[ChatEntry], rng: var Rand,
    inputs, prevInputs: seq[InputState]): SituationStepResult =
  dec situationTimer
  if situationStep == SituationGazing and situationTimer <= 0:
    situation = players[0].soul.generateSituation(
      world, chatLogStrings(chatLog), situations)
    situationStep = SituationTitle
    situationTimer = SituationTitleTicks
  elif situationStep == SituationTitle and situationTimer <= 0:
    situationStep = SituationDescription
    situationTimer = SituationDescTicks
    logSituation(situation.title, situation.description)
  elif situationStep == SituationDescription and situationTimer <= 0:
    situationStep = SituationChoices
    startSceneChoices(players, rng, sceneTurnOrder, sceneTurnIndex,
      currentTurn, sceneState, sceneTimer)

  elif situationStep == SituationChoices:
    dec sceneTimer
    let turnPlayer = players[currentTurn]
    let turnIsHuman = turnPlayer.kind == PlayerHuman
    let turnPrev = if currentTurn < prevInputs.len: prevInputs[currentTurn]
                   else: InputState()
    let turnCur = if currentTurn < inputs.len: inputs[currentTurn]
                  else: InputState()
    let turnInput = released(turnCur, turnPrev)

    if sceneState.step == SceneGazing and sceneTimer <= 0:
      generateSceneOpts(players, currentTurn, world, situation, chatLog,
        sceneState, sceneTimer)

    elif sceneState.step == SceneReading and sceneState.choice.state == ChoiceReading:
      if turnIsHuman:
        sceneState.choice.handleChoiceInput(turnInput)
        players[currentTurn].cursor = sceneState.choice.cursor
        if sceneState.choice.state == ChoiceSelected:
          sceneTimer = SceneAcceptTicks
      elif sceneTimer <= 0:
        let pick = rng.rand(sceneState.choice.optionCount() - 1)
        sceneState.choice.selected = pick
        sceneState.choice.state = ChoiceSelected
        sceneTimer = SceneAcceptTicks

    elif sceneState.choice.state == ChoiceSelected and sceneTimer <= 0:
      let player = players[currentTurn]
      let sel = sceneState.choice.selected
      let actionText = if sel < sceneState.choice.options.len:
          sceneState.choice.options[sel]
        else:
          "do nothing"
      logSituationAction(player, actionText)
      chatLog.add(ChatEntry(
        name: player.name,
        colorIndex: uint8(player.colorIndex),
        text: actionText
      ))
      sceneTurnIndex += 1
      if sceneTurnIndex >= sceneTurnOrder.len:
        situations.add(situation)
        var allSpent = true
        for p in players:
          if p.magicTokens > 0:
            allSpent = false
            break
        if allSpent:
          return SituationToEnd
        else:
          return SituationToFacts
      else:
        currentTurn = sceneTurnOrder[sceneTurnIndex]
        startSceneTurn(sceneState, sceneTimer)

  SituationContinue
