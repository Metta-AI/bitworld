import std/json
import curly, jsony

var
  aiKey* = ""
let
  aiResponsesUrl = "https://api.openai.com/v1/responses"
  aiTextModel = "gpt-5.1-codex"
  curl = newCurlPool(3)

const
  OpenAiTimeoutSeconds = (60 * 3).float32 # 3 min

type
  ConversationMessage* = object
    role*: string
    content*: string

  ResponseRequest = ref object
    model: string
    input: seq[ConversationMessage]

proc last*[T](arr: seq[T], number: int): seq[T] =
  ## Returns the last `number` elements of the array `arr` or the whole
  ## array if `number` is greater than the length of the array.
  if number >= arr.len:
    return arr
  return arr[arr.len - number .. ^1]

proc talkToAI*(messages: var seq[ConversationMessage]): string =
  ## Sends messages to the OpenAI Responses API and returns the reply.
  let request = ResponseRequest(
    model: aiTextModel,
    input: messages,
  )
  let response = curl.post(
    aiResponsesUrl,
    @[
      ("Authorization", "Bearer " & aiKey),
      ("Content-Type", "application/json")
    ],
    request.toJson(),
    OpenAiTimeoutSeconds
  )
  if response.code != 200:
    echo "ERROR: ", response.body
    return
  let data = parseJson(response.body)
  var reply = ""
  for item in data["output"]:
    if item{"type"}.getStr() == "message":
      for part in item["content"]:
        if part{"type"}.getStr() == "output_text":
          reply.add part["text"].getStr()
  echo "AI: ", reply
  messages.add(
    ConversationMessage(
      role: "assistant",
      content: reply
    )
  )
  return reply
