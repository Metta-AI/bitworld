switch("path", thisDir() & "/common")

when not defined(debug):
  --define:release
  --define:noAutoGLerrorCheck
