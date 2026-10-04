import std/[json, monotimes, os, times]
import bitworld/[decision_trajectory, native_http, native_stop, runtime, runtime_input]

installNativeStopHandlers()
var control: NativeRequestControl
var captures: seq[RuntimeInputCapture]
let deadline = getMonoTime() + initDuration(seconds = 2)
proc input(value, source: string): string =
  readRuntimeInput(value, source, deadline, control, 4096, 4096, captures)

try:
  let config = readRuntimeConfig(input)
  discard parseJson(config.config)
  echo "runtime config accepted"
finally:
  writePrivate(getEnv("INPUT_PRIVATE_CAPTURE"), $runtimeInputCapturesJson(captures))
