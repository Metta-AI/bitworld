import
  std/[json, os],
  curly, jsony

const
  BedrockVersion = "bedrock-2023-05-31"
  DefaultBedrockRegion = "us-east-1"
  DefaultBedrockModel = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

type
  ConversationMessage* = object
    role*: string
    content*: string
  MessageRequest = object
    anthropic_version: string
    max_tokens: int
    system: string
    messages: seq[ConversationMessage]

var
  bedrockKey* = getEnv("AWS_BEARER_TOKEN_BEDROCK")
  bedrockRegion* = getEnv("AWS_REGION")
  bedrockModel* = getEnv("BEDROCK_MODEL")

let
  curl = newCurlPool(3)

proc region(): string =
  ## Returns the configured AWS Region for Bedrock requests.
  result = bedrockRegion
  if result.len == 0:
    result = getEnv("AWS_DEFAULT_REGION")
  if result.len == 0:
    result = DefaultBedrockRegion

proc model(): string =
  ## Returns the configured Bedrock model ID for requests.
  if bedrockModel.len > 0:
    return bedrockModel
  DefaultBedrockModel

proc key(): string =
  ## Returns the configured Bedrock bearer token.
  result = bedrockKey
  if result.len == 0:
    result = getEnv("BEDROCK_KEY")

proc bedrockUrl(): string =
  ## Builds the Bedrock Runtime InvokeModel URL.
  "https://bedrock-runtime." & region() &
    ".amazonaws.com/model/" & model() & "/invoke"

proc requestBody(messages: openArray[ConversationMessage]): string =
  ## Builds one Bedrock Anthropic Messages request body.
  var systemPrompt = ""
  var chatMessages: seq[ConversationMessage]
  for msg in messages:
    if msg.role == "system":
      systemPrompt = msg.content
    else:
      chatMessages.add msg
  let request = MessageRequest(
    anthropic_version: BedrockVersion,
    max_tokens: 4096,
    system: systemPrompt,
    messages: chatMessages,
  )
  request.toJson()

proc parseReply(body: string): string =
  ## Extracts output text from one Bedrock response body.
  let data = parseJson(body)
  for part in data["content"]:
    if part{"type"}.getStr() == "text":
      result.add part["text"].getStr()

proc last*[T](arr: seq[T], number: int): seq[T] =
  ## Returns the last `number` elements of the array or the whole
  ## array if `number` is greater than the length of the array.
  if number >= arr.len:
    return arr
  return arr[arr.len - number .. ^1]

proc talkToAI*(messages: var seq[ConversationMessage]): string =
  ## Sends messages to Bedrock Runtime and returns the reply.
  let token = key()
  if token.len == 0:
    echo "ERROR: AWS_BEARER_TOKEN_BEDROCK or BEDROCK_KEY is not set"
    return
  let response = curl.post(
    bedrockUrl(),
    @[
      ("Authorization", "Bearer " & token),
      ("Accept", "application/json"),
      ("Content-Type", "application/json")
    ],
    requestBody(messages)
  )
  if response.code != 200:
    echo "ERROR: ", response.body
    return
  let reply = response.body.parseReply()
  echo "AI: ", reply
  messages.add(
    ConversationMessage(
      role: "assistant",
      content: reply
    )
  )
  return reply
