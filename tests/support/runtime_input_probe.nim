import std/[base64, json, monotimes, options, os, strutils, times]
import bitworld/[native_http, native_stop, runtime_input]

let args = commandLineParams()
installNativeStopHandlers()
var control: NativeRequestControl
if args[1] == "prestop": requestNativeStop()
if args[1] == "precancel": control.cancelNativeRequest()
if args[1] == "presignal":
  echo "installed"
  flushFile(stdout)
  discard stdin.readLine()
let deadline = getMonoTime() + initDuration(milliseconds = args[2].parseInt())
let response = performInputGet(args[0], @[], deadline, control,
  args[3].parseInt(), args[4].parseInt())
var nextKind = "not_requested"
if args[1] == "twice":
  let next = performInputGet(args[0] & "/second", @[], deadline, control,
    args[3].parseInt(), args[4].parseInt())
  doAssert next.latencyMs.isNone
  nextKind = $next.kind
var status = newJNull()
if response.httpStatus.isSome: status = %response.httpStatus.get()
echo $(%*{"kind": $response.kind, "status": status,
  "body_b64": encode(response.bodyBytes), "headers_b64": encode(response.headerBytes),
  "complete": response.transferComplete, "joined": response.responseReaderJoined,
  "next_kind": nextKind})
