import std/osproc, std/json, std/os, std/tempfiles, std/base64

const
  model = "us.anthropic.claude-sonnet-4-6"
  region = "us-east-1"

proc ask*(prompt: string): string =
  let body = %*{
    "anthropic_version": "bedrock-2023-05-31",
    "max_tokens": 256,
    "messages": [
      {"role": "user", "content": prompt}
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
    removeFile(outPath)
    raise newException(IOError, "Claude API call failed: " & output)

  let response = parseJson(readFile(outPath))
  removeFile(outPath)
  result = response["content"][0]["text"].getStr()
