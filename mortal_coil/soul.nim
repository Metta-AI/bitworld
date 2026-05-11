import std/[strutils, random]
import claude

const
  MaxFactLen* = 38

type
  Soul* = object
    passions*: seq[string]

proc newSoul*(): Soul =
  Soul(passions: @[])

proc generateWorld*(soul: Soul): tuple[title: string, description: string] =
  const seeds = [
    "bone", "silk", "rust", "tide", "moss", "salt", "wax", "iron",
    "glass", "thorn", "ember", "frost", "dust", "hollow", "ink", "veil",
    "blood", "cosmos", "dark", "ash", "flame", "void", "dream", "storm",
    "crystal", "shadow", "rot", "gold", "teeth", "smoke", "mirror", "root",
    "hunger", "clock", "worm", "stone", "feather", "ocean", "plague", "star",
    "chain", "moth", "fungus", "candle", "copper", "marrow", "fog", "river",
    "oracle", "grave", "skin", "pearl", "thunder", "coral", "obsidian", "web",
    "spiral", "breath", "lantern", "sorrow", "honey", "mercury", "ruin", "egg",
    "anvil", "crypt", "pollen", "quartz", "bile", "aurora", "spine", "tar",
    "lotus", "cipher", "wolf", "sulfur", "needle", "abyss", "amber", "tongue",
    "furnace", "lichen", "bell", "swamp", "comet", "sinew", "mask", "clay",
    "hymn", "vapor", "claw", "labyrinth", "chalk", "serpent", "dusk", "loom",
    "orbit", "pyre", "kelp", "whisper", "anvil", "opal", "carrion", "tide",
    "sigil", "knot", "glacier", "poppy", "crucible", "mist", "talon", "well",
    "spore", "dirge"
  ]
  var rng = initRand()
  let seed = seeds[rng.rand(seeds.high)]

  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "Create a game setting inspired by the concept of '" & seed & "'.\n"
  prompt &= "Respond with exactly 2 lines:\n"
  prompt &= "Line 1: A short evocative title (max 20 characters, lowercase)\n"
  prompt &= "Line 2: A 100 character description of the world (lowercase)\n"

  if soul.passions.len > 0:
    prompt.add("Draw inspiration from: " & soul.passions.join(", ") & ". ")

  prompt.add("Respond with exactly 2 lines, nothing else.")

  let response = claude.ask(prompt)
  var nonEmpty: seq[string]
  for line in response.strip().splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      nonEmpty.add(trimmed)

  if nonEmpty.len >= 2:
    result.title = nonEmpty[0]
    if result.title.len > 20:
      result.title = result.title[0 ..< 20]
    result.description = nonEmpty[1]
    if result.description.len > 100:
      result.description = result.description[0 ..< 100]
  elif nonEmpty.len == 1:
    result.title = nonEmpty[0]
    if result.title.len > 20:
      result.title = result.title[0 ..< 20]
    result.description = "a world where shadows speak and the forgotten remember"
  else:
    result.title = "the nameless land"
    result.description = "a world where shadows speak and the forgotten remember"

proc generateFacts*(soul: Soul, chatLog: seq[string]): array[3, string] =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "Generate exactly 3 short mystical facts about how the world works.\n"
  prompt &= "Each fact MUST be " & $(MaxFactLen - 8) & " characters or fewer.\n"
  prompt &= "Each fact should be a single lowercase statement about a rule of the world.\n"

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
