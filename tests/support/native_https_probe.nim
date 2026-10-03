import std/[json, monotimes, options, os, times]
import bitworld/native_http

let args = commandLineParams()
let deadline = getMonoTime() + initDuration(seconds = 3)
let response = if args[1] == "inference":
  performNativePost(args[0], @[], "private fixture", deadline)
else:
  performArtifactUpload(args[0], ahPut, @[], "private fixture", deadline)
echo $(%*{"kind": $response.kind, "complete": response.transferComplete,
  "status": (if response.httpStatus.isSome: %response.httpStatus.get() else: newJNull()),
  "body": response.bodyBytes})
