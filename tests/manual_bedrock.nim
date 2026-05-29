import bitworld/ais/bedrock as bedrockAi

echo "Testing Bedrock adapter helpers"
var messages = @[
  bedrockAi.ConversationMessage(role: "user", content: "hello")
]
doAssert messages.last(1).len == 1
doAssert messages.last(2).len == 1
echo "All tests passed"
