## Parent admits cancellation only after the real HTTP fixture receives a request.
import std/[base64, json, monotimes, options, os, times]
import bitworld/[native_http, native_stop]

type OwnedRequest = object
  control: NativeRequestControl
  deadline: MonoTime
  url: cstring
  responseBytes: pointer
  responseLen: int

proc request(job: ptr OwnedRequest) {.thread.} =
  let response = performNativePost($job.url, @[], "first", job.deadline, job.control)
  let resultBytes = $(%*{"kind": $response.kind,
    "status": response.httpStatus, "headers_b64": encode(response.headerBytes),
    "body_b64": encode(response.bodyBytes), "complete": response.transferComplete,
    "reader_joined": response.responseReaderJoined})
  job.responseLen = resultBytes.len
  job.responseBytes = allocShared(resultBytes.len)
  doAssert job.responseBytes != nil
  copyMem(job.responseBytes, resultBytes[0].unsafeAddr, resultBytes.len)

let url = commandLineParams()[0]
installNativeStopHandlers()
let deadline = getMonoTime() + initDuration(seconds = 5)
var job = OwnedRequest(deadline: deadline, url: url.cstring)
var worker: Thread[ptr OwnedRequest]
var joined = false
createThread(worker, request, job.addr)
try:
  doAssert stdin.readLine() == "cancel"
  cancelNativeRequest(job.control)
  joinThread(worker)
  joined = true
  var bytes = newString(job.responseLen)
  copyMem(bytes[0].addr, job.responseBytes, bytes.len)
  let canceled = parseJson(bytes)
  doAssert canceled["kind"].getStr() == "nhCanceled"
  doAssert canceled["reader_joined"].getBool()
  doAssert not interruptionRequested()
  let repeated = performNativePost(url, @[], "not admitted", deadline, job.control)
  doAssert repeated.kind == nhCanceled and repeated.httpStatus.isNone
  doAssert repeated.responseReaderJoined.isNone
  var nextControl: NativeRequestControl
  let next = performNativePost(url, @[], "second", deadline, nextControl)
  doAssert next.kind == nhComplete and next.responseReaderJoined == some(true)
  doAssert next.bodyBytes == "\x00\xffok"
  requestNativeStop()
  var stoppedControl: NativeRequestControl
  let stopped = performNativePost(url, @[], "not admitted", deadline, stoppedControl)
  doAssert stopped.kind == nhInterrupted and stopped.httpStatus.isNone
  echo $(%*{"canceled": canceled, "later_call_complete": true,
    "original_deadline_retained": true, "global_stop_blocks_fresh_control": true})
finally:
  if not joined:
    cancelNativeRequest(job.control)
    joinThread(worker)
  if job.responseBytes != nil: deallocShared(job.responseBytes)
