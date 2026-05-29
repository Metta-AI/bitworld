import bitworld/ais/openai as openAi

echo "Testing OpenAI adapter helpers"
var messages = @[
  openAi.ConversationMessage(role: "user", content: "hello")
]
doAssert messages.last(1).len == 1
doAssert messages.last(2).len == 1
echo "All tests passed"
