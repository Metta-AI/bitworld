import std/osproc, std/json, std/os, std/tempfiles, std/base64

const
  model = "us.anthropic.claude-sonnet-4-6"
  region = "us-east-1"

let body = %*{
  "anthropic_version": "bedrock-2023-05-31",
  "max_tokens": 256,
  "messages": [
    {"role": "user", "content": "How're you today?"}
  ]
}

let (tmpFile, tmpPath) = createTempFile("claude_req_", ".json")
tmpFile.write(encode($body))
tmpFile.close()

let (_, outPath) = createTempFile("claude_res_", ".json")

let (output, exitCode) = execCmdEx(
  "aws bedrock-runtime invoke-model" &
  " --profile softmax" &
  " --model-id " & model &
  " --region " & region &
  " --content-type application/json" &
  " --accept application/json" &
  " --body file://" & tmpPath &
  " " & outPath
)

removeFile(tmpPath)

if exitCode != 0:
  echo "Error: ", output
  removeFile(outPath)
  quit(1)

let response = parseJson(readFile(outPath))
removeFile(outPath)
echo response["content"][0]["text"].getStr()
