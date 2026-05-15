when defined(profileTracePath):
  import
    std/os,
    fluffy/measure

  export measure
else:
  macro measure*(fn: untyped): untyped =
    ## Passes procedures through unchanged when profiling is off.
    fn

const
  ProfileTracePath* {.strdefine.} = ""
  ProfileTicks* {.intdefine.} = 100

when defined(profileTracePath):
  var profileTraceDumped: bool

proc profileTraceEnabled*(): bool =
  ## Returns true when the Fluffy trace build is enabled.
  when defined(profileTracePath):
    ProfileTracePath.len > 0
  else:
    false

proc startProfileTrace*() =
  ## Starts Fluffy tracing when a trace output path is configured.
  when defined(profileTracePath):
    if ProfileTracePath.len > 0:
      startTrace()

proc profileTraceTickReached*(tickCount: int): bool =
  ## Returns true when the configured profile tick limit was reached.
  when defined(profileTracePath):
    ProfileTracePath.len > 0 and ProfileTicks > 0 and tickCount >= ProfileTicks
  else:
    false

proc dumpProfileTrace*() =
  ## Dumps the Fluffy trace once when profiling is enabled.
  when defined(profileTracePath):
    if ProfileTracePath.len == 0 or profileTraceDumped:
      return
    profileTraceDumped = true
    endTrace()
    let dir = ProfileTracePath.parentDir()
    if dir.len > 0:
      createDir(dir)
    dumpMeasures(ProfileTracePath)
