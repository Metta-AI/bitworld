import std/[base64, json, monotimes, options, os, strutils, times]
import bitworld/[artifact_runtime, decision_trajectory, native_http, native_stop, runtime, runtime_input]

var control: NativeRequestControl
let args = commandLineParams()
installNativeStopHandlers()
let deadline = getMonoTime() + initDuration(milliseconds = args[2].parseBiggestInt())
if args[1] == "stop":
  let inference = performNativePost(args[0] & "/inference", @[], "started", deadline, control)
  doAssert inference.kind == nhInterrupted
  echo $(%*{"inference": $inference.kind})
  flushFile(stdout)
if args[1] == "retained":
  var initialThreads = 0
  for entry in walkDir("/proc/self/task"): inc initialThreads
  for index in 0 ..< 8:
    writeCogameUri(args[0], "retained", "application/json", "fixture")
    var captures: seq[RuntimeInputCapture]
    doAssert readRuntimeInput(args[0], "fixture", deadline, control,
      1024, 4096, captures) == "reloaded"
  var finalThreads = 0
  for entry in walkDir("/proc/self/task"): inc finalThreads
  doAssert finalThreads == initialThreads
elif args[1] == "local":
  let trajectory = newDecisionTrajectory("episode", "seed", "fixture", "source-v1", "source")
  trajectory.finish(esTruncated, %*{"reason": "interrupted"}, newJNull())
  requestNativeStop()
  writeTrajectoryArtifact(trajectory, args[0], deadline)
elif args[1] == "writer" or args[1] == "failure":
  writeCogameArtifact(args[0], "private checkpoint", "application/x-ndjson", "fixture", deadline)
elif args[1] == "budget":
  let first = performArtifactUpload(args[0] & "/first", ahPut, @[], "first", deadline)
  doAssert first.kind == nhDeadline
  let second = performArtifactUpload(args[0] & "/second", ahPost, @[], "second", deadline)
  doAssert second.kind == nhDeadline and second.latencyMs.isNone
  echo $(%*{"first": $first.kind, "second": $second.kind})
else:
  let response = performArtifactUpload(args[0] & "/artifact",
    (if args[1] == "post": ahPost else: ahPut), @[("Content-Type", "application/octet-stream")],
    "\x00\xffcheckpoint", deadline)
  if args[1] == "signal-upload": doAssert interruptionRequested()
  echo $(%*{"kind": $response.kind, "status": response.httpStatus.get(),
    "body_b64": encode(response.bodyBytes), "complete": response.transferComplete})
