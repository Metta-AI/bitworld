## Real-frame diagnostic — reads a frame from frames.bin and tests
## whether parseVotingScreen can parse it.

import std/[os, strformat, strutils]

import ../../../sim
import ../../../../common/server
import ../../../../common/protocol

import ../bot
import ../types
import ../voting
import ../localize  # isInterstitialScreen
import ../ascii     # detectInterstitialText, isGameOverText

const FrameSize = ScreenWidth * ScreenHeight

proc main() =
  let framesPath = paramStr(1)
  let targetTick = parseInt(paramStr(2))

  var bot = initBot(masterSeed = 1)
  for i in 0 ..< 8:
    discard bot.sim.addPlayer("acct-" & $i)

  let f = open(framesPath, fmRead)
  defer: f.close()
  let offset = targetTick * FrameSize
  f.setFilePos(offset)
  var frame = newSeq[uint8](FrameSize)
  let bytesRead = f.readBytes(frame, 0, FrameSize)
  if bytesRead != FrameSize:
    echo "failed to read frame at tick ", targetTick
    quit(1)

  for i in 0 ..< FrameSize:
    bot.io.unpacked[i] = frame[i]
  inc bot.frameTick

  let isInterstitial = bot.isInterstitialScreen()
  echo &"tick={targetTick} isInterstitial={isInterstitial}"

  if isInterstitial:
    let text = bot.detectInterstitialText()
    echo &"  interstitialText='{text}'"

  let parsed = bot.parseVotingScreen()
  echo &"  parseVotingScreen={parsed}"

  if parsed:
    echo &"  playerCount={bot.voting.playerCount} cursor={bot.voting.cursor}"
    echo &"  selfSlot={bot.voting.selfSlot}"
    for i in 0 ..< bot.voting.playerCount:
      echo &"    slot[{i}]: color={bot.voting.slots[i].colorIndex} alive={bot.voting.slots[i].alive}"
  else:
    for count in [8, 10, 6, 4]:
      let layout = voteGridLayout(count)
      let skipOk = bot.voteSkipTextMatches(layout.skipX, layout.skipY)
      echo &"  count={count}: skipTextMatches={skipOk}"
      if skipOk or count == 8:
        for i in 0 ..< count:
          let slot = bot.parseVoteSlot(count, i)
          echo &"    slot[{i}]: colorIndex={slot.colorIndex} alive={slot.alive}"

  # Dump SKIP area pixels for font diagnosis
  let layout = voteGridLayout(8)
  echo &"\n  SKIP area (skipX={layout.skipX} skipY={layout.skipY}):"
  for y in max(0, layout.skipY-1) .. min(ScreenHeight-1, layout.skipY+7):
    var row = ""
    for x in max(0, layout.skipX-2) .. min(ScreenWidth-1, layout.skipX+30):
      let px = frame[y * ScreenWidth + x]
      if px == 2: row.add('#')
      elif px == 0: row.add('.')
      else: row.add(chr(ord('0') + int(px) mod 10))
    echo &"    y={y:3d}: {row}"

when isMainModule:
  main()
