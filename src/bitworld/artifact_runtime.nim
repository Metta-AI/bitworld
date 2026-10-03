## Native artifact finalization with one caller-owned absolute cleanup deadline.
## Keep this module out of simulation/WASM codecs; inference stop stays irreversible.

import std/[monotimes, options, os]
import native_http, runtime, decision_trajectory

export ArtifactHttpMethod

proc requireArtifactBudget(deadline: MonoTime, source: string) =
  if getMonoTime() >= deadline:
    raise newException(IOError, source & " artifact cleanup deadline exceeded")

proc writeCogameArtifact*(value, data, contentType, source: string,
    cleanupDeadline: MonoTime, httpMethod: ArtifactHttpMethod = ahPut) =
  requireArtifactBudget(cleanupDeadline, source)
  if value.isHttpCogameUri():
    let response = performArtifactUpload(value, httpMethod,
      @[("Content-Type", contentType)], data, cleanupDeadline)
    if response.kind != nhComplete:
      raise newException(IOError, source & " artifact upload " & $response.kind)
    let status = response.httpStatus.get()
    if status < 200 or status >= 300:
      raise newException(IOError, source & " artifact upload failed: " & $status)
  else:
    let path = pathFromCogameUri(value, source)
    let directory = path.parentDir()
    if directory.len > 0:
      createDir(directory)
    writeFile(path, data)
  requireArtifactBudget(cleanupDeadline, source)

proc writeTrajectoryArtifact*(trajectory: DecisionTrajectory, destinationUri: string,
    cleanupDeadline: MonoTime, httpMethod: ArtifactHttpMethod = ahPut) =
  ## The private episode is sealed before its bytes are uploaded or created exclusively.
  requireArtifactBudget(cleanupDeadline, CogameSaveTrajectoryUriEnv)
  if destinationUri.isHttpCogameUri():
    writeCogameArtifact(destinationUri, trajectory.eventsJsonl(),
      "application/x-ndjson", CogameSaveTrajectoryUriEnv, cleanupDeadline, httpMethod)
  else:
    trajectory.writeEvents(pathFromCogameUri(destinationUri, CogameSaveTrajectoryUriEnv))
  requireArtifactBudget(cleanupDeadline, CogameSaveTrajectoryUriEnv)
