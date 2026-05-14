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
  var parts: seq[string]
  for i in 0 ..< players.len:
    if i == currentTurn:
      continue
    parts.add(players[i].name & ": " & (if votes[i] == VoteVeto: "veto" else: "pass"))
  echo "  ", parts.join("  ")
  var vetoCount = 0
  for i in 0 ..< votes.len:
    if i == currentTurn:
      continue
    if votes[i] == VoteVeto: inc vetoCount
  let voterCount = players.len - 1
  if vetoCount * 2 < voterCount:
    echo "  pass: ", factText
  else:
    echo "  veto: ", factText

proc logSituation*(title, description: string) =
  echo ""
  echo "--- Situation ---"
  echo "  ", title
  echo "  ", description

proc logSituationAction*(player: Player, actionText: string) =
  echo "  ", player.name, ": ", actionText
