## Process-owned stop intent. Signal handlers never allocate, log, or write artifacts.
## The engine observes this flag, joins its work, then seals the private episode.

when not defined(posix):
  {.error: "Native Coworld interruption requires a POSIX runtime.".}

import std/[atomics, posix]

type NativeSignalHandler = proc(number: cint) {.noconv.}

var stopRequested: Atomic[bool]

proc interruptionRequested*(): bool {.inline.} =
  stopRequested.load(moRelaxed)

proc requestNativeStop*() {.inline, gcsafe, raises: [].} =
  ## Owned lifecycle cleanup uses the same irreversible intent as a signal.
  stopRequested.store(true, moRelaxed)

proc requestStop(_: cint) {.noconv, gcsafe, raises: [].} =
  requestNativeStop()

proc setSignalHandler(number: cint, handler: NativeSignalHandler): NativeSignalHandler
    {.importc: "signal", header: "<signal.h>".}

proc atomicAlwaysLockFree(size: csize_t, address: pointer): bool
    {.importc: "__atomic_always_lock_free", nodecl.}

proc installNativeStopHandlers*() =
  ## Call before starting owned threads. Stop intent is irreversible for this process.
  doAssert atomicAlwaysLockFree(csize_t(sizeof(bool)), nil),
    "The native stop flag must be lock-free in a signal handler"
  doAssert setSignalHandler(SIGTERM, requestStop) != cast[NativeSignalHandler](-1)
  doAssert setSignalHandler(SIGINT, requestStop) != cast[NativeSignalHandler](-1)
