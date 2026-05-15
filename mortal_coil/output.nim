import std/strutils
import data

proc logWorld*(title, description: string) =
  echo ""
  echo "--- The World ---"
  echo "  ", title
  echo "  ", description

proc logMagicalFactsPhase*() =
  echo ""
  echo "--- Magical Facts ---"

proc logFactSkipped*(playerName: string) =
  echo "  ", playerName, " skipped."

proc logFactOutcome*(players: seq[Player], currentTurn: int,
    factText: string, votes: seq[Vote]) =
  echo "  ", players[currentTurn].name, " chose a fact."
  var vetoCount = 0
  for i in 0 ..< votes.len:
    if i == currentTurn:
      continue
    if votes[i] == VoteVeto: inc vetoCount
  let voterCount = players.len - 1
  let passed = vetoCount * 2 < voterCount
  let resultWord = if passed: "pass" else: "veto"
  var parts: seq[string]
  for i in 0 ..< players.len:
    if i == currentTurn:
      continue
    parts.add(players[i].name & ": " & (if votes[i] == VoteVeto: "veto" else: "pass"))
  echo "  Result: ", resultWord, ". ", parts.join(", "), "."
  if passed:
    echo "  ", factText

proc logSituation*(title, description: string) =
  echo ""
  echo "--- Situation ---"
  echo "  ", title
  echo "  ", description

proc logSituationAction*(player: Player, actionText: string) =
  echo "  ", player.name, ": ", actionText

proc logConflict*(chapter: int, title, description: string) =
  echo ""
  echo "--- Chapter ", chapter, " ---"
  echo "  ", title
  echo "  ", description

proc logConflictEscalation*(round: int, description: string) =
  echo "  [round ", round + 1, "] ", description

proc logConflictAction*(player: Player, actionText: string) =
  echo "  ", player.name, ": ", actionText

proc logConflictOutcome*(round: int, outcome: string,
    results: seq[PlayerRoundResult], players: seq[Player]) =
  echo "  [outcome ", round + 1, "] ", outcome
  for r in results:
    let total = r.powerBefore - r.burdenTaken - r.partyBurden + r.rewardEarned + r.partyReward
    echo "    ", players[r.playerIndex].name, " (", r.powerBefore, " power): ",
      "-", r.burdenTaken, " burden, -", r.partyBurden, " party burden, ",
      "+", r.rewardEarned, " reward, +", r.partyReward, " party reward = ", total

proc logConflictResolution*(resolution: string) =
  echo "  Resolution: ", resolution
