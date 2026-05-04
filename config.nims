import os, strformat, strutils

const RootDir = thisDir()

switch("path", RootDir & "/common")
switch("path", RootDir & "/src")
switch("path", RootDir & "/../mummy/src")
switch("path", RootDir & "/../paddy/src")
switch("path", RootDir & "/../whisky/src")
switch("outdir", thisDir() & "/out")

when defined(emscripten):
  const OutputDir = RootDir / "among_them" / "emscripten"
  if not dirExists(OutputDir):
    mkDir(OutputDir)

  switch("nimcache", OutputDir / "tmp")
  switch("threads", "off")
  --os:linux
  --cpu:wasm32
  --cc:clang
  when defined(windows):
    --clang.exe:emcc.bat
    --clang.linkerexe:emcc.bat
    --clang.cpp.exe:emcc.bat
    --clang.cpp.linkerexe:emcc.bat
  else:
    --clang.exe:emcc
    --clang.linkerexe:emcc
    --clang.cpp.exe:emcc
    --clang.cpp.linkerexe:emcc
  --listCmd

  --gc:arc
  --exceptions:goto
  --define:noSignalHandler
  --debugger:native
  --define:noAutoGLerrorCheck
  --define:release

  switch(
    "passL",
    (&"""
    -o {OutputDir / projectName()}.html
    --preload-file {RootDir / "clients" / "data"}@clients/data
    --preload-file {RootDir / "clients" / "dist"}@clients/dist
    --preload-file {RootDir / "among_them" / "map.json"}@among_them/map.json
    --preload-file {RootDir / "among_them" / "skeld2.aseprite"}@among_them/skeld2.aseprite
    --preload-file {RootDir / "among_them" / "spritesheet.aseprite"}@among_them/spritesheet.aseprite
    --preload-file {RootDir / "among_them" / "ascii.png"}@among_them/ascii.png
    --shell-file {OutputDir / "shell.html"}
    -s ASYNCIFY
    -s FETCH
    -s USE_WEBGL2=1
    -s MAX_WEBGL_VERSION=2
    -s MIN_WEBGL_VERSION=1
    -s FULL_ES3=1
    -s GL_ENABLE_GET_PROC_ADDRESS=1
    -s ALLOW_MEMORY_GROWTH
    """).replace("\n", " ")
  )

  if paramStr(1) == "run" or paramStr(1) == "r":
    setCommand("c")
    echo "To run emscripten, use:"
    echo "emrun " & OutputDir / (projectName() & ".html")
else:
  switch("nimcache", getCurrentDir() & "/nimcache")
  switch("threads", "on")
  switch("mm", "orc")

  when not defined(debug):
    --define:release
    --define:noAutoGLerrorCheck

  # Bots that connect outbound need OpenSSL so they can talk wss://.
  when projectName() == "nottoodumb":
    --define:ssl
