## Shared artifact service for the COGAME_*_URI https contract.
##
## Provides upload secret + token handling and the two HTTP handlers
## (upload for replays/results, download for config) so that game and
## player containers can exchange artifacts over https instead of
## bind-mounted file:// paths.
##
## Both games_server and tournament_server initialize this (with their
## own replay dir and will mount the handlers on their own ports) so
## that launched ECS tasks can be given working https URIs pointing
## at the correct server without cross-dependency.

import
  std/[os, strutils, sha1, sysrand]

from mummy import Request, respond

proc parseUrlPairs(s: string): seq[(string, string)] =
  ## Small helper duplicated for the artifact module (original lives in games_server).
  result = @[]
  for part in s.split('&'):
    if part.len == 0: continue
    let eq = part.find('=')
    if eq < 0:
      result.add((part, ""))
    else:
      result.add((part[0 ..< eq], part[eq+1 .. ^1]))

proc queryValue(request: Request, key: string): string =
  ## Reads one query string value.
  let queryStart = request.uri.find('?')
  if queryStart < 0 or queryStart + 1 >= request.uri.len:
    return
  for (queryKey, value) in parseUrlPairs(request.uri[queryStart + 1 .. ^1]):
    if queryKey == key:
      return value

const
  UploadSecretEnv* = "GAMES_SERVER_UPLOAD_SECRET"
  UploadSecretFile* = ".upload_secret"
  UploadSecretBytes* = 32
  ReplayUploadPath* = "/api/replay/upload/"
  ReplayDownloadPath* = "/api/replay/download/"

var
  artifactReplayDir* = ""
  uploadSecretValue* = ""

proc setArtifactReplayDir*(dir: string) =
  ## Sets the base directory used for storing replays, scores, and configs.
  artifactReplayDir = dir

proc replayDir*(): string =
  artifactReplayDir

proc ensureReplayDir*() =
  ## Creates the replay directory when it is missing.
  if artifactReplayDir.len == 0:
    raise newException(IOError, "artifact replay dir not set")
  try:
    createDir(artifactReplayDir)
  except OSError as e:
    raise newException(IOError, "could not create replay directory: " & e.msg)

proc cleanReplayName*(value: string): string =
  ## Keeps only replay file name characters (shared helper).
  for c in value:
    if c.isAlphaNumeric() or c == '_' or c == '-' or c == '.':
      result.add(c)
  if result.len > 128:
    result = result[0 .. 127]

proc replayPath*(name: string): string =
  ## Returns the host path for one replay/config/scores file.
  if artifactReplayDir.len == 0:
    raise newException(IOError, "artifact replay dir not set")
  let clean = cleanReplayName(name)
  artifactReplayDir / clean

proc uploadSecretPath(): string =
  replayDir() / UploadSecretFile

proc generateUploadSecret(): string =
  var bytes: array[UploadSecretBytes, byte]
  if not urandom(bytes):
    raise newException(IOError, "could not generate upload secret")
  for b in bytes:
    result.add(b.toHex(2).toLowerAscii())

proc loadUploadSecret*(): string =
  result = getEnv(UploadSecretEnv).strip()
  if result.len > 0:
    return
  let path = uploadSecretPath()
  ensureReplayDir()
  if fileExists(path):
    result = readFile(path).strip()
    if result.len > 0:
      return
  result = generateUploadSecret()
  try:
    writeFile(path, result & "\n")
  except OSError as e:
    raise newException(IOError, "could not write upload secret: " & e.msg)

proc uploadSecret*(): string =
  if uploadSecretValue.len == 0:
    uploadSecretValue = loadUploadSecret()
  uploadSecretValue

proc sameToken*(a, b: string): bool =
  var diff = a.len xor b.len
  let count = max(a.len, b.len)
  for i in 0 ..< count:
    let
      left = if i < a.len: ord(a[i]) else: 0
      right = if i < b.len: ord(b[i]) else: 0
    diff = diff or (left xor right)
  diff == 0

proc generateUploadToken*(fileName: string): string =
  let clean = cleanReplayName(fileName)
  if clean.len == 0:
    raise newException(IOError, "could not tokenize empty file name")
  ($secureHash(uploadSecret() & "\n" & clean)).toLowerAscii()

proc validateUploadToken*(token, fileName: string): bool =
  if token.len == 0 or fileName.len == 0:
    return false
  sameToken(token.toLowerAscii(), generateUploadToken(fileName))

proc handleUpload*(request: Request, uploadPathPrefix: string): tuple[status: int, headers: seq[(string,string)], body: string] =
  ## Pure handler logic for PUT upload. Returns what the caller should respond with.
  let pathPart = request.path[uploadPathPrefix.len .. ^1]
  let clean = cleanReplayName(pathPart)
  if clean.len == 0:
    return (400, @[("Content-Type", "text/plain")], "bad filename\n")
  let token = request.queryValue("token")
  if not validateUploadToken(token, clean):
    return (403, @[("Content-Type", "text/plain")], "invalid token\n")
  ensureReplayDir()
  writeFile(replayPath(clean), request.body)
  echo "[artifact-upload] ", clean, " (", request.body.len, " bytes)"
  return (200, @[("Content-Type", "application/json")], """{"status":"ok"}""" & "\n")

proc handleDownload*(request: Request, downloadPathPrefix: string): tuple[status: int, headers: seq[(string,string)], body: string] =
  ## Pure handler logic for GET download.
  let name = request.path[downloadPathPrefix.len .. ^1]
  let clean = cleanReplayName(name)
  if clean.len == 0 or not fileExists(replayPath(clean)):
    return (404, @[("Content-Type", "text/plain")], "not found\n")
  let body = readFile(replayPath(clean))
  return (200, @[("Content-Type", "application/octet-stream")], body)
