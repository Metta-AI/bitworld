import bitworld/ais/gemini as geminiAi

echo "Testing Gemini adapter helpers"
var messages = @[
  geminiAi.ConversationMessage(role: "user", content: "hello")
]
doAssert messages.last(1).len == 1
doAssert messages.last(2).len == 1
echo "All tests passed"
