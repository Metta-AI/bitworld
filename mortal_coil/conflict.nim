import std/random
import protocol, server, soul, choose, data, output, render_utils

const
  ConflictTitleTicks* = 24 * 3
  ConflictDescTicks* = 24 * 10
  ConflictSceneReadTicks* = 24 * 10
  ConflictSceneAcceptTicks* = 24 * 1
  ConflictResolutionTicks* = 24 * 10
  ConflictMaxRounds* = 3
  BackgroundColor = 1'u8

proc startConflictSceneTurn(conflictState: var ConflictState) =
  conflictState.sceneState = SceneState(step: SceneGazing)
  conflictState.sceneTimer = 1

proc startConflictChoices*(players: seq[Player], rng: var Rand,
    conflictState: var ConflictState, currentTurn: var int) =
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
  let situation = Situation(title: conflict.title, description: conflict.description)
  let scene = player.soul.generateSceneOptions(world, situation, chatLogStrings(chatLog))
  conflictState.sceneState.header = scene.header
  conflictState.sceneState.choice = initChoice(
    @[scene.options[0], scene.options[1], scene.options[2], scene.options[3]], "do nothing")
  conflictState.sceneState.step = SceneReading
  conflictState.sceneTimer = ConflictSceneReadTicks

proc renderConflictChoices*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], players: seq[Player], currentTurn: int,
    conflictState: ConflictState) =
  fb.clearFrame(BackgroundColor)
  let player = players[currentTurn]
  let color = uint8(player.colorIndex)
  let prefix = player.name & "'s turn:"
  fb.blitTextTinted(letterSprites, digitSprites, prefix, TextMargin, 4, color)

  var choicesY = 4 + CharHeight + 4
  if conflictState.sceneState.header.len > 0:
    let headerY = 4 + CharHeight + 2
    let maxChars = charsFromX(TextMargin)
    let header = if conflictState.sceneState.header.len > maxChars * 2:
        conflictState.sceneState.header[0 ..< maxChars * 2]
      else:
        conflictState.sceneState.header
    let rows = fb.blitTextWrapped(letterSprites, digitSprites, header, TextMargin, headerY, 8)
    choicesY = headerY + rows * 8 + 2

  let showCursor = player.kind == PlayerHuman and conflictState.sceneState.step == SceneReading
  discard renderChoices(fb, letterSprites, digitSprites,
    conflictState.sceneState.choice, color, showCursor, startY = choicesY)

proc renderConflict*(fb: var Framebuffer, letterSprites: seq[Sprite],
    digitSprites: array[10, Sprite], players: seq[Player], currentTurn: int,
    conflictState: ConflictState, conflict: Conflict) =
  fb.clearFrame(0)
  case conflictState.step
  of ConflictGazing:
    let line1 = "conflict"
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight) div 2
    fb.blitTextTinted(letterSprites, line1, x1, y1, 5)
  of ConflictTitle:
    let line1 = "conflict"
    let line2 = conflict.title
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let x2 = (ScreenWidth - line2.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight * 2 - 2) div 2
    let y2 = y1 + CharHeight + 2
    fb.blitTextTinted(letterSprites, line1, x1, y1, 5)
    fb.blitTextTinted(letterSprites, digitSprites, line2, x2, y2, 5)
  of ConflictDescription:
    let maxChars = charsFromX(TextMargin)
    let lineCount = max(1, (conflict.description.len + maxChars - 1) div maxChars)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.blitTextWrappedTinted(letterSprites, digitSprites, conflict.description, TextMargin, startY, 8, 5)
  of ConflictChoices:
    fb.renderConflictChoices(letterSprites, digitSprites, players, currentTurn, conflictState)
  of ConflictResolution:
    let maxChars = charsFromX(TextMargin)
    let lineCount = max(1, (conflictState.resolution.len + maxChars - 1) div maxChars)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard fb.blitTextWrappedTinted(letterSprites, digitSprites, conflictState.resolution, TextMargin, startY, 8, 5)

type
  ConflictStepResult* = enum
    ConflictContinue
    ConflictDone

proc stepConflict*(players: var seq[Player], currentTurn: var int,
    conflictState: var ConflictState, conflictTimer: var int,
    conflict: var Conflict, world: World, situation: Situation,
    chatLog: var seq[ChatEntry], rng: var Rand,
    inputs, prevInputs: seq[InputState]): ConflictStepResult =
  dec conflictTimer

  if conflictState.step == ConflictGazing and conflictTimer <= 0:
    conflict = players[0].soul.generateConflict(world, situation, chatLogStrings(chatLog))
    conflictState.step = ConflictTitle
    conflictTimer = ConflictTitleTicks

  elif conflictState.step == ConflictTitle and conflictTimer <= 0:
    conflictState.step = ConflictDescription
    conflictTimer = ConflictDescTicks
    logConflict(conflict.title, conflict.description)

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
      let player = players[currentTurn]
      let sel = conflictState.sceneState.choice.selected
      let actionText = if sel < conflictState.sceneState.choice.options.len:
          conflictState.sceneState.choice.options[sel]
        else:
          "do nothing"
      logConflictAction(player, actionText)
      chatLog.add(ChatEntry(
        name: player.name,
        colorIndex: uint8(player.colorIndex),
        text: actionText
      ))
      conflictState.sceneTurnIndex += 1
      if conflictState.sceneTurnIndex >= conflictState.sceneTurnOrder.len:
        conflictState.round += 1
        if conflictState.round >= ConflictMaxRounds:
          let resolution = players[0].soul.generateConflictResolution(
            world, conflict, chatLogStrings(chatLog))
          conflictState.resolution = resolution
          conflictState.step = ConflictResolution
          conflictTimer = ConflictResolutionTicks
          logConflictResolution(resolution)
        else:
          let escalation = players[0].soul.generateConflictEscalation(
            world, conflict, conflictState.round - 1, chatLogStrings(chatLog))
          conflict.description = escalation
          logConflictEscalation(conflictState.round - 1, escalation)
          conflictState.step = ConflictDescription
          conflictTimer = ConflictDescTicks
      else:
        currentTurn = conflictState.sceneTurnOrder[conflictState.sceneTurnIndex]
        startConflictSceneTurn(conflictState)

  elif conflictState.step == ConflictResolution and conflictTimer <= 0:
    return ConflictDone

  ConflictContinue
