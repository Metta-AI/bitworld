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
const ConflictOutcomeMaxLen* = 120
const ConflictOutcomePadding* = 20
const ConflictOutcomeNarrationMaxLen* = 80
const ConflictOutcomeNarrationPadding* = 10
const ConflictResolutionMaxLen* = 120
const ConflictResolutionPadding* = 20
const SceneHeaderMaxLen* = 38
const SceneHeaderPadding* = 8
const SceneOptionMaxLen* = 60
const SceneOptionPadding* = 12

type
  RiskTarget* = enum
    TargetSelf
    TargetOthers

  ChoiceScheme* = object
    risk*: int             # 0 to 2
    bearer*: RiskTarget    # who bears the risk
    rewarded*: RiskTarget  # who gets the reward

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

  OutcomeScore* = object
    playerName*: string
    score*: int  # -1, 0, +1

  ConflictOutcomeResult* = object
    narration*: string
    scores*: seq[OutcomeScore]

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
  prompt &= "Line 1: A short evocative title (max " & $WorldTitleMaxLen & " characters, title case)\n"
  prompt &= "Line 2: A " & $(WorldMaxLen - WorldPadding) & " character description of the world (sentence case, ends with a period)\n"

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
    result.description = "A world where shadows speak and the forgotten remember."
  else:
    result.title = "The Nameless Land"
    result.description = "A world where shadows speak and the forgotten remember."

proc generateFacts*(soul: Soul, world: World, chatLog: seq[string]): array[3, string] =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "Generate exactly 3 short mystical facts about how this world works.\n"
  prompt &= "Each fact MUST be " & $(FactMaxLen - FactPadding) & " characters or fewer.\n"
  prompt &= "Each fact should be a single sentence about a rule of the world (sentence case, ends with a period).\n"

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
    result[i] = "The void whispers back."

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
  prompt &= "Line 1: A short evocative title (max " & $SituationTitleMaxLen & " characters, title case)\n"
  prompt &= "Line 2: A " & $(SituationMaxLen - SituationPadding) & " character description of the situation (sentence case, ends with a period)\n"
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
    result.description = "Something stirs in the darkness."
  else:
    result.title = "The Unknown"
    result.description = "Something stirs in the darkness."

proc generateSceneOptions*(soul: Soul, world: World, situation: Situation, chatLog: seq[string]): ScenePrompt =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The current situation is '" & situation.title & "': " & situation.description & ".\n"
  prompt &= "Generate a short header summarizing what this player perceives, followed by 4 actions.\n"
  prompt &= "The header is this player's subjective take on the situation.\n"
  prompt &= "Respond with exactly 5 lines:\n"
  prompt &= "Line 1: A header (max " & $(SceneHeaderMaxLen - SceneHeaderPadding) & " characters, sentence case, ends with a period)\n"
  prompt &= "Lines 2-5: Actions (each max " & $(SceneOptionMaxLen - SceneOptionPadding) & " characters, sentence case, ends with a period)\n"

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
    result.header = "The world awaits."

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
    result.options[i] = "Stare into the void."

proc riskTargetDescription(target: RiskTarget): string =
  case target
  of TargetSelf: "self"
  of TargetOthers: "the other party members"

proc schemeDescription(scheme: ChoiceScheme): string =
  "risk " & $scheme.risk & ", " &
    riskTargetDescription(scheme.bearer) & " bears the risk, " &
    riskTargetDescription(scheme.rewarded) & " gets the reward"

proc generateConflictOptions*(soul: Soul, world: World, conflict: Conflict,
    schemes: array[4, ChoiceScheme], chatLog: seq[string]): ScenePrompt =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The conflict is '" & conflict.title & "': " & conflict.description & ".\n"
  prompt &= "Generate a short header summarizing what this player perceives, followed by 4 actions.\n"
  prompt &= "The header is this player's subjective take on the conflict.\n"
  prompt &= "Each action MUST match its assigned risk profile:\n"
  for i in 0 ..< 4:
    prompt &= "  - " & schemeDescription(schemes[i]) & "\n"
  prompt &= "Risk 0 = safe/cautious action. Risk 1 = moderate danger. Risk 2 = reckless/desperate.\n"
  prompt &= "Bearer = who bears the danger of this choice (self or others in the party).\n"
  prompt &= "Rewarded = who benefits if it pays off (self or others in the party).\n"
  prompt &= "Higher risk means the action should feel more dangerous or ambitious.\n"
  prompt &= "Respond with exactly 5 lines:\n"
  prompt &= "Line 1: A header (max " & $(SceneHeaderMaxLen - SceneHeaderPadding) & " characters, sentence case, ends with a period)\n"
  prompt &= "Lines 2-5: Actions (each max " & $(SceneOptionMaxLen - SceneOptionPadding) & " characters, sentence case, ends with a period)\n"

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
    result.header = "The conflict deepens."

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
    result.options[i] = "Stare into the void."

proc generateConflict*(soul: Soul, world: World, situation: Situation, chatLog: seq[string]): Conflict =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The last situation was '" & situation.title & "': " & situation.description & ".\n"
  prompt &= "Based on the players' actions, a conflict has emerged.\n"
  prompt &= "Generate a conflict that arises from the situation.\n"
  prompt &= "Respond with exactly 2 lines:\n"
  prompt &= "Line 1: A short evocative title (max " & $ConflictTitleMaxLen & " characters, title case)\n"
  prompt &= "Line 2: A " & $(ConflictMaxLen - ConflictPadding) & " character description of the conflict (sentence case, ends with a period)\n"

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
    result.description = "Tensions rise beyond breaking."
  else:
    result.title = "The Clash"
    result.description = "Tensions rise beyond breaking."

proc generateConflictEscalation*(soul: Soul, world: World, conflict: Conflict, round: int, chatLog: seq[string]): string =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The conflict is '" & conflict.title & "': " & conflict.description & ".\n"
  prompt &= "This is escalation round " & $(round + 1) & " of 3. The tension is rising.\n"
  prompt &= "Generate a single sentence describing the escalation (max " & $(ConflictMaxLen - ConflictPadding) & " characters, sentence case, ends with a period).\n"

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
  "The conflict deepens."

proc generateConflictOutcome*(soul: Soul, world: World, conflict: Conflict,
    round: int, playerNames: seq[string], chatLog: seq[string]): ConflictOutcomeResult =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The conflict is '" & conflict.title & "': " & conflict.description & ".\n"
  prompt &= "Round " & $(round + 1) & " of 3 just ended. The players made their choices.\n"
  prompt &= "Briefly narrate what happens, then score each player's choice.\n"
  prompt &= "Score meaning: -1 = failed (choice backfired), 0 = neutral, +1 = achieved (choice succeeded).\n"
  prompt &= "Higher-risk choices (higher power at stake) are harder to pull off.\n"
  prompt &= "Respond with exactly " & $(1 + playerNames.len) & " lines:\n"
  prompt &= "Line 1: A short narrative of what happens (max " & $(ConflictOutcomeMaxLen - ConflictOutcomePadding) & " characters, sentence case, ends with a period)\n"
  for i in 0 ..< playerNames.len:
    prompt &= "Line " & $(i + 2) & ": " & playerNames[i] & " score (just -1, 0, or 1)\n"

  if chatLog.len > 0:
    prompt.add("The story so far:\n")
    for entry in chatLog:
      prompt.add("- " & entry & "\n")

  prompt.add("Respond with exactly " & $(1 + playerNames.len) & " lines, nothing else.")

  let response = claude.ask(prompt)
  var nonEmpty: seq[string]
  for line in response.strip().splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      nonEmpty.add(trimmed)

  if nonEmpty.len >= 1:
    result.narration = nonEmpty[0]
    if result.narration.len > ConflictOutcomeMaxLen:
      result.narration = result.narration[0 ..< ConflictOutcomeMaxLen]
  else:
    result.narration = "The consequences unfold."

  for i in 0 ..< playerNames.len:
    var score = 0
    if i + 1 < nonEmpty.len:
      let scoreLine = nonEmpty[i + 1]
      if scoreLine.contains("-1"): score = -1
      elif scoreLine.contains("1"): score = 1
    result.scores.add(OutcomeScore(playerName: playerNames[i], score: score))

proc generateConflictResolution*(soul: Soul, world: World, conflict: Conflict, chatLog: seq[string]): string =
  var prompt = ""
  prompt &= "You are a world-building oracle for a dark fantasy game.\n"
  prompt &= "The world is called '" & world.title & "': " & world.description & ".\n"
  prompt &= "The conflict was '" & conflict.title & "': " & conflict.description & ".\n"
  prompt &= "Based on the players' actions, the conflict has resolved.\n"
  prompt &= "Generate a single sentence describing the resolution (max " & $(ConflictResolutionMaxLen - ConflictResolutionPadding) & " characters, sentence case, ends with a period).\n"

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
  "The dust settles."
