import
  std/[json, options, os, strutils],
  curly, jsony

const
  DefaultOpenAiTimeoutSeconds = 30

var
  aiKey* = getEnv("OPENAI_KEY")
let
  aiResponsesUrl = "https://api.openai.com/v1/responses"
  aiTextModel = "gpt-5.1-codex"
  curl = newCurly(3)

type
  ConversationMessage* = object
    role*: string
    content*: string

  TalkResult* = object
    done*: bool
    ok*: bool
    tag*: string
    reply*: string
    error*: string

  ResponseRequest = ref object
    model: string
    input: seq[ConversationMessage]

proc openAiTimeoutSeconds(): int =
  ## Returns the OpenAI request timeout from the environment.
  let value = getEnv("OPENAI_TIMEOUT_SECONDS").strip()
  if value.len == 0:
    return DefaultOpenAiTimeoutSeconds
  try:
    max(1, int(parseFloat(value)))
  except ValueError:
    DefaultOpenAiTimeoutSeconds

proc requestBody(messages: openArray[ConversationMessage]): string =
  ## Builds one OpenAI Responses request body.
  var input: seq[ConversationMessage]
  for message in messages:
    input.add(message)
  let request = ResponseRequest(
    model: aiTextModel,
    input: input
  )
  request.toJson()

proc requestHeaders(): HttpHeaders =
  ## Builds one OpenAI request header set.
  result["Authorization"] = "Bearer " & aiKey
  result["Content-Type"] = "application/json"

proc parseReply(body: string): string =
  ## Extracts output text from one OpenAI Responses API body.
  let data = parseJson(body)
  for item in data["output"]:
    if item{"type"}.getStr() == "message":
      for part in item["content"]:
        if part{"type"}.getStr() == "output_text":
          result.add part["text"].getStr()

proc startTalkToAI*(
  messages: openArray[ConversationMessage],
  tag = ""
): bool =
  ## Starts a non-blocking OpenAI Responses API request.
  if aiKey.len == 0:
    return false
  curl.startRequest(
    "POST",
    aiResponsesUrl,
    requestHeaders(),
    requestBody(messages),
    openAiTimeoutSeconds(),
    tag
  )
  true

proc pollTalkToAI*(): TalkResult =
  ## Polls for one finished non-blocking OpenAI request.
  let answer = curl.pollForResponse()
  if answer.isNone:
    return TalkResult(done: false)
  result.done = true
  result.tag = answer.get.response.request.tag
  if answer.get.error.len > 0:
    result.error = answer.get.error
    return
  let response = answer.get.response
  if response.code != 200:
    result.error = response.body
    echo "ERROR: ", response.body
    return
  try:
    result.reply = response.body.parseReply()
  except CatchableError as err:
    result.error = err.msg
    return
  if result.reply.len == 0:
    result.error = "OpenAI response did not include output text"
    return
  result.ok = true
  echo "AI: ", result.reply

proc last*[T](arr: seq[T], number: int): seq[T] =
  ## Returns the last `number` elements of the array `arr` or the whole
  ## array if `number` is greater than the length of the array.
  if number >= arr.len:
    return arr
  return arr[arr.len - number .. ^1]

proc talkToAI*(messages: var seq[ConversationMessage]): string =
  ## Sends messages to the OpenAI Responses API and returns the reply.
  let response = curl.post(
    aiResponsesUrl,
    requestHeaders(),
    requestBody(messages),
    openAiTimeoutSeconds()
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
