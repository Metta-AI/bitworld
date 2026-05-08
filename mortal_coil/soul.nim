import std/strutils
import claude

const
  MaxFactLen* = 38

type
  Soul* = object
    passions*: seq[string]

proc newSoul*(): Soul =
  Soul(passions: @[])

proc generateFacts*(soul: Soul, chatLog: seq[string]): array[3, string] =
  var prompt = "You are a world-building oracle for a dark fantasy game. "
  prompt.add("Generate exactly 3 short mystical facts about how the world works. ")
  prompt.add("Each fact MUST be " & $(MaxFactLen - 8) & " characters or fewer.")
  prompt.add("Each fact should be a single lowercase statement about a rule of the world. ")

  if soul.passions.len > 0:
    prompt.add("The player's passions are: " & soul.passions.join(", ") & ". ")
    prompt.add("Facts should relate to these passions. ")

  if chatLog.len > 0:
    prompt.add("The story so far:\n")
    for entry in chatLog:
      prompt.add("- " & entry & "\n")
    prompt.add("Facts should build on or complement the existing lore. ")

  prompt.add("Respond with exactly 3 lines, one fact per line, nothing else.")

  let response = claude.ask(prompt)
  let lines = response.strip().splitLines()

  var idx = 0
  for line in lines:
    if idx >= 3:
      break
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    if trimmed.len <= MaxFactLen:
      result[idx] = trimmed
    else:
      result[idx] = trimmed[0 ..< MaxFactLen]
    inc idx

  for i in idx ..< 3:
    result[i] = "the void whispers back"
