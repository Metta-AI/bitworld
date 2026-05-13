import mummy
import protocol, server, soul, choose
import std/[exitprocs, locks, monotimes, os, osproc, parseopt, random, strutils, tables, times]
import windy
import bitworld/clients

const
  TargetFps = 24.0
  WebSocketPath = "/player"
  GlobalWebSocketPath = "/global"
  BackgroundColor = 1'u8
  MaxPlayers = 8
  DefaultMinPlayers = 4
  LobbyCountdownTicks = 24 * 5
  WorldTitleTicks = 24 * 3
  WorldDescTicks = 24 * 10
  SituationTitleTicks = 24 * 3
  SituationDescTicks = 24 * 10
  SceneReadTicks = 24 * 3
  SceneAcceptTicks = 24 * 1
  FactReadTicks = 24 * 3
  FactAcceptTicks = 24 * 1
  CharWidth = 6
  CharHeight = 6
  TextMargin = 4
  ClientScreenOnlyWidth = 384
  ClientScreenOnlyHeight = 384
  ClientWindowMargin = 50
  PlayerClientSourceRelative = "clients" / "player_client.nim"

type
  GamePhase = enum
    PhaseLobby
    PhaseWorld
    PhaseMagicalFacts
    PhaseSituation
    PhaseConflict
    PhasePower
    PhaseEnd

  PlayerKind* = enum
    PlayerHuman
    PlayerBot

  Player = object
    name: string
    colorIndex: int
    ready: bool
    kind: PlayerKind
    soul: Soul
    cursor: int
    magicTokens: int

  ChatEntry = object
    name: string
    colorIndex: uint8
    text: string

  Vote = enum
    VotePending
    VotePass
    VoteVeto

  WorldStep = enum
    WorldGazing
    WorldTitle
    WorldDescription

  SituationStep = enum
    SituationGazing
    SituationTitle
    SituationDescription
    SituationChoices

  SceneStep = enum
    SceneGazing
    SceneReading

  FactStep = enum
    FactGazing
    FactReading
    FactSelected
    FactVoting
    FactVoteResult
    FactShowChat

  FactChoice = object
    choice: ChoiceCtx
    step: FactStep
    votes: seq[Vote]
    voteTimers: seq[int]
    voteResultTimer: int

  SceneState = object
    choice: ChoiceCtx
    step: SceneStep

  SimServer = object
    players: seq[Player]
    phase: GamePhase
    tick: int
    lobbyCountdown: int
    minPlayers: int
    currentTurn: int
    chatLog: seq[ChatEntry]
    factChoice: FactChoice
    factTimer: int
    worldStep: WorldStep
    worldTimer: int
    world: World
    situationStep: SituationStep
    situationTimer: int
    situation: Situation
    situations: seq[Situation]
    sceneState: SceneState
    sceneTimer: int
    sceneTurnOrder: seq[int]
    sceneTurnIndex: int
    fb: Framebuffer
    digitSprites: array[10, Sprite]
    letterSprites: seq[Sprite]
    rng: Rand
    prevInputs: seq[InputState]
    chatScroll: int
    chatConfirmed: seq[bool]
    chatInterrupted: seq[bool]

  WebSocketAppState = object
    lock: Lock
    inputMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    playerIndices: Table[WebSocket, int]
    playerNames: Table[WebSocket, string]
    chatMessages: Table[WebSocket, string]
    closedSockets: seq[WebSocket]
    globalViewers: Table[WebSocket, bool]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

var appState: WebSocketAppState

proc initAppState() =
  initLock(appState.lock)
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerNames = initTable[WebSocket, string]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.closedSockets = @[]
  appState.globalViewers = initTable[WebSocket, bool]()

proc inputStateFromMasks(currentMask, previousMask: uint8): InputState =
  result = decodeInputMask(currentMask)

proc addPlayer(sim: var SimServer, name: string, kind: PlayerKind = PlayerHuman): int =
  if sim.players.len >= MaxPlayers:
    return -1
  let idx = sim.players.len
  sim.players.add(Player(
    name: if name.len > 0: name else: "Player" & $(idx + 1),
    colorIndex: (idx mod 8) + 3,
    ready: false,
    kind: kind,
    soul: newSoul(),
    cursor: 0,
    magicTokens: 4
  ))
  idx

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  if websocket notin appState.playerIndices:
    return
  let removedIndex = appState.playerIndices[websocket]
  appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.playerNames.del(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.players.delete(removedIndex)
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex:
        dec value

proc chatLogStrings(sim: SimServer): seq[string] =
  for entry in sim.chatLog:
    result.add(entry.name & ": " & entry.text)

proc generateFactOptions(sim: var SimServer) =
  let player = sim.players[sim.currentTurn]
  let facts = player.soul.generateFacts(sim.world, sim.chatLogStrings())
  sim.factChoice.choice = initChoice(@[facts[0], facts[1], facts[2]], "skip")
  sim.factChoice.step = FactReading
  sim.factTimer = FactReadTicks

proc startFactTurn(sim: var SimServer) =
  sim.factChoice = FactChoice(step: FactGazing)
  sim.factTimer = 1

proc generateSceneOpts(sim: var SimServer) =
  let player = sim.players[sim.currentTurn]
  let opts = player.soul.generateSceneOptions(sim.world, sim.situation, sim.chatLogStrings())
  sim.sceneState.choice = initChoice(@[opts[0], opts[1], opts[2], opts[3]], "do nothing")
  sim.sceneState.step = SceneReading
  sim.sceneTimer = SceneReadTicks

proc startSceneChoices(sim: var SimServer) =
  sim.sceneTurnOrder = @[]
  for i in 0 ..< sim.players.len:
    sim.sceneTurnOrder.add(i)
  sim.rng.shuffle(sim.sceneTurnOrder)
  sim.sceneTurnIndex = 0
  sim.currentTurn = sim.sceneTurnOrder[0]
  sim.sceneState = SceneState(step: SceneGazing)
  sim.sceneTimer = 1

proc fillRect(fb: var Framebuffer, x, y, w, h: int, color: uint8) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      fb.putPixel(px, py, color)

proc renderLobby(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let title = "mortal coil"
  sim.fb.blitText(sim.letterSprites, title, 20, 10)

  let countText = $sim.players.len & " of " & $sim.minPlayers
  sim.fb.blitText(sim.letterSprites, sim.digitSprites, countText, 34, 30)

  for i, player in sim.players:
    let y = 44 + i * 8
    sim.fb.fillRect(10, y, 4, 4, uint8(player.colorIndex))
    let displayName = if player.name.len > 16: player.name[0..15] else: player.name
    sim.fb.blitText(sim.letterSprites, displayName, 18, y)

  if sim.players.len >= sim.minPlayers and sim.lobbyCountdown > 0:
    let seconds = (sim.lobbyCountdown + 23) div 24
    let startText = "start in " & $seconds
    sim.fb.blitText(sim.letterSprites, sim.digitSprites, startText, 28, 118)

proc charsFromX(x: int): int =
  (ScreenWidth - x) div CharWidth

proc blitTextWrapped(sim: var SimServer, text: string, x, y: int, lineHeight: int): int =
  let maxChars = charsFromX(x)
  var row = 0
  var pos = 0
  while pos < text.len:
    let remaining = text.len - pos
    let lineLen = min(remaining, maxChars)
    let line = text[pos ..< pos + lineLen]
    sim.fb.blitText(sim.letterSprites, sim.digitSprites, line, x, y + row * lineHeight)
    pos += lineLen
    inc row
    if y + row * lineHeight + CharHeight > ScreenHeight:
      break
  row

proc blitTextWrappedTinted(sim: var SimServer, text: string, x, y: int, lineHeight: int, tint: uint8): int =
  let maxChars = charsFromX(x)
  var row = 0
  var pos = 0
  while pos < text.len:
    let remaining = text.len - pos
    let lineLen = min(remaining, maxChars)
    let line = text[pos ..< pos + lineLen]
    sim.fb.blitTextTinted(sim.letterSprites, sim.digitSprites, line, x, y + row * lineHeight, tint)
    pos += lineLen
    inc row
    if y + row * lineHeight + CharHeight > ScreenHeight:
      break
  row

proc renderVoteBox(sim: var SimServer, x, y, w, h: int, vote: Vote, color: uint8) =
  sim.fb.fillRect(x, y, w, 1, color)
  sim.fb.fillRect(x, y + h - 1, w, 1, color)
  sim.fb.fillRect(x, y, 1, h, color)
  sim.fb.fillRect(x + w - 1, y, 1, h, color)
  case vote
  of VotePending:
    let passX = x + (w - 4 * CharWidth) div 2
    sim.fb.blitText(sim.letterSprites, "pass", passX, y + 2)
    let vetoX = x + (w - 4 * CharWidth) div 2
    sim.fb.blitText(sim.letterSprites, "veto", vetoX, y + 9)
  of VotePass:
    let passX = x + (w - 4 * CharWidth) div 2
    sim.fb.blitTextTinted(sim.letterSprites, "pass", passX, y + 5, color)
  of VoteVeto:
    let vetoX = x + (w - 4 * CharWidth) div 2
    sim.fb.blitTextTinted(sim.letterSprites, "veto", vetoX, y + 5, color)

proc renderVotePanel(sim: var SimServer) =
  let voterCount = sim.players.len - 1
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
    for i in 0 ..< sim.players.len:
      if i == sim.currentTurn:
        continue
      let x = TextMargin + col * (colW + gap)
      let y = startY + row * (boxH + 2)
      if y + boxH > ScreenHeight:
        break
      let color = uint8(sim.players[i].colorIndex)
      sim.renderVoteBox(x, y, colW, boxH, sim.factChoice.votes[i], color)
      col += 1
      if col >= 2:
        col = 0
        row += 1
  else:
    let boxW = ScreenWidth - TextMargin * 2
    let totalH = voterCount * (boxH + 2)
    var voteY = ScreenHeight - totalH
    for i in 0 ..< sim.players.len:
      if i == sim.currentTurn:
        continue
      if voteY + boxH > ScreenHeight:
        break
      let color = uint8(sim.players[i].colorIndex)
      sim.renderVoteBox(TextMargin, voteY, boxW, boxH, sim.factChoice.votes[i], color)
      voteY += boxH + 2

proc renderFactChoices(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let player = sim.players[sim.currentTurn]
  let color = uint8(player.colorIndex)
  let voting = sim.factChoice.step in {FactVoting, FactVoteResult}
  let suffix = if voting: " proposal" else: " choose"
  let nameX = TextMargin
  sim.fb.blitTextTinted(sim.letterSprites, sim.digitSprites, player.name, nameX, 4, color)
  let suffixX = nameX + player.name.len * CharWidth
  sim.fb.blitText(sim.letterSprites, sim.digitSprites, suffix, suffixX, 4)

  let showCursor = player.kind == PlayerHuman and sim.factChoice.step == FactReading
  let y = renderChoices(sim.fb, sim.letterSprites, sim.digitSprites,
    sim.factChoice.choice, color, showCursor, voting)

  if voting:
    sim.renderVotePanel()
  else:
    let tokenText = "magic " & $player.magicTokens
    let tokenX = (ScreenWidth - tokenText.len * CharWidth) div 2
    let tokenY = y + (ScreenHeight - y - CharHeight) div 2
    sim.fb.blitTextTinted(sim.letterSprites, sim.digitSprites, tokenText, tokenX, tokenY, color)

proc entryLineCount(entry: ChatEntry): int =
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

proc renderFactChat(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  sim.fb.blitText(sim.letterSprites, "magical facts", TextMargin, 4)

  if sim.chatScroll >= sim.chatLog.len:
    sim.chatScroll = max(0, sim.chatLog.len - 1)

  let startY = 14
  let availableLines = (ScreenHeight - startY) div 8
  let endIdx = min(sim.chatScroll + 1, sim.chatLog.len)

  var startIdx = endIdx
  var totalLines = 0
  while startIdx > 0:
    let lines = entryLineCount(sim.chatLog[startIdx - 1])
    if totalLines + lines > availableLines:
      break
    totalLines += lines
    dec startIdx

  var y = startY
  for i in startIdx ..< endIdx:
    if y + CharHeight > ScreenHeight:
      break
    let entry = sim.chatLog[i]
    let maxNameChars = min(entry.name.len, charsFromX(TextMargin) - 1)
    let displayName = entry.name[0 ..< maxNameChars]
    sim.fb.blitTextTinted(sim.letterSprites, sim.digitSprites, displayName, TextMargin, y, entry.colorIndex)
    let textX = TextMargin + (maxNameChars + 1) * CharWidth
    let maxTextChars = charsFromX(textX)
    if maxTextChars > 0 and entry.text.len > 0:
      let firstLine = if entry.text.len > maxTextChars: entry.text[0 ..< maxTextChars] else: entry.text
      sim.fb.blitText(sim.letterSprites, sim.digitSprites, firstLine, textX, y)
      y += 8
      var pos = maxTextChars
      let wrapChars = charsFromX(TextMargin)
      while pos < entry.text.len:
        if y + CharHeight > ScreenHeight:
          break
        let lineLen = min(entry.text.len - pos, wrapChars)
        let line = entry.text[pos ..< pos + lineLen]
        sim.fb.blitText(sim.letterSprites, sim.digitSprites, line, TextMargin, y)
        pos += lineLen
        y += 8
    else:
      y += 8

proc renderGazing(sim: var SimServer) =
  sim.fb.clearFrame(0)
  let line1 = "gazing into"
  let line2 = "the void"
  let x1 = (ScreenWidth - line1.len * CharWidth) div 2
  let x2 = (ScreenWidth - line2.len * CharWidth) div 2
  let y1 = (ScreenHeight - CharHeight * 2 - 2) div 2
  let y2 = y1 + CharHeight + 2
  sim.fb.blitTextTinted(sim.letterSprites, line1, x1, y1, 9)
  sim.fb.blitTextTinted(sim.letterSprites, line2, x2, y2, 9)

proc renderWorld(sim: var SimServer) =
  sim.fb.clearFrame(0)
  case sim.worldStep
  of WorldGazing:
    let line1 = "the world"
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight) div 2
    sim.fb.blitTextTinted(sim.letterSprites, line1, x1, y1, 2)
  of WorldTitle:
    let line1 = "the world"
    let line2 = sim.world.title
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let x2 = (ScreenWidth - line2.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight * 2 - 2) div 2
    let y2 = y1 + CharHeight + 2
    sim.fb.blitTextTinted(sim.letterSprites, line1, x1, y1, 2)
    sim.fb.blitTextTinted(sim.letterSprites, sim.digitSprites, line2, x2, y2, 2)
  of WorldDescription:
    let maxChars = charsFromX(TextMargin)
    let lineCount = max(1, (sim.world.description.len + maxChars - 1) div maxChars)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard sim.blitTextWrappedTinted(sim.world.description, TextMargin, startY, 8, 2)

proc renderSceneChoices(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let player = sim.players[sim.currentTurn]
  let color = uint8(player.colorIndex)
  let nameX = TextMargin
  sim.fb.blitTextTinted(sim.letterSprites, sim.digitSprites, player.name, nameX, 4, color)
  let suffixX = nameX + player.name.len * CharWidth
  sim.fb.blitText(sim.letterSprites, sim.digitSprites, " act", suffixX, 4)

  let showCursor = player.kind == PlayerHuman and sim.sceneState.step == SceneReading
  discard renderChoices(sim.fb, sim.letterSprites, sim.digitSprites,
    sim.sceneState.choice, color, showCursor)

proc renderSituation(sim: var SimServer) =
  sim.fb.clearFrame(0)
  case sim.situationStep
  of SituationGazing:
    let line1 = "situation"
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight) div 2
    sim.fb.blitTextTinted(sim.letterSprites, line1, x1, y1, 5)
  of SituationTitle:
    let line1 = "situation"
    let line2 = sim.situation.title
    let x1 = (ScreenWidth - line1.len * CharWidth) div 2
    let x2 = (ScreenWidth - line2.len * CharWidth) div 2
    let y1 = (ScreenHeight - CharHeight * 2 - 2) div 2
    let y2 = y1 + CharHeight + 2
    sim.fb.blitTextTinted(sim.letterSprites, line1, x1, y1, 5)
    sim.fb.blitTextTinted(sim.letterSprites, sim.digitSprites, line2, x2, y2, 5)
  of SituationDescription:
    let maxChars = charsFromX(TextMargin)
    let lineCount = max(1, (sim.situation.description.len + maxChars - 1) div maxChars)
    let totalH = lineCount * 8
    let startY = max(TextMargin, (ScreenHeight - totalH) div 2)
    discard sim.blitTextWrappedTinted(sim.situation.description, TextMargin, startY, 8, 5)
  of SituationChoices:
    sim.renderSceneChoices()

proc renderFact(sim: var SimServer) =
  case sim.factChoice.step
  of FactGazing:
    sim.renderGazing()
  of FactReading, FactSelected, FactVoting, FactVoteResult:
    sim.renderFactChoices()
  of FactShowChat:
    sim.renderFactChat()

proc renderGame(sim: var SimServer) =
  sim.fb.clearFrame(BackgroundColor)
  let phaseText = case sim.phase
    of PhaseLobby: "lobby"
    of PhaseWorld: "the world"
    of PhaseMagicalFacts: "magical facts"
    of PhaseSituation: "situation"
    of PhaseConflict: "conflict"
    of PhasePower: "power"
    of PhaseEnd: "end"
  sim.fb.blitText(sim.letterSprites, phaseText, 4, 4)

proc render(sim: var SimServer) =
  case sim.phase
  of PhaseLobby:
    sim.renderLobby()
  of PhaseWorld:
    sim.renderWorld()
  of PhaseMagicalFacts:
    sim.renderFact()
  of PhaseSituation:
    sim.renderSituation()
  else:
    sim.renderGame()

proc released(current, prev: InputState): InputState =
  result.up = not current.up and prev.up
  result.down = not current.down and prev.down
  result.left = not current.left and prev.left
  result.right = not current.right and prev.right
  result.attack = not current.attack and prev.attack
  result.b = not current.b and prev.b
  result.select = not current.select and prev.select

proc step(sim: var SimServer, inputs: seq[InputState]) =
  inc sim.tick
  case sim.phase
  of PhaseLobby:
    if sim.players.len >= sim.minPlayers:
      if sim.lobbyCountdown <= 0:
        sim.lobbyCountdown = LobbyCountdownTicks
      else:
        dec sim.lobbyCountdown
        if sim.lobbyCountdown <= 0:
          sim.phase = PhaseWorld
          sim.worldStep = WorldGazing
          sim.worldTimer = 1
    else:
      sim.lobbyCountdown = 0
  of PhaseWorld:
    dec sim.worldTimer
    if sim.worldStep == WorldGazing and sim.worldTimer <= 0:
      sim.world = sim.players[0].soul.generateWorld()
      sim.worldStep = WorldTitle
      sim.worldTimer = WorldTitleTicks
    elif sim.worldStep == WorldTitle and sim.worldTimer <= 0:
      sim.worldStep = WorldDescription
      sim.worldTimer = WorldDescTicks
      echo "  World: ", sim.world.description
    elif sim.worldStep == WorldDescription and sim.worldTimer <= 0:
      sim.phase = PhaseMagicalFacts
      sim.currentTurn = 0
      sim.chatLog = @[]
      sim.startFactTurn()
  of PhaseMagicalFacts:
    if sim.players.len == 0:
      sim.phase = PhaseLobby
      return
    dec sim.factTimer
    let turnPlayer = sim.players[sim.currentTurn]
    let turnIsHuman = turnPlayer.kind == PlayerHuman
    let turnPrev = if sim.currentTurn < sim.prevInputs.len: sim.prevInputs[sim.currentTurn]
                   else: InputState()
    let turnCur = if sim.currentTurn < inputs.len: inputs[sim.currentTurn]
                  else: InputState()
    let turnInput = released(turnCur, turnPrev)

    if sim.factChoice.step == FactGazing and sim.factTimer <= 0:
      sim.generateFactOptions()

    elif sim.factChoice.step == FactVoting:
      var allVoted = true
      for i in 0 ..< sim.factChoice.votes.len:
        if sim.factChoice.votes[i] == VotePending:
          if sim.players[i].kind == PlayerHuman:
            let voterPrev = if i < sim.prevInputs.len: sim.prevInputs[i] else: InputState()
            let voterCur = if i < inputs.len: inputs[i] else: InputState()
            let voterRel = released(voterCur, voterPrev)
            if voterRel.attack:
              sim.factChoice.votes[i] = VotePass
            elif voterRel.b:
              sim.factChoice.votes[i] = VoteVeto
            else:
              allVoted = false
          else:
            dec sim.factChoice.voteTimers[i]
            if sim.factChoice.voteTimers[i] <= 0:
              if sim.rng.rand(3) <= 1:
                sim.factChoice.votes[i] = VotePass
              else:
                sim.factChoice.votes[i] = VoteVeto
            else:
              allVoted = false
      if allVoted:
        sim.factChoice.step = FactVoteResult
        sim.factChoice.voteResultTimer = FactAcceptTicks

    elif sim.factChoice.step == FactVoteResult:
      dec sim.factChoice.voteResultTimer
      if sim.factChoice.voteResultTimer <= 0:
        var vetoCount = 0
        for v in sim.factChoice.votes:
          if v == VoteVeto:
            inc vetoCount
        let player = sim.players[sim.currentTurn]
        let factText = sim.factChoice.choice.options[sim.factChoice.choice.selected]
        if vetoCount * 2 >= sim.factChoice.votes.len:
          sim.chatLog.add(ChatEntry(
            name: player.name,
            colorIndex: uint8(player.colorIndex),
            text: "vetoed"
          ))
        else:
          sim.players[sim.currentTurn].magicTokens -= 1
          sim.chatLog.add(ChatEntry(
            name: player.name,
            colorIndex: uint8(player.colorIndex),
            text: factText
          ))
        sim.factChoice.step = FactShowChat
        sim.chatScroll = sim.chatLog.len - 1
        sim.chatConfirmed = newSeq[bool](sim.players.len)
        sim.chatInterrupted = newSeq[bool](sim.players.len)
        sim.factTimer = FactAcceptTicks * 4

    elif sim.factChoice.step == FactReading:
      if turnIsHuman:
        sim.factChoice.choice.handleChoiceInput(turnInput)
        sim.players[sim.currentTurn].cursor = sim.factChoice.choice.cursor
        if sim.factChoice.choice.state == ChoiceSelected:
          sim.factChoice.step = FactSelected
          sim.factTimer = FactAcceptTicks
      elif sim.factTimer <= 0:
        let pick = sim.rng.rand(3)
        sim.factChoice.choice.selected = pick
        sim.factChoice.choice.state = ChoiceSelected
        sim.factChoice.step = FactSelected
        sim.factTimer = FactAcceptTicks

    elif sim.factChoice.step == FactSelected:
      if sim.factTimer > 0:
        discard
      elif sim.factChoice.choice.selected >= 0 and sim.factChoice.choice.selected < 3:
        sim.factChoice.step = FactVoting
        sim.factChoice.votes = @[]
        sim.factChoice.voteTimers = @[]
        for i in 0 ..< sim.players.len:
          if i == sim.currentTurn:
            sim.factChoice.votes.add(VotePass)
            sim.factChoice.voteTimers.add(0)
          else:
            sim.factChoice.votes.add(VotePending)
            sim.factChoice.voteTimers.add(24 * (sim.rng.rand(3) + 1))
      else:
        let player = sim.players[sim.currentTurn]
        sim.chatLog.add(ChatEntry(
          name: player.name,
          colorIndex: uint8(player.colorIndex),
          text: "skip"
        ))
        sim.factChoice.step = FactShowChat
        sim.chatScroll = sim.chatLog.len - 1
        sim.chatConfirmed = newSeq[bool](sim.players.len)
        sim.chatInterrupted = newSeq[bool](sim.players.len)
        sim.factTimer = FactAcceptTicks * 4

    elif sim.factChoice.step == FactShowChat:
      for i in 0 ..< sim.players.len:
        if sim.players[i].kind == PlayerBot:
          if sim.factTimer <= 0:
            sim.chatConfirmed[i] = true
        else:
          let cur = if i < inputs.len: inputs[i] else: InputState()
          let prev = if i < sim.prevInputs.len: sim.prevInputs[i] else: InputState()
          let rel = released(cur, prev)
          if rel.down:
            sim.chatScroll = min(sim.chatScroll + 1, max(0, sim.chatLog.len - 1))
            sim.chatInterrupted[i] = true
          elif rel.up:
            sim.chatScroll = max(sim.chatScroll - 1, 0)
            sim.chatInterrupted[i] = true
          elif rel.attack and sim.chatInterrupted[i]:
            sim.chatConfirmed[i] = true
          if sim.factTimer <= 0 and not sim.chatInterrupted[i]:
            sim.chatConfirmed[i] = true
      var allConfirmed = true
      for i in 0 ..< sim.players.len:
        if not sim.chatConfirmed[i]:
          allConfirmed = false
          break
      if allConfirmed:
        var allSpent = true
        for p in sim.players:
          if p.magicTokens > 0:
            allSpent = false
            break
        sim.currentTurn += 1
        if sim.currentTurn >= sim.players.len:
          sim.currentTurn = 0
          sim.phase = PhaseSituation
          sim.situationStep = SituationGazing
          sim.situationTimer = 1
          return
        sim.startFactTurn()
  of PhaseSituation:
    dec sim.situationTimer
    if sim.situationStep == SituationGazing and sim.situationTimer <= 0:
      sim.situation = sim.players[0].soul.generateSituation(
        sim.world, sim.chatLogStrings(), sim.situations)
      sim.situationStep = SituationTitle
      sim.situationTimer = SituationTitleTicks
    elif sim.situationStep == SituationTitle and sim.situationTimer <= 0:
      sim.situationStep = SituationDescription
      sim.situationTimer = SituationDescTicks
      echo "  Situation: ", sim.situation.description
    elif sim.situationStep == SituationDescription and sim.situationTimer <= 0:
      sim.situationStep = SituationChoices
      sim.startSceneChoices()

    elif sim.situationStep == SituationChoices:
      let turnPlayer = sim.players[sim.currentTurn]
      let turnIsHuman = turnPlayer.kind == PlayerHuman
      let turnPrev = if sim.currentTurn < sim.prevInputs.len: sim.prevInputs[sim.currentTurn]
                     else: InputState()
      let turnCur = if sim.currentTurn < inputs.len: inputs[sim.currentTurn]
                    else: InputState()
      let turnInput = released(turnCur, turnPrev)

      if sim.sceneState.step == SceneGazing and sim.sceneTimer <= 0:
        sim.generateSceneOpts()

      elif sim.sceneState.step == SceneReading:
        if turnIsHuman:
          sim.sceneState.choice.handleChoiceInput(turnInput)
          sim.players[sim.currentTurn].cursor = sim.sceneState.choice.cursor
          if sim.sceneState.choice.state == ChoiceSelected:
            sim.sceneTimer = SceneAcceptTicks
        elif sim.sceneTimer <= 0:
          let pick = sim.rng.rand(sim.sceneState.choice.optionCount() - 1)
          sim.sceneState.choice.selected = pick
          sim.sceneState.choice.state = ChoiceSelected
          sim.sceneTimer = SceneAcceptTicks

      elif sim.sceneState.choice.state == ChoiceSelected and sim.sceneTimer <= 0:
        let player = sim.players[sim.currentTurn]
        let sel = sim.sceneState.choice.selected
        let actionText = if sel < sim.sceneState.choice.options.len:
            sim.sceneState.choice.options[sel]
          else:
            "do nothing"
        sim.chatLog.add(ChatEntry(
          name: player.name,
          colorIndex: uint8(player.colorIndex),
          text: actionText
        ))
        sim.sceneTurnIndex += 1
        if sim.sceneTurnIndex >= sim.sceneTurnOrder.len:
          sim.situations.add(sim.situation)
          var allSpent = true
          for p in sim.players:
            if p.magicTokens > 0:
              allSpent = false
              break
          if allSpent:
            sim.phase = PhaseEnd
          else:
            sim.phase = PhaseMagicalFacts
            sim.currentTurn = 0
            sim.startFactTurn()
        else:
          sim.currentTurn = sim.sceneTurnOrder[sim.sceneTurnIndex]
          sim.sceneState = SceneState(step: SceneGazing)
          sim.sceneTimer = 1
  else:
    discard
  sim.prevInputs = inputs

proc buildFramePacket(sim: var SimServer, playerIndex: int): seq[uint8] =
  sim.render()
  sim.fb.packFramebuffer()
  result = newSeq[uint8](ProtocolBytes)
  for i in 0 ..< ProtocolBytes:
    result[i] = sim.fb.packed[i]

proc buildGlobalPacket(sim: var SimServer): seq[uint8] =
  sim.render()
  sim.fb.packFramebuffer()
  result = newSeq[uint8](ProtocolBytes)
  for i in 0 ..< ProtocolBytes:
    result[i] = sim.fb.packed[i]

proc initSim(seed: int, minPlayers: int): SimServer =
  result.phase = PhaseLobby
  result.tick = 0
  result.lobbyCountdown = 0
  result.minPlayers = minPlayers
  result.currentTurn = 0
  result.chatLog = @[]
  result.rng = initRand(seed)
  result.fb = initFramebuffer()

  let dataDir = clientsDir() / "data"
  result.digitSprites = loadDigitSprites(dataDir / "numbers.png")
  result.letterSprites = loadLetterSprites(dataDir / "letters.png")
  loadPalette(dataDir / "pallete.png")

proc playerIdentity(request: Request): string =
  let uri = request.uri
  let qPos = uri.find('?')
  if qPos < 0:
    return "player"
  let query = uri[qPos + 1 .. ^1]
  for param in query.split('&'):
    let kv = param.split('=', 1)
    if kv.len == 2 and kv[0] == "name":
      return kv[1]
  "player"

proc serveClientHtml(request: Request, route: string): bool =
  if request.httpMethod != "GET":
    return false
  let filePath = clientStaticPath(route)
  if filePath.len == 0:
    return false
  var headers: HttpHeaders
  headers["Content-Type"] = clientStaticContentType(route)
  headers["Cache-Control"] = "no-cache"
  if not fileExists(filePath):
    request.respond(404, headers, "Not found: " & route)
    return true
  try:
    request.respond(200, headers, readFile(filePath))
  except IOError as e:
    request.respond(500, headers, "Error: " & e.msg)
  true

proc serveGlobalViewer(request: Request): bool =
  if request.httpMethod != "GET":
    return false
  let route = request.path
  if route != GlobalClientRoute and route != GlobalClientHtmlRoute and
     route != CoworldGlobalClientRoute:
    return false
  let filePath = clientStaticPath(PlayerClientRoute)
  if filePath.len == 0 or not fileExists(filePath):
    return false
  var html = readFile(filePath)
  html = html.replace("/player", "/global")
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  request.respond(200, headers, html)
  true

proc serveStaticClientHtml(request: Request): bool =
  ## Serves one static client asset if the route matches.
  if request.serveGlobalViewer():
    return true
  request.serveClientHtml(request.path)

proc httpHandler(request: Request) =
  if request.path == WebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerNames[websocket] = request.playerIdentity()
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.headers["Sec-WebSocket-Key"].len > 0:
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = true
  elif request.serveStaticClientHtml():
    discard
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "Mortal Coil server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    {.gcsafe.}:
      withLock appState.lock:
        if websocket notin appState.globalViewers:
          appState.playerIndices[websocket] = 0x7fffffff
          appState.inputMasks[websocket] = 0
          appState.lastAppliedMasks[websocket] = 0
  of MessageEvent:
    if message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if isInputPacket(message.data):
            appState.inputMasks[websocket] = blobToMask(message.data)
          elif isChatPacket(message.data):
            appState.chatMessages[websocket] = blobToChat(message.data)
  of ErrorEvent:
    discard
  of CloseEvent:
    {.gcsafe.}:
      withLock appState.lock:
        appState.closedSockets.add(websocket)

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc runFrameLimiter(previousTick: var MonoTime) =
  let frameDuration = initDuration(milliseconds = int(1000.0 / TargetFps))
  let elapsed = getMonoTime() - previousTick
  if elapsed < frameDuration:
    sleep(int((frameDuration - elapsed).inMilliseconds))
  previousTick = getMonoTime()

var
  clientProcesses: seq[Process]
  guiCleanupStarted = false

proc primaryScreen(): Screen =
  let screens = getScreens()
  if screens.len > 0:
    for screen in screens:
      if screen.primary:
        return screen
    return screens[0]
  Screen(left: 0, right: 1920, top: 0, bottom: 1080, primary: true)

proc clientLaunches(players: int): seq[tuple[title: string, x, y: int]] =
  let screen = primaryScreen()
  let rowCounts =
    case players
    of 1: @[1]
    of 2: @[2]
    of 3: @[3]
    of 4: @[2, 2]
    of 5: @[3, 2]
    of 6: @[3, 3]
    of 7: @[4, 3]
    of 8: @[4, 4]
    else: @[4, 4]

  let
    totalHeight =
      rowCounts.len * ClientScreenOnlyHeight +
      max(0, rowCounts.len - 1) * ClientWindowMargin
    startY = screen.top + (screen.bottom - screen.top - totalHeight) div 2

  for rowIndex, rowCount in rowCounts:
    let
      rowWidth =
        rowCount * ClientScreenOnlyWidth +
        max(0, rowCount - 1) * ClientWindowMargin
      startX = screen.left + (screen.right - screen.left - rowWidth) div 2
      y = startY + rowIndex * (ClientScreenOnlyHeight + ClientWindowMargin)

    for col in 0 ..< rowCount:
      let playerNumber = result.len + 1
      result.add((
        title: "Mortal Coil Player " & $playerNumber,
        x: startX + col * (ClientScreenOnlyWidth + ClientWindowMargin),
        y: y
      ))

proc stopClientProcesses() =
  if guiCleanupStarted:
    return
  guiCleanupStarted = true
  for i in countdown(clientProcesses.high, 0):
    if clientProcesses[i].isNil:
      continue
    try:
      if clientProcesses[i].peekExitCode() == -1:
        clientProcesses[i].terminate()
        for _ in 0 ..< 20:
          if clientProcesses[i].peekExitCode() != -1:
            break
          sleep(100)
        if clientProcesses[i].peekExitCode() == -1:
          clientProcesses[i].kill()
    except CatchableError:
      discard
    try:
      clientProcesses[i].close()
    except CatchableError:
      discard
  clientProcesses.setLen(0)

proc guiCleanupAtExit() {.noconv.} =
  stopClientProcesses()

proc guiControlCHook() {.noconv.} =
  stopClientProcesses()
  quit(130)

proc exePathFor(sourceRelative: string): string =
  let exeName = sourceRelative.splitFile().name.addFileExt(ExeExts[0])
  repoDir() / "out" / exeName

proc launchGuiClients(address: string, port: int, players: int) =
  let
    clientExe = exePathFor(PlayerClientSourceRelative)
    clientWorkDir = repoDir() / "clients"
    connectAddress =
      if address == "0.0.0.0" or address == "::": "127.0.0.1"
      else: address
    launches = clientLaunches(players)

  if not fileExists(clientExe):
    echo "GUI: player_client not compiled. Run: nim c ", PlayerClientSourceRelative
    return

  addExitProc(guiCleanupAtExit)
  setControlCHook(guiControlCHook)

  for i, launch in launches:
    let wsUrl = "ws://" & connectAddress & ":" & $port &
      "/player?name=player" & $(i + 1)
    let args = @[
      "--address:" & wsUrl,
      "--screen-only",
      "--title:" & launch.title,
      "--joystick:" & $(i + 1),
      "--x:" & $launch.x,
      "--y:" & $launch.y,
      "--reconnect:1"
    ]
    try:
      clientProcesses.add(startProcess(
        clientExe,
        workingDir = clientWorkDir,
        args = args,
        options = {poParentStreams}
      ))
      echo "  GUI: launched ", launch.title
    except CatchableError as e:
      echo "  GUI: failed to start player ", i + 1, ": ", e.msg

proc runServerLoop(host = DefaultHost, port = DefaultPort, seed = 0,
                   gui = false, players = DefaultMinPlayers, bots = 0) =
  initAppState()

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4,
    tcpNoDelay = true
  )

  var serverThread: Thread[ServerThreadArgs]
  var serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()

  echo "Mortal Coil running on ", host, ":", port
  echo "  Player: http://", host, ":", port, PlayerClientRoute
  echo "  Global: http://", host, ":", port, GlobalClientRoute

  if gui:
    launchGuiClients(host, port, players)

  var
    sim = initSim(seed, players)
    lastTick = getMonoTime()

  for i in 0 ..< bots:
    let botName = "bot" & $(i + 1)
    discard sim.addPlayer(botName, PlayerBot)

  while true:
    var
      sockets: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      globalViewers: seq[WebSocket] = @[]

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          sim.removePlayer(websocket)
          appState.globalViewers.del(websocket)
        appState.closedSockets.setLen(0)

        for websocket in appState.playerIndices.keys:
          if appState.playerIndices[websocket] == 0x7fffffff:
            let name = appState.playerNames.getOrDefault(websocket, "")
            let idx = sim.addPlayer(name)
            if idx >= 0:
              appState.playerIndices[websocket] = idx
              echo "Player joined: ", sim.players[idx].name

        inputs = newSeq[InputState](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if playerIndex < 0 or playerIndex >= inputs.len:
            continue
          let
            currentMask = appState.inputMasks.getOrDefault(websocket, 0)
            previousMask = appState.lastAppliedMasks.getOrDefault(websocket, 0)
          inputs[playerIndex] = inputStateFromMasks(currentMask, previousMask)
          appState.lastAppliedMasks[websocket] = currentMask
          sockets.add(websocket)
          playerIndices.add(playerIndex)

        for websocket, msg in appState.chatMessages.pairs:
          let playerIndex = appState.playerIndices.getOrDefault(websocket, -1)
          if playerIndex >= 0 and playerIndex < sim.players.len:
            if msg.startsWith("/passions "):
              let passionStr = msg["/passions ".len .. ^1]
              sim.players[playerIndex].soul.passions = passionStr.split(",")
              for i in 0 ..< sim.players[playerIndex].soul.passions.len:
                sim.players[playerIndex].soul.passions[i] =
                  sim.players[playerIndex].soul.passions[i].strip()
        appState.chatMessages.clear()

        for websocket in appState.globalViewers.keys:
          globalViewers.add(websocket)

    sim.step(inputs)

    for i in 0 ..< sockets.len:
      let frameBlob = blobFromBytes(sim.buildFramePacket(playerIndices[i]))
      try:
        sockets[i].send(frameBlob, BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            sim.removePlayer(sockets[i])

    if globalViewers.len > 0:
      let globalBlob = blobFromBytes(sim.buildGlobalPacket())
      for viewer in globalViewers:
        try:
          viewer.send(globalBlob, BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              appState.globalViewers.del(viewer)

    runFrameLimiter(lastTick)

when isMainModule:
  var
    address = DefaultHost
    port = DefaultPort
    seed = 0
    gui = false
    players = DefaultMinPlayers
    bots = 0
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = val
      of "port": port = parseInt(val)
      of "seed": seed = parseInt(val)
      of "gui": gui = true
      of "players": players = parseInt(val)
      of "bots": bots = parseInt(val)
      else: discard
    else: discard
  runServerLoop(address, port, seed, gui, players, bots)
