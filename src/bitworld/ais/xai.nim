import curly, jsony

var
  xaiKey* = ""
let
  xaiUrl = "https://api.x.ai/v1/chat/completions"
  xaiModel = "grok-4-latest"
  curl = newCurlPool(3)

const
  XaiTimeoutSeconds = (60 * 3).float32 # 3 min

type
  ConversationMessage* = object
    role*: string
    content*: string
  ChatRequest = object
    model: string
    messages: seq[ConversationMessage]
    stream: bool
    temperature: float
  Completion = object
    index: int
    message: ConversationMessage
    finishReason: string
  CompletionsResponse = object
    choices: seq[Completion]

proc last*[T](arr: seq[T], number: int): seq[T] =
  ## Returns the last `number` elements of the array or the whole
  ## array if `number` is greater than the length of the array.
  if number >= arr.len:
    return arr
  return arr[arr.len - number .. ^1]

proc talkToAI*(messages: var seq[ConversationMessage]): string =
  ## Sends messages to the xAI chat completions API and returns the reply.
  let request = ChatRequest(
    model: xaiModel,
    messages: messages,
    stream: false,
    temperature: 0.7,
  )
  let response = curl.post(
    xaiUrl,
    @[
      ("Authorization", "Bearer " & xaiKey),
      ("Content-Type", "application/json")
    ],
    request.toJson(),
    XaiTimeoutSeconds
  )
  if response.code != 200:
    echo "ERROR: ", response.body
    return
  let data = response.body.fromJson(CompletionsResponse)
  let reply = data.choices[0].message.content
  echo "AI: ", reply
  messages.add(
    ConversationMessage(
      role: "assistant",
      content: reply
    )
  )
  return reply
