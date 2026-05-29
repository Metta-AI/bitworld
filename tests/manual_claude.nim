import bitworld/ais/claude as claudeAi

echo "Testing Claude adapter helpers"
var messages = @[
  claudeAi.ConversationMessage(role: "user", content: "hello")
]
doAssert messages.last(1).len == 1
doAssert messages.last(2).len == 1
echo "All tests passed"
