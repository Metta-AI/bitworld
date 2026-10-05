## Native startup input ownership. Keep transport out of runtime/WASM decoders.
import std/[base64, json, monotimes, options, os]
import native_http, native_stop, runtime

type RuntimeInputCapture* = object
  source*, uri*: string
  response*: Option[NativeHttpResponse]
  fileBytes*: string

proc readRuntimeInput*(value, source: string, deadline: MonoTime,
    control: var NativeRequestControl, maxBodyBytes, maxHeaderBytes: int,
    captures: var seq[RuntimeInputCapture]): string =
  ## Capture precedes status/format validation; the HTTP owner has already joined.
  doAssert maxBodyBytes > 0 and maxBodyBytes < int.high and maxHeaderBytes > 0
  if interruptionRequested():
    raise newException(CogameRuntimeError, source & " input interrupted")
  if control.nativeRequestCanceled():
    raise newException(CogameRuntimeError, source & " input canceled")
  if getMonoTime() >= deadline:
    raise newException(CogameRuntimeError, source & " input deadline exceeded")
  if value.isHttpCogameUri():
    let response = performInputGet(value, @[], deadline, control,
      maxBodyBytes, maxHeaderBytes)
    captures.add RuntimeInputCapture(source: source, uri: value, response: some(response))
    if response.kind != nhComplete:
      raise newException(CogameRuntimeError, source & " input " & $response.kind)
    let status = response.httpStatus.get()
    if status < 200 or status >= 300:
      raise newException(CogameRuntimeError, source & " input HTTP status " & $status)
    result = response.bodyBytes
  else:
    let path = pathFromCogameUri(value, source)
    if getFileInfo(path).kind != pcFile:
      raise newException(CogameRuntimeError, source & " input must be a regular file")
    let file = open(path, fmRead)
    try:
      result = newString(maxBodyBytes + 1)
      result.setLen(file.readBuffer(result[0].addr, result.len))
    finally:
      file.close()
    captures.add RuntimeInputCapture(source: source, uri: value, fileBytes: result)
    if result.len > maxBodyBytes:
      raise newException(CogameRuntimeError, source & " input byte limit exceeded")
  if interruptionRequested():
    raise newException(CogameRuntimeError, source & " input interrupted")
  if control.nativeRequestCanceled():
    raise newException(CogameRuntimeError, source & " input canceled")
  if getMonoTime() >= deadline:
    raise newException(CogameRuntimeError, source & " input deadline exceeded")

proc runtimeInputCapturesJson*(captures: openArray[RuntimeInputCapture]): JsonNode =
  ## Private evidence only: source URIs and bytes must never enter public replay/logs.
  result = newJArray()
  for capture in captures:
    var item = %*{"source": capture.source, "uri": capture.uri,
      "file_body_b64": encode(capture.fileBytes), "transport": newJNull()}
    if capture.response.isSome:
      let response = capture.response.get()
      item["file_body_b64"] = newJNull()
      item["transport"] = %*{"kind": $response.kind,
        "http_status": response.httpStatus, "response_body_b64": encode(response.bodyBytes),
        "response_headers_b64": encode(response.headerBytes),
        "response_complete": response.transferComplete,
        "response_reader_joined": response.responseReaderJoined,
        "latency_ms": response.latencyMs, "error": response.error}
    result.add item
