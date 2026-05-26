import std/random
import bitworld/protocol, bitworld/server, soul, choose, data, output, render_utils

const
  SituationTitleTicks* = 24 * 3
  SituationDescTicks* = 24 * 10
  SceneReadTicks* = 24 * 10
  SceneAcceptTicks* = 24 * 2
  BackgroundColor = 0'u8

proc generateSceneOpts(players: seq[Player], currentTurn: int,
    world: World, situation: Situation, chatLog: seq[ChatEntry],
    sceneState: var SceneState, sceneTimer: var int) =
  let player = players[currentTurn]
  let scene = player.soul.generateSceneOptions(world, situation, chatLogStrings(chatLog))
  sceneState.header = scene.header
  sceneState.choice = initChoice(@[scene.options[0], scene.options[1], scene.options[2], scene.options[3]], "Do nothing.")
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

proc renderSceneChoices*(fb: var Framebuffer, players: seq[Player],
    currentTurn: int, sceneState: SceneState) =
  fb.clearFrame(BackgroundColor)
  let player = players[currentTurn]
  let color = uint8(player.colorIndex)
  let prefix = player.name & "'s turn:"
  fb.drawText(prefix, TextMargin, 4, color)

  var choicesY = 4 + font.height + 4
  if sceneState.header.len > 0:
    let headerY = 4 + font.height + 2
    let maxWidth = ScreenWidth - TextMargin * 2
    let maxHeaderChars = fitChars(sceneState.header, maxWidth * 2)
    let header = if sceneState.header.len > maxHeaderChars:
        sceneState.header[0 ..< maxHeaderChars]
      else:
        sceneState.header
    let rows = fb.drawTextWrapped(header, TextMargin, headerY, 8)
    choicesY = headerY + rows * 8 + 2

  let showCursor = player.kind == PlayerHuman and sceneState.step == SceneReading
  discard renderChoices(fb, sceneState.choice, color, showCursor, startY = choicesY)

proc renderSituation*(fb: var Framebuffer, players: seq[Player],
    currentTurn: int, situationStep: SituationStep, situation: Situation,
    sceneState: SceneState) =
  fb.clearFrame(0)
  case situationStep
  of SituationGazing:
    let line1 = "Situation"
    let x1 = (ScreenWidth - textW(line1)) div 2
    let y1 = (ScreenHeight - font.height) div 2
    fb.drawText(line1, x1, y1, 5)
  of SituationTitle:
    let line1 = "Situation"
    let line2 = situation.title
    let x1 = (ScreenWidth - textW(line1)) div 2
    let x2 = (ScreenWidth - textW(line2)) div 2
    let y1 = (ScreenHeight - font.height * 2 - 2) div 2
    let y2 = y1 + font.height + 2
    fb.drawText(line1, x1, y1, 5)
    fb.drawText(line2, x2, y2, 5)
  of SituationDescription:
    let maxWidth = ScreenWidth - TextMargin * 2
    let lineCount = wrapLineCount(situation.description, maxWidth)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.drawTextWrapped(situation.description, TextMargin, startY, 8, 5)
  of SituationChoices:
    fb.renderSceneChoices(players, currentTurn, sceneState)

type
  SituationStepResult* = enum
    SituationContinue
    SituationDone

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
          "Do nothing."
      logSituationAction(player, actionText)
      chatLog.add(ChatEntry(
        name: player.name,
        colorIndex: uint8(player.colorIndex),
        text: actionText
      ))
      sceneTurnIndex += 1
      if sceneTurnIndex >= sceneTurnOrder.len:
        situations.add(situation)
        return SituationDone
      else:
        currentTurn = sceneTurnOrder[sceneTurnIndex]
        startSceneTurn(sceneState, sceneTimer)

  SituationContinue
