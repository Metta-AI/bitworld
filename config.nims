switch("path", thisDir() & "/common")
switch("path", thisDir() & "/../mummy/src")
switch("path", thisDir() & "/../paddy/src")
switch("path", thisDir() & "/../whisky/src")
switch("nimcache", getCurrentDir() & "/nimcache")
switch("threads", "on")
switch("mm", "orc")

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck
