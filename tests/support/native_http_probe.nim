import std/[base64, json, monotimes, options, os, strutils, times]
import bitworld/[native_http, native_stop]

let args = commandLineParams()
installNativeStopHandlers()
let deadline = getMonoTime() + initDuration(milliseconds = args[1].parseBiggestInt())
let response = performNativePost(args[0], @[("content-type", "application/json")],
  "{\"fixture\":true}", deadline)
doAssert response.responseReaderJoined == some(true)
echo $(%*{"kind": $response.kind, "status": (if response.httpStatus.isSome: %response.httpStatus.get() else: newJNull()),
  "headers_b64": encode(response.headerBytes), "body_b64": encode(response.bodyBytes),
  "complete": response.transferComplete,
  "latency_ms": (if response.latencyMs.isSome: %response.latencyMs.get() else: newJNull())})
if args.len == 3:
  let repeated = performNativePost(args[0], @[("content-type", "application/json")],
    "{\"fixture\":true}", deadline)
  doAssert repeated.kind == response.kind
  doAssert repeated.latencyMs.isNone and repeated.httpStatus.isNone
  doAssert repeated.responseReaderJoined.isNone
  doAssert repeated.bodyBytes.len == 0 and repeated.headerBytes.len == 0
requestNativeStop()
doAssert interruptionRequested()
let stopped = performNativePost(args[0], @[("content-type", "application/json")],
  "{\"fixture\":true}", getMonoTime() + initDuration(seconds = 5))
doAssert stopped.kind == nhInterrupted
doAssert stopped.latencyMs.isNone and stopped.httpStatus.isNone
doAssert stopped.bodyBytes.len == 0 and stopped.headerBytes.len == 0

doAssert stopped.responseReaderJoined.isNone
