## Modulabot CLI entry point.
##
## Phase 0: parses flags, builds a `Paths` record, runs the (stub) runner,
## exits 0. Phase 1 fills `viewer/runner.nim` with the real connect /
## drain / step / send loop; this entry point doesn't change.
##
## When built as a shared library (`-d:modulabotLibrary`) this module's
## body is unused — `ffi/lib.nim` provides the C-callable entry surface
## instead.

when defined(modulabotLibrary):
  # Library build: import the FFI module so its `{.exportc.}` symbols end
  # up in the shared object. The module's body is itself `when`-gated.
  import ffi/lib
  export lib
else:
  # CLI build: parser, runner, defaults.
  import std/[os, parseopt, strutils]
  import protocol
  import viewer/runner

when isMainModule and not defined(modulabotLibrary):
  var
    address = DefaultHost
    port = DefaultPort
    gui = false
    name = ""
    mapPath = ""
    framesPath = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      of "gui":
        gui = true
      of "name":
        name = val
      of "map":
        mapPath = val
      of "frames":
        framesPath = val
      else:
        discard
    else:
      discard
  if mapPath.len > 0 and not mapPath.isAbsolute():
    mapPath = absolutePath(mapPath)
  if framesPath.len > 0 and not framesPath.isAbsolute():
    framesPath = absolutePath(framesPath)
  runBot(address, port, gui, name, mapPath, framesPath)
