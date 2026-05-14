import std/[strutils, random]
import claude

const FactMaxLen* = 38
const FactPadding* = 8
const WorldTitleMaxLen* = 20
const WorldMaxLen* = 120
const WorldPadding* = 20
const SituationTitleMaxLen* = 20
const SituationMaxLen* = 120
const SituationPadding* = 20
const ConflictTitleMaxLen* = 20
const ConflictMaxLen* = 120
const ConflictPadding* = 20
const ConflictResolutionMaxLen* = 120
const ConflictResolutionPadding* = 20
const SceneHeaderMaxLen* = 38
const SceneHeaderPadding* = 8
const SceneOptionMaxLen* = 38
const SceneOptionPadding* = 8

type
  Attitude* = enum
    Adversarial
    Neutral
    Cooperative

  ChoiceScheme* = object
    attitude*: Attitude
    effect*: int

  World* = object
    title*: string
    description*: string

  Situation* = object
    title*: string
    description*: string

  Conflict* = object
    title*: string
    description*: string

  Soul* = object
    passions*: seq[string]

  ScenePrompt* = object
    header*: string
    options*: array[4, string]

proc newSoul*(): Soul =
  Soul(passions: @[])

proc generateWorld*(soul: Soul): World =
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
  prompt &= "Line 1: A short evocative title (max " & $WorldTitleMaxLen & " characters, lowercase)\n"
  prompt &= "Line 2: A " & $(WorldMaxLen - WorldPadding) & " character description of the world (lowercase)\n"

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
    if result.title.len > WorldTitleMaxLen:
      result.title = result.title[0 ..< WorldTitleMaxLen]
    result.description = nonEmpty[1]
    if result.description.len > WorldMaxLen:
      result.description = result.description[0 ..< WorldMaxLen]
  elif nonEmpty.len == 1:
    result.title = nonEmpty[0]
    if result.title.len > WorldTitleMaxLen:
      result.title = result.title[0 ..< WorldTitleMaxLen]
    result.description = "a world where shadows speak and the forgotten remember"
  else:
    result.title = "the nameless land"
    result.description = "a world where shadows speak and the forgotten remember"

proc generateFacts*(soul: Soul, world: World, chatLog: seq[string]): array[3, string] =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "Generate exactly 3 short mystical facts about how this world works.\n"
  prompt &= "Each fact MUST be " & $(FactMaxLen - FactPadding) & " characters or fewer.\n"
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
    if trimmed.len <= FactMaxLen:
      result[idx] = trimmed
    else:
      result[idx] = trimmed[0 ..< FactMaxLen]
    inc idx

  for i in idx ..< 3:
    result[i] = "the void whispers back"

proc generateSituation*(soul: Soul, world: World, chatLog: seq[string], previousSituations: seq[Situation]): Situation =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"

  if chatLog.len > 0:
    prompt &= "Magical facts established:\n"
    for entry in chatLog:
      prompt &= "- " & entry & "\n"

  if previousSituations.len > 0:
    prompt &= "Previous situations:\n"
    for sit in previousSituations:
      prompt &= "- " & sit.title & ": " & sit.description & "\n"

  prompt &= "Generate a new situation for the players.\n"
  prompt &= "Respond with exactly 2 lines:\n"
  prompt &= "Line 1: A short evocative title (max " & $SituationTitleMaxLen & " characters, lowercase)\n"
  prompt &= "Line 2: A " & $(SituationMaxLen - SituationPadding) & " character description of the situation (lowercase)\n"
  prompt &= "The situation must not imply direct conflict, its for the players to explore the world.\n"
  prompt &= "Respond with exactly 2 lines, nothing else."

  let response = claude.ask(prompt)
  var nonEmpty: seq[string]
  for line in response.strip().splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      nonEmpty.add(trimmed)

  if nonEmpty.len >= 2:
    result.title = nonEmpty[0]
    if result.title.len > SituationTitleMaxLen:
      result.title = result.title[0 ..< SituationTitleMaxLen]
    result.description = nonEmpty[1]
    if result.description.len > SituationMaxLen:
      result.description = result.description[0 ..< SituationMaxLen]
  elif nonEmpty.len == 1:
    result.title = nonEmpty[0]
    if result.title.len > SituationTitleMaxLen:
      result.title = result.title[0 ..< SituationTitleMaxLen]
    result.description = "something stirs in the darkness"
  else:
    result.title = "the unknown"
    result.description = "something stirs in the darkness"

proc generateSceneOptions*(soul: Soul, world: World, situation: Situation, chatLog: seq[string]): ScenePrompt =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The current situation is '" & situation.title & "': " & situation.description & ".\n"
  prompt &= "Generate a short header summarizing what this player perceives, followed by 4 actions.\n"
  prompt &= "The header is this player's subjective take on the situation.\n"
  prompt &= "Respond with exactly 5 lines:\n"
  prompt &= "Line 1: A header (max " & $(SceneHeaderMaxLen - SceneHeaderPadding) & " characters, lowercase)\n"
  prompt &= "Lines 2-5: Actions (each max " & $(SceneOptionMaxLen - SceneOptionPadding) & " characters, lowercase)\n"

  if soul.passions.len > 0:
    prompt.add("The player's passions are: " & soul.passions.join(", ") & ". ")
    prompt.add("The header and actions should reflect these passions. ")

  if chatLog.len > 0:
    prompt.add("The story so far:\n")
    for entry in chatLog:
      prompt.add("- " & entry & "\n")

  prompt.add("Respond with exactly 5 lines, no prefixes, no numbering, no bullets, just raw text.")

  let response = claude.ask(prompt)
  let lines = response.strip().splitLines()

  var nonEmpty: seq[string]
  for line in lines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      nonEmpty.add(trimmed)

  if nonEmpty.len >= 1:
    result.header = nonEmpty[0]
    if result.header.len > SceneHeaderMaxLen:
      result.header = result.header[0 ..< SceneHeaderMaxLen]
  else:
    result.header = "the world awaits"

  var idx = 0
  for i in 1 ..< nonEmpty.len:
    if idx >= 4:
      break
    let cleaned = nonEmpty[i]
    if cleaned.len <= SceneOptionMaxLen:
      result.options[idx] = cleaned
    else:
      result.options[idx] = cleaned[0 ..< SceneOptionMaxLen]
    inc idx

  for i in idx ..< 4:
    result.options[i] = "stare into the void"

proc attitudeDescription(attitude: Attitude): string =
  case attitude
  of Adversarial: "adversarial (harms or exploits another party member)"
  of Neutral: "neutral (affects only self or enemies, not allies)"
  of Cooperative: "cooperative (helps or protects another party member)"

proc effectDescription(effect: int): string =
  if effect > 0: "gains " & $effect & " power"
  elif effect < 0: "costs " & $(-effect) & " power"
  else: "no power change"

proc generateConflictOptions*(soul: Soul, world: World, conflict: Conflict,
    schemes: array[4, ChoiceScheme], chatLog: seq[string]): ScenePrompt =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The conflict is '" & conflict.title & "': " & conflict.description & ".\n"
  prompt &= "Generate a short header summarizing what this player perceives, followed by 4 actions.\n"
  prompt &= "The header is this player's subjective take on the conflict.\n"
  prompt &= "Each action MUST match its assigned attitude and power effect:\n"
  for i in 0 ..< 4:
    prompt &= "  - " & attitudeDescription(schemes[i].attitude) &
      ", " & effectDescription(schemes[i].effect) & "\n"
  prompt &= "Adversarial = action taken against party members (using them as cover, attacking them).\n"
  prompt &= "Neutral = action affecting only self or enemies (attacking a monster, dodging, thinking).\n"
  prompt &= "Cooperative = action benefiting party members (shielding them, healing them).\n"
  prompt &= "Respond with exactly 5 lines:\n"
  prompt &= "Line 1: A header (max " & $(SceneHeaderMaxLen - SceneHeaderPadding) & " characters, lowercase)\n"
  prompt &= "Lines 2-5: Actions (each max " & $(SceneOptionMaxLen - SceneOptionPadding) & " characters, lowercase)\n"

  if soul.passions.len > 0:
    prompt.add("The player's passions are: " & soul.passions.join(", ") & ". ")
    prompt.add("The header and actions should reflect these passions. ")

  if chatLog.len > 0:
    prompt.add("The story so far:\n")
    for entry in chatLog:
      prompt.add("- " & entry & "\n")

  prompt.add("Respond with exactly 5 lines, no prefixes, no numbering, no bullets, just raw text.")

  let response = claude.ask(prompt)
  let lines = response.strip().splitLines()

  var nonEmpty: seq[string]
  for line in lines:
    let trimmed = line.strip()
    if trimmed.len > 0:
      nonEmpty.add(trimmed)

  if nonEmpty.len >= 1:
    result.header = nonEmpty[0]
    if result.header.len > SceneHeaderMaxLen:
      result.header = result.header[0 ..< SceneHeaderMaxLen]
  else:
    result.header = "the conflict deepens"

  var idx = 0
  for i in 1 ..< nonEmpty.len:
    if idx >= 4:
      break
    let cleaned = nonEmpty[i]
    if cleaned.len <= SceneOptionMaxLen:
      result.options[idx] = cleaned
    else:
      result.options[idx] = cleaned[0 ..< SceneOptionMaxLen]
    inc idx

  for i in idx ..< 4:
    result.options[i] = "stare into the void"

proc generateConflict*(soul: Soul, world: World, situation: Situation, chatLog: seq[string]): Conflict =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The last situation was '" & situation.title & "': " & situation.description & ".\n"
  prompt &= "Based on the players' actions, a conflict has emerged.\n"
  prompt &= "Generate a conflict that arises from the situation.\n"
  prompt &= "Respond with exactly 2 lines:\n"
  prompt &= "Line 1: A short evocative title (max " & $ConflictTitleMaxLen & " characters, lowercase)\n"
  prompt &= "Line 2: A " & $(ConflictMaxLen - ConflictPadding) & " character description of the conflict (lowercase)\n"

  if chatLog.len > 0:
    prompt.add("The story so far:\n")
    for entry in chatLog:
      prompt.add("- " & entry & "\n")

  prompt.add("Respond with exactly 2 lines, nothing else.")

  let response = claude.ask(prompt)
  var nonEmpty: seq[string]
  for line in response.strip().splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      nonEmpty.add(trimmed)

  if nonEmpty.len >= 2:
    result.title = nonEmpty[0]
    if result.title.len > ConflictTitleMaxLen:
      result.title = result.title[0 ..< ConflictTitleMaxLen]
    result.description = nonEmpty[1]
    if result.description.len > ConflictMaxLen:
      result.description = result.description[0 ..< ConflictMaxLen]
  elif nonEmpty.len == 1:
    result.title = nonEmpty[0]
    if result.title.len > ConflictTitleMaxLen:
      result.title = result.title[0 ..< ConflictTitleMaxLen]
    result.description = "tensions rise beyond breaking"
  else:
    result.title = "the clash"
    result.description = "tensions rise beyond breaking"

proc generateConflictEscalation*(soul: Soul, world: World, conflict: Conflict, round: int, chatLog: seq[string]): string =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The conflict is '" & conflict.title & "': " & conflict.description & ".\n"
  prompt &= "This is escalation round " & $(round + 1) & " of 3. The tension is rising.\n"
  prompt &= "Generate a single sentence describing the escalation (max " & $(ConflictMaxLen - ConflictPadding) & " characters, lowercase).\n"

  if chatLog.len > 0:
    prompt.add("The story so far:\n")
    for entry in chatLog:
      prompt.add("- " & entry & "\n")

  prompt.add("Respond with exactly 1 line, nothing else.")

  let response = claude.ask(prompt).strip()
  if response.len > 0:
    if response.len <= ConflictMaxLen:
      return response
    else:
      return response[0 ..< ConflictMaxLen]
  "the conflict deepens"

proc generateConflictResolution*(soul: Soul, world: World, conflict: Conflict, chatLog: seq[string]): string =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The conflict was '" & conflict.title & "': " & conflict.description & ".\n"
  prompt &= "Based on the players' actions, the conflict has resolved.\n"
  prompt &= "Generate a single sentence describing the resolution (max " & $(ConflictResolutionMaxLen - ConflictResolutionPadding) & " characters, lowercase).\n"

  if chatLog.len > 0:
    prompt.add("The story so far:\n")
    for entry in chatLog:
      prompt.add("- " & entry & "\n")

  prompt.add("Respond with exactly 1 line, nothing else.")

  let response = claude.ask(prompt).strip()
  if response.len > 0:
    if response.len <= ConflictResolutionMaxLen:
      return response
    else:
      return response[0 ..< ConflictResolutionMaxLen]
  "the dust settles"
