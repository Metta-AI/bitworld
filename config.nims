import std/strutils

switch("path", thisDir() & "/common")
let localMummy = thisDir() & "/../mummy/src/mummy.nim"
if fileExists(localMummy) and readFile(localMummy).contains("tcpNoDelay"):
  switch("path", thisDir() & "/../mummy/src")
switch("path", thisDir() & "/../paddy/src")
switch("path", thisDir() & "/../whisky/src")
switch("nimcache", getCurrentDir() & "/nimcache")
switch("threads", "on")
switch("mm", "orc")

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck
