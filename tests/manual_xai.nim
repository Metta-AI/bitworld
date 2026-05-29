import bitworld/ais/xai as xaiAi

echo "Testing xAI adapter helpers"
var messages = @[
  xaiAi.ConversationMessage(role: "user", content: "hello")
]
doAssert messages.last(1).len == 1
doAssert messages.last(2).len == 1
echo "All tests passed"
