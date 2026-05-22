import std/[monotimes, options, os, parseopt, random, strutils, times]
import whisky, supersnappy
import protocol

import ../../claude

const
  SpritePlayerInputMsg = 0x84'u8
  MsgDefineSprite = 0x01'u8
  MsgDefineObject = 0x02'u8
  MsgDeleteObject = 0x03'u8
  MsgClearObjects = 0x04'u8
  MsgSetViewport = 0x05'u8
  MsgDefineLayer = 0x06'u8

type
  CoilBot = object
    name: string
    personality: string
    rng: Rand
    label: string
    record: seq[string]
    actedOnLabel: string
    frameTick: int

proc sendMask(ws: WebSocket, mask: uint8) =
  var buf = newString(2)
  buf[0] = char(SpritePlayerInputMsg)
  buf[1] = char(mask)
  ws.send(buf, BinaryMessage)

proc readU16(data: string, offset: int): int =
  int(uint16(data[offset].uint8) or (uint16(data[offset + 1].uint8) shl 8))

proc readI16(data: string, offset: int): int =
  let v = uint16(data[offset].uint8) or (uint16(data[offset + 1].uint8) shl 8)
  int(cast[int16](v))

proc readU32(data: string, offset: int): int =
  int(uint32(data[offset].uint8) or
    (uint32(data[offset + 1].uint8) shl 8) or
    (uint32(data[offset + 2].uint8) shl 16) or
    (uint32(data[offset + 3].uint8) shl 24))

proc parseLabels(data: string): string =
  ## Parse a sprite-v1 message stream and concatenate all sprite labels.
  var pos = 0
  var labels: seq[string]
  while pos < data.len:
    let msgType = data[pos].uint8
    inc pos
    case msgType
    of MsgDefineSprite:
      if pos + 6 > data.len: break
      pos += 2  # sprite id
      pos += 2  # width
      pos += 2  # height
      if pos + 4 > data.len: break
      let compLen = readU32(data, pos); pos += 4
      pos += compLen  # skip compressed pixels
      if pos + 2 > data.len: break
      let labelLen = readU16(data, pos); pos += 2
      if pos + labelLen > data.len: break
      if labelLen > 0:
        labels.add(data[pos ..< pos + labelLen])
      pos += labelLen
    of MsgDefineObject:
      pos += 11
    of MsgDeleteObject:
      pos += 2
    of MsgClearObjects:
      discard
    of MsgSetViewport:
      pos += 5
    of MsgDefineLayer:
      pos += 3
    else:
      break
  labels.join("\n")

proc getField(label, key: string): string =
  for line in label.splitLines():
    if line.startsWith(key & ":"):
      return line[key.len + 1 .. ^1]
  ""

proc getOptions(label: string): seq[string] =
  for i in 1 .. 5:
    let val = label.getField("option" & $i)
    if val.len > 0:
      result.add(val)

proc askClaude(bot: var CoilBot, options: seq[string], header: string): int =
  let choiceTexts = block:
    var lines: seq[string]
    for i, c in options:
      lines.add($(i + 1) & ". " & c)
    lines.join("\n")

  let prompt = "You are " & bot.name & ", a player in a social negotiation game called Mortal Coil. " &
    "Your personality: " & bot.personality & "\n\n" &
    (if header.len > 0: "Context: " & header & "\n\n" else: "") &
    "Choose one option by responding with ONLY the number (1-" & $options.len & "):\n" &
    choiceTexts

  echo "coilbot: asking Claude..."
  try:
    let response = ask(prompt)
    let cleaned = response.strip()
    echo "coilbot: Claude says: \"", cleaned, "\""
    for ch in cleaned:
      if ch in {'1'..'9'}:
        let idx = ord(ch) - ord('1')
        if idx >= 0 and idx < options.len:
          return idx
    echo "coilbot: unclear, picking random"
    bot.rng.rand(options.len - 1)
  except CatchableError as e:
    echo "coilbot: Claude error: ", e.msg
    bot.rng.rand(options.len - 1)

proc submitChoice(bot: var CoilBot, ws: WebSocket, pick: int) =
  for i in 0 ..< pick:
    echo "coilbot: DOWN (", pick - i, " left)"
    ws.sendMask(encodeInputMask(InputState(down: true)))
    sleep(100)
    ws.sendMask(0)
    sleep(100)
  echo "coilbot: A (select)"
  ws.sendMask(encodeInputMask(InputState(attack: true)))
  sleep(100)
  ws.sendMask(0)
  echo "coilbot: submitted"
  bot.actedOnLabel = bot.label

proc tick(bot: var CoilBot, ws: WebSocket) =
  if bot.label == bot.actedOnLabel:
    return
  let step = bot.label.getField("step")
  let turn = bot.label.getField("turn")
  let selected = bot.label.getField("selected")

  if (step == "ConflictChoices" or step == "SituationChoices") and
      turn.toLowerAscii == bot.name.toLowerAscii and selected == "-1":
    let options = bot.label.getOptions()
    if options.len > 0:
      let header = bot.label.getField("header")
      echo "coilbot: === MY TURN ==="
      if header.len > 0:
        echo "coilbot: header: ", header
      for i, o in options:
        echo "coilbot:   ", i + 1, ". ", o
      let pick = bot.askClaude(options, header)
      echo "coilbot: => chose #", pick + 1, ": ", options[pick]
      bot.submitChoice(ws, pick)

proc runBot(host: string, port: int, name, personality: string, seed: int64) =
  var bot = CoilBot(
    name: name,
    personality: personality,
    rng: initRand(seed),
  )
  echo "coilbot: ", name, " connecting to ", host, ":", port
  echo "coilbot: personality = ", personality

  let queryName = block:
    var escaped = ""
    for ch in name:
      if ch in {'a'..'z'} or ch in {'A'..'Z'} or ch in {'0'..'9'} or
          ch in {'-', '_', '.', '~'}:
        escaped.add(ch)
      else:
        escaped.add('%')
        escaped.add("0123456789ABCDEF"[(ord(ch) shr 4) and 0x0f])
        escaped.add("0123456789ABCDEF"[ord(ch) and 0x0f])
    escaped

  let url =
    if host.startsWith("ws://") or host.startsWith("wss://"):
      host
    else:
      "ws://" & host & ":" & $port & "/sprite_player?name=" & queryName

  while true:
    try:
      let ws = newWebSocket(url)
      echo "coilbot: connected to /sprite_player"

      while true:
        let message = ws.receiveMessage()
        if message.isNone:
          continue
        let msg = message.get
        if msg.kind == Ping:
          ws.send(msg.data, Pong)
          continue
        if msg.kind != BinaryMessage:
          continue

        inc bot.frameTick
        let label = parseLabels(msg.data)
        if label.len > 0 and label != bot.label:
          bot.label = label
          bot.record.add(label)
          echo "---"
          echo label

        bot.tick(ws)

    except CatchableError as e:
      echo "coilbot: disconnected: ", e.msg
      sleep(1000)
      echo "coilbot: reconnecting..."

when isMainModule:
  var
    host = getEnv("COWORLD_PLAYER_WS_URL")
    port = DefaultPort
    name = if host.len > 0: "" else: "Coilbot"
    #personality = "Strategic and adaptable. Prefer cooperation when risk is high, but willing to exploit when the reward justifies it."
    personality = "Strategic and adaptable. Makes his choices based on what it internally thinks."
    seed = getMonoTime().ticks
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": host = val
      of "port": port = parseInt(val)
      of "name": name = val
      of "personality": personality = val
      of "seed": seed = parseInt(val)
      else: discard
    else: discard
  runBot(host, port, name, personality, seed)
