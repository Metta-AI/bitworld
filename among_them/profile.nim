const
  ProfileTracePath* {.strdefine.} = ""
  ProfileTicks* {.intdefine.} = 100

when ProfileTracePath.len > 0:
  import
    std/os,
    fluffy/measure

  export measure

  var
    profileStarted = false
    profileDumped = false

  proc ensureProfileDir() =
    ## Creates the parent directory for the profile trace if needed.
    let dir = ProfileTracePath.parentDir()
    if dir.len > 0:
      createDir(dir)

  proc profileEnabled*(): bool =
    ## Returns true when Fluffy profiling is compiled in.
    true

  proc startProfileTrace*() =
    ## Starts the Fluffy trace capture once.
    if profileStarted:
      return
    profileStarted = true
    ensureProfileDir()
    echo "Profile trace enabled: ", ProfileTracePath
    echo "Profile ticks: ", ProfileTicks
    startTrace()

  proc finishProfileTrace*() =
    ## Stops and writes the Fluffy trace capture once.
    if not profileStarted or profileDumped:
      return
    profileDumped = true
    endTrace()
    ensureProfileDir()
    dumpMeasures(ProfileTracePath)

  proc profileShouldDump*(gameTicks: int): bool =
    ## Returns true when the configured profile tick budget has elapsed.
    ProfileTicks > 0 and gameTicks >= ProfileTicks and not profileDumped

  template profileBlock*(name: string, body: untyped) =
    ## Measures a named block while profiling is enabled.
    measurePush(name)
    try:
      body
    finally:
      measurePop()
else:
  macro measure*(fn: untyped): untyped =
    ## Leaves a measured proc unchanged when profiling is disabled.
    fn

  proc profileEnabled*(): bool =
    ## Returns true when Fluffy profiling is compiled in.
    false

  proc startProfileTrace*() =
    ## Starts the Fluffy trace capture once.
    discard

  proc finishProfileTrace*() =
    ## Stops and writes the Fluffy trace capture once.
    discard

  proc profileShouldDump*(gameTicks: int): bool =
    ## Returns true when the configured profile tick budget has elapsed.
    false

  template profileBlock*(name: string, body: untyped) =
    ## Leaves a measured block unchanged when profiling is disabled.
    body
