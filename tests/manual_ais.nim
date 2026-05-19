import
  std/[os, strutils],
  bitworld/ais/bedrock as bedrockAi,
  bitworld/ais/claude as claudeAi,
  bitworld/ais/gemini as geminiAi,
  bitworld/ais/openai as openAi,
  bitworld/ais/xai as xaiAi

const
  SmokePrompt = "Reply with exactly: ready"

var
  failures = 0

proc clip(value: string): string =
  ## Returns a compact single-line preview of a response.
  result = value.strip().replace("\n", " ")
  if result.len > 80:
    result = result[0 ..< 80] & "..."

proc fail(name, message: string) =
  ## Records and prints one provider failure.
  inc failures
  echo name, " FAILED: ", message

proc requireEnv(name: string): bool =
  ## Returns true if one required environment variable is set.
  result = getEnv(name).strip().len > 0
  if not result:
    fail(name, name & " should be set")

proc requireAnyEnv(name: string, names: openArray[string]): bool =
  ## Returns true if at least one required environment variable is set.
  for name in names:
    if getEnv(name).strip().len > 0:
      return true
  fail(name, names.join(" or ") & " should be set")

proc checkReply(name, reply: string) =
  ## Checks that an AI adapter returned a non-empty reply.
  if reply.strip().len == 0:
    fail(name, name & " should return text")
    return
  echo name, ": ", reply.clip()

proc testClaude() =
  ## Tests the Claude adapter with one short chat request.
  echo "Testing Claude"
  if not requireEnv("CLAUDE_KEY"):
    return
  var messages = @[
    claudeAi.ConversationMessage(
      role: "system",
      content: "You are a terse game NPC."
    ),
    claudeAi.ConversationMessage(
      role: "user",
      content: SmokePrompt
    )
  ]
  checkReply("Claude", claudeAi.talkToAI(messages))

proc testGemini() =
  ## Tests the Gemini adapter with one short chat request.
  echo "Testing Gemini"
  if not requireEnv("GEMINI_KEY"):
    return
  var messages = @[
    geminiAi.ConversationMessage(
      role: "system",
      content: "You are a terse game NPC."
    ),
    geminiAi.ConversationMessage(
      role: "user",
      content: SmokePrompt
    )
  ]
  checkReply("Gemini", geminiAi.talkToAI(messages))

proc testOpenAi() =
  ## Tests the OpenAI adapter with one short chat request.
  echo "Testing OpenAI"
  if not requireEnv("OPENAI_KEY"):
    return
  var messages = @[
    openAi.ConversationMessage(
      role: "system",
      content: "You are a terse game NPC."
    ),
    openAi.ConversationMessage(
      role: "user",
      content: SmokePrompt
    )
  ]
  checkReply("OpenAI", openAi.talkToAI(messages))

proc testXai() =
  ## Tests the xAI adapter with one short chat request.
  echo "Testing xAI"
  if not requireEnv("XAI_KEY"):
    return
  var messages = @[
    xaiAi.ConversationMessage(
      role: "system",
      content: "You are a terse game NPC."
    ),
    xaiAi.ConversationMessage(
      role: "user",
      content: SmokePrompt
    )
  ]
  checkReply("xAI", xaiAi.talkToAI(messages))

proc testBedrock() =
  ## Tests the Bedrock adapter with one short chat request.
  echo "Testing Bedrock"
  if not requireAnyEnv(
    "Bedrock",
    ["AWS_BEARER_TOKEN_BEDROCK", "BEDROCK_KEY"]
  ):
    return
  var messages = @[
    bedrockAi.ConversationMessage(
      role: "system",
      content: "You are a terse game NPC."
    ),
    bedrockAi.ConversationMessage(
      role: "user",
      content: SmokePrompt
    )
  ]
  checkReply("Bedrock", bedrockAi.talkToAI(messages))

testClaude()
testGemini()
testOpenAi()
testXai()
testBedrock()
doAssert failures == 0, $failures & " AI smoke tests failed"
echo "All AI smoke tests passed"
