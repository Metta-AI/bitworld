import std/json
import curly

var
  geminiKey* = ""
let
  geminiModel = "gemini-2.5-flash"
  curl = newCurlPool(3)

const
  GeminiTimeoutSeconds = (60 * 3).float32 # 3 min

type
  ConversationMessage* = object
    role*: string
    content*: string

proc geminiUrl(model: string): string =
  ## Builds the Gemini endpoint URL for a specific model.
  return "https://generativelanguage.googleapis.com/v1beta/models/" &
    model & ":generateContent?key=" & geminiKey

proc last*[T](arr: seq[T], number: int): seq[T] =
  ## Returns the last `number` elements of the array or the whole
  ## array if `number` is greater than the length of the array.
  if number >= arr.len:
    return arr
  return arr[arr.len - number .. ^1]

proc talkToAI*(messages: var seq[ConversationMessage]): string =
  ## Sends messages to the Gemini generateContent API and returns the reply.
  var systemText = ""
  var contents = newJArray()
  for msg in messages:
    if msg.role == "system":
      systemText = msg.content
    else:
      let role = if msg.role == "assistant": "model" else: msg.role
      contents.add(%*{"role": role, "parts": [{"text": msg.content}]})
  var body = %*{"contents": contents}
  if systemText.len > 0:
    body["systemInstruction"] = %*{"parts": [{"text": systemText}]}
  let response = curl.post(
    geminiUrl(geminiModel),
    @[("Content-Type", "application/json")],
    $body,
    GeminiTimeoutSeconds
  )
  if response.code != 200:
    echo "ERROR: ", response.body
    return
  let data = parseJson(response.body)
  var reply = ""
  for part in data["candidates"][0]["content"]["parts"]:
    if part.hasKey("text"):
      reply.add part["text"].getStr()
  echo "AI: ", reply
  messages.add(
    ConversationMessage(
      role: "assistant",
      content: reply
    )
  )
  return reply
