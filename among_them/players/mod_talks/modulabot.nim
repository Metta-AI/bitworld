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
  import types
  import viewer/runner

  proc parseTraceLevel(s: string): TraceLevel =
    case s.toLowerAscii()
    of "off":       tlOff
    of "events":    tlEvents
    of "decisions": tlDecisions
    of "full":      tlFull
    else:           tlDecisions

when isMainModule and not defined(modulabotLibrary):
  var
    address = DefaultHost
    port = DefaultPort
    gui = false
    name = ""
    mapPath = ""
    framesPath = ""
    traceDir = getEnv("MODULABOT_TRACE_DIR")
    traceLevel = parseTraceLevel(getEnv("MODULABOT_TRACE_LEVEL", "decisions"))
    traceSnapshotPeriod = block:
      let s = getEnv("MODULABOT_TRACE_SNAPSHOT_PERIOD", "120")
      try: parseInt(s) except ValueError: 120
    traceMeta = getEnv("MODULABOT_TRACE_META")
    traceFramesDump = block:
      let s = getEnv("MODULABOT_TRACE_FRAMES_DUMP", "1").toLowerAscii()
      s != "0" and s != "false" and s != "off"
    llmMockPath = getEnv("MODTALKS_LLM_MOCK")
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
      of "trace-dir":
        traceDir = val
      of "trace-level":
        traceLevel = parseTraceLevel(val)
      of "trace-snapshot-period":
        traceSnapshotPeriod = parseInt(val)
      of "trace-meta":
        traceMeta = val
      of "trace-frames-dump":
        traceFramesDump = true
      of "no-trace-frames-dump":
        traceFramesDump = false
      of "llm-mock":
        llmMockPath = val
      else:
        discard
    else:
      discard
  if mapPath.len > 0 and not mapPath.isAbsolute():
    mapPath = absolutePath(mapPath)
  if framesPath.len > 0 and not framesPath.isAbsolute():
    framesPath = absolutePath(framesPath)
  if traceDir.len > 0 and not traceDir.isAbsolute():
    traceDir = absolutePath(traceDir)
  if llmMockPath.len > 0 and not llmMockPath.isAbsolute():
    llmMockPath = absolutePath(llmMockPath)
  runBot(address, port, gui, name, mapPath, framesPath,
         traceDir, traceLevel, traceSnapshotPeriod, traceMeta,
         traceFramesDump, llmMockPath)
