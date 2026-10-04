## A synchronous, owned native HTTP request with an absolute monotonic deadline.
## No provider parsing or game acceptance occurs here. All received bytes survive
## timeout/interruption; the handle is cleaned before the result can be sealed.

import std/[atomics, monotimes, options, os, posix, times]
import libcurl except Option
import webby/httpheaders
import native_stop

export httpheaders

type
  ArtifactHttpMethod* = enum
    ahPut = "PUT", ahPost = "POST"
  RequestPurpose = enum
    rpInference, rpInput, rpArtifact
  NativeHttpKind* = enum
    nhComplete, nhDeadline, nhInterrupted, nhCanceled, nhTransportFailure, nhLimitExceeded
  NativeRequestControl* = object
    canceled: Atomic[bool]
  NativeHttpResponse* = object
    kind*: NativeHttpKind
    httpStatus*: Option[int]
    headerBytes*, bodyBytes*: string
    transferComplete*: bool
    responseReaderJoined*: Option[bool]
    latencyMs*: Option[float]
    error*: string
  Transfer = object
    deadline: MonoTime
    purpose: RequestPurpose
    control: ptr NativeRequestControl
    headerBytes, bodyBytes: string
    maxHeaderBytes, maxBodyBytes: int
    limitExceeded: bool

# The pinned Nim binding omits these existing libcurl options.
const
  OptTimeoutMs = cast[libcurl.Option](155)
  OptConnectTimeoutMs = cast[libcurl.Option](156)
  OptProtocols = cast[libcurl.Option](181)
  OptXferInfoFunction = cast[libcurl.Option](20219)

proc cancelNativeRequest*(control: var NativeRequestControl) {.inline, gcsafe, raises: [].} =
  ## Irreversible for this request only; the owner retains it until its worker joins.
  control.canceled.store(true, moRelaxed)

proc nativeRequestCanceled*(control: var NativeRequestControl): bool {.inline, gcsafe, raises: [].} =
  control.canceled.load(moRelaxed)

proc requireCurl(code: Code) =
  if code != E_OK:
    raise newException(Defect, $easy_strerror(code))

block:
  requireCurl(global_init(GLOBAL_DEFAULT))
  doAssert (version_info(VERSION_NOW).features and VERSION_ASYNCHDNS) != 0,
    "An asynchronous DNS resolver is required for absolute native request deadlines"

proc receiveHeaders(buffer: cstring, size, count: int, context: pointer): int {.cdecl.} =
  let transfer = cast[ptr Transfer](context)
  result = size * count
  let offset = transfer.headerBytes.len
  if result > transfer.maxHeaderBytes - offset:
    let retained = transfer.maxHeaderBytes - offset
    transfer.headerBytes.setLen(offset + retained)
    if retained > 0: copyMem(transfer.headerBytes[offset].addr, buffer, retained)
    transfer.limitExceeded = true
    return 0
  transfer.headerBytes.setLen(offset + result)
  if result > 0: copyMem(transfer.headerBytes[offset].addr, buffer, result)

proc receiveBody(buffer: cstring, size, count: int, context: pointer): int {.cdecl.} =
  let transfer = cast[ptr Transfer](context)
  result = size * count
  let offset = transfer.bodyBytes.len
  if result > transfer.maxBodyBytes - offset:
    let retained = transfer.maxBodyBytes - offset
    transfer.bodyBytes.setLen(offset + retained)
    if retained > 0: copyMem(transfer.bodyBytes[offset].addr, buffer, retained)
    transfer.limitExceeded = true
    return 0
  transfer.bodyBytes.setLen(offset + result)
  if result > 0: copyMem(transfer.bodyBytes[offset].addr, buffer, result)

proc checkTransfer(context: pointer, downloadTotal, downloaded,
    uploadTotal, uploaded: int64): cint {.cdecl.} =
  let transfer = cast[ptr Transfer](context)
  if (transfer.purpose != rpArtifact and
      (interruptionRequested() or transfer.control[].nativeRequestCanceled())) or
      getMonoTime() >= transfer.deadline: 1 else: 0

proc performOwnedRequest(url: string, httpMethod: string,
    headers: HttpHeaders, body: string, deadline: MonoTime,
    purpose: RequestPurpose, control: var NativeRequestControl,
    maxBodyBytes, maxHeaderBytes: int): NativeHttpResponse =
  if purpose != rpArtifact and interruptionRequested():
    result.kind = nhInterrupted
    return
  if purpose != rpArtifact and control.nativeRequestCanceled():
    result.kind = nhCanceled
    return
  let remaining = (deadline - getMonoTime()).inNanoseconds
  if remaining <= 0:
    result.kind = nhDeadline
    return

  let handle = easy_init()
  doAssert handle != nil, "Cannot allocate native HTTP handle"
  var headerList: Pslist
  var transfer = Transfer(deadline: deadline, purpose: purpose, control: control.addr,
    maxBodyBytes: maxBodyBytes, maxHeaderBytes: maxHeaderBytes)
  var oldMask, pipeMask, previousPending: Sigset
  doAssert sigemptyset(pipeMask) == 0
  doAssert sigaddset(pipeMask, SIGPIPE) == 0
  doAssert sigpending(previousPending) == 0
  let pipeWasPending = sigismember(previousPending, SIGPIPE) != 0
  doAssert pthread_sigmask(SIG_BLOCK, pipeMask, oldMask) == 0

  try:
    for (name, value) in headers:
      let appended = slist_append(headerList, (name & ": " & value).cstring)
      doAssert appended != nil, "Cannot allocate native HTTP headers"
      headerList = appended
    requireCurl(handle.easy_setopt(OPT_URL, url.cstring))
    requireCurl(handle.easy_setopt(OPT_CUSTOMREQUEST, httpMethod.cstring))
    if httpMethod != "GET":
      requireCurl(handle.easy_setopt(OPT_POSTFIELDS, body.cstring))
      requireCurl(handle.easy_setopt(OPT_POSTFIELDSIZE, clong(body.len)))
    requireCurl(handle.easy_setopt(OPT_HTTPHEADER, headerList))
    requireCurl(handle.easy_setopt(OPT_FOLLOWLOCATION, clong(0)))
    requireCurl(handle.easy_setopt(OptProtocols, clong(3))) # HTTP and HTTPS only.
    requireCurl(handle.easy_setopt(OPT_NOSIGNAL, clong(1)))
    if existsEnv("SSL_CERT_FILE"):
      requireCurl(handle.easy_setopt(OPT_CAINFO, getEnv("SSL_CERT_FILE").cstring))
    requireCurl(handle.easy_setopt(OPT_HEADERDATA, transfer.addr))
    requireCurl(handle.easy_setopt(OPT_HEADERFUNCTION, receiveHeaders))
    requireCurl(handle.easy_setopt(OPT_WRITEDATA, transfer.addr))
    requireCurl(handle.easy_setopt(OPT_WRITEFUNCTION, receiveBody))
    requireCurl(handle.easy_setopt(OPT_PROGRESSDATA, transfer.addr))
    requireCurl(handle.easy_setopt(OPT_NOPROGRESS, clong(0)))
    requireCurl(handle.easy_setopt(OptXferInfoFunction, checkTransfer))
    let started = getMonoTime()
    let finalRemaining = (deadline - started).inNanoseconds
    if finalRemaining <= 0 or (purpose != rpArtifact and
        (interruptionRequested() or control.nativeRequestCanceled())):
      result.kind = if purpose != rpArtifact and interruptionRequested(): nhInterrupted
        elif purpose != rpArtifact and control.nativeRequestCanceled(): nhCanceled
        else: nhDeadline
      return
    let milliseconds = clong((finalRemaining + 999_999) div 1_000_000)
    requireCurl(handle.easy_setopt(OptTimeoutMs, milliseconds))
    requireCurl(handle.easy_setopt(OptConnectTimeoutMs, milliseconds))
    let code = handle.easy_perform()
    result.transferComplete = code == E_OK
    result.latencyMs = some(float((getMonoTime() - started).inNanoseconds) / 1_000_000)
    var status: clong
    requireCurl(handle.easy_getinfo(INFO_RESPONSE_CODE, status.addr))
    if status != 0: result.httpStatus = some(int(status))
    if purpose != rpArtifact and interruptionRequested(): result.kind = nhInterrupted
    elif purpose != rpArtifact and control.nativeRequestCanceled(): result.kind = nhCanceled
    elif transfer.limitExceeded: result.kind = nhLimitExceeded
    elif code == E_OPERATION_TIMEOUTED or getMonoTime() >= deadline: result.kind = nhDeadline
    elif code == E_OK: result.kind = nhComplete
    else: result.kind = nhTransportFailure
    if code != E_OK: result.error = $easy_strerror(code)
  finally:
    easy_cleanup(handle)
    slist_free_all(headerList)
    if not pipeWasPending:
      var pending: Sigset
      doAssert sigpending(pending) == 0
      if sigismember(pending, SIGPIPE) > 0:
        var received: cint
        doAssert sigwait(pipeMask, received) == 0
    var discardedMask: Sigset
    doAssert pthread_sigmask(SIG_SETMASK, oldMask, discardedMask) == 0
  if purpose != rpArtifact and interruptionRequested(): result.kind = nhInterrupted
  elif purpose != rpArtifact and control.nativeRequestCanceled(): result.kind = nhCanceled
  elif getMonoTime() >= deadline: result.kind = nhDeadline
  result.headerBytes = move transfer.headerBytes
  result.bodyBytes = move transfer.bodyBytes
  result.responseReaderJoined = some(true)

proc performNativePost*(url: string, headers: HttpHeaders, body: string,
    deadline: MonoTime, control: var NativeRequestControl): NativeHttpResponse =
  ## A caller shares one deadline across retries. Never reset it per attempt.
  performOwnedRequest(url, "POST", headers, body, deadline, rpInference, control,
    int.high, int.high)

proc performArtifactUpload*(url: string, httpMethod: ArtifactHttpMethod,
    headers: HttpHeaders, body: string, cleanupDeadline: MonoTime): NativeHttpResponse =
  ## Checkpoint finalization has its own finite cleanup lifetime after inference stops.
  ## No caller can disable interruption in the inference API.
  var control: NativeRequestControl
  performOwnedRequest(url, $httpMethod, headers, body, cleanupDeadline, rpArtifact, control,
    int.high, int.high)

proc performInputGet*(url: string, headers: HttpHeaders, deadline: MonoTime,
    control: var NativeRequestControl, maxBodyBytes, maxHeaderBytes: int): NativeHttpResponse =
  ## Startup input has one owner/deadline and never follows a redirect to a new URI.
  doAssert maxBodyBytes > 0 and maxHeaderBytes > 0
  performOwnedRequest(url, "GET", headers, "", deadline, rpInput, control,
    maxBodyBytes, maxHeaderBytes)
