## Exhaustiveness check for `tuning_snapshot.nim`.
##
## Enforces the TRACING.md §10.3 "single source of truth" rule: every
## public `const NAME* = ...` in a policy module must appear as a key
## in `tuning_snapshot.nim`, or be explicitly listed in the
## `SnapshotExempt` whitelist below with a one-line reason.
##
## The check is a static scan — no imports from the policy modules
## themselves, so it runs quickly and is safe to invoke from
## `trace_smoke.sh` between build + parity steps.
##
## Exits non-zero (and prints every offender) if any constant is
## declared but neither registered in the snapshot nor exempted.
##
## Usage:
##   nim r tools/check_tuning_snapshot.nim
##
## A new tuning knob must either be wired into
## `tuning_snapshot.nim` or get a line here with a one-line reason
## describing why it's out of scope for the manifest (e.g. "derived
## from PatchSize", "hash seed, not a policy knob", "screen layout
## coordinate, not tunable").

import std/[os, sets, strformat, strutils]

const
  PolicyModules = [
    "tuning.nim",
    "voting.nim",
    "motion.nim",
    "evidence.nim",
    "policy_imp.nim",
    "policy_crew.nim",
    "tasks.nim",
    "actors.nim",
    "path.nim",
    "sprite_match.nim",
    "localize.nim",
    "frame.nim"
  ]

  ## Names that deliberately stay out of the snapshot. Keep each line
  ## commented with the reason — this is the audit trail for future
  ## reviewers wondering why the lint doesn't flag a given constant.
  SnapshotExempt = [
    # evidence.nim
    "PlayerColorNames",     # string table, not a numeric tunable
    # localize.nim
    "PatchGridW",           # derived: ScreenWidth div PatchSize
    "PatchGridH",           # derived: ScreenHeight div PatchSize
    "PatchHashBase",        # FNV-1a prime, not a policy knob
    "PatchHashSeed",        # FNV-1a seed, not a policy knob
    # voting.nim
    "VoteStartY",           # screen layout coord, not tunable
    "VoteSkipW",            # screen layout coord, not tunable
    "VoteBlackMarker",      # pixel value, not a policy knob
    "VoteChatIconX",        # sim-sourced screen coord, not tunable
    "VoteChatSpeakerSearch",  # local OCR-search window; retune lives
                              # with the OCR code, not the harness
    # frame.nim
    "KillIconY"             # screen layout coord (pair of KillIconX);
                            # KillIconX is in the snapshot because the
                            # HUD's x-slot has a documented parity
                            # implication (v2 migration), y does not
  ]

proc loadRegisteredKeys(snapshotPath: string): HashSet[string] =
  ## Returns the set of identifier names referenced on the right of a
  ## `"Name": Name,` entry in `tuning_snapshot.nim`. Both the key and
  ## the reference resolve to the same symbol by convention, so we
  ## accept either side as "registered".
  result = initHashSet[string]()
  if not fileExists(snapshotPath):
    echo &"FAIL: {snapshotPath} not found"
    quit(2)
  for rawLine in lines(snapshotPath):
    let line = rawLine.strip()
    if not line.startsWith("\""):
      continue
    let closeQuote = line.find('"', 1)
    if closeQuote <= 1:
      continue
    let name = line[1 ..< closeQuote]
    if name.len > 0 and name[0] in {'A' .. 'Z'}:
      result.incl(name)

proc collectDeclaredConsts(path: string): seq[tuple[name: string, lineno: int]] =
  ## Returns every `  Name* = value` declaration in a module. Matches
  ## the indentation convention used across modulabot: a single
  ## `const` block indented with two spaces.
  if not fileExists(path):
    return
  var inConst = false
  var lineno = 0
  for rawLine in lines(path):
    inc lineno
    let stripped = rawLine.strip()
    if stripped.startsWith("const"):
      inConst = true
      continue
    if inConst:
      if stripped.len == 0:
        continue
      if not rawLine.startsWith(" "):
        inConst = false
        continue
      if not rawLine.startsWith("  "):
        continue
      # A `const` entry looks like `  Name* = value` or `  Name* =` on
      # its own (multi-line literal). We want just the leading
      # identifier with the `*` export marker.
      let body = rawLine[2 .. ^1]
      if body.len == 0 or body[0] notin {'A' .. 'Z'}:
        continue
      var ident = ""
      for ch in body:
        if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
          ident.add(ch)
        else:
          break
      if ident.len == 0:
        continue
      let rest = body[ident.len .. ^1].strip()
      if not rest.startsWith("* ="):
        continue
      result.add((ident, lineno))

proc main() =
  let repoRoot = currentSourcePath().parentDir().parentDir()
  let snapshotPath = repoRoot / "tuning_snapshot.nim"
  let registered = loadRegisteredKeys(snapshotPath)
  let exempt = toHashSet(@SnapshotExempt)

  var missing: seq[tuple[name, module: string, lineno: int]] = @[]
  for moduleName in PolicyModules:
    let modulePath = repoRoot / moduleName
    for entry in collectDeclaredConsts(modulePath):
      if entry.name in registered:
        continue
      if entry.name in exempt:
        continue
      missing.add((entry.name, moduleName, entry.lineno))

  if missing.len == 0:
    echo "tuning_snapshot lint: OK (",
         registered.len, " registered, ",
         exempt.len, " exempt)"
    return

  echo "tuning_snapshot lint: FAIL"
  for entry in missing:
    echo &"  {entry.module}:{entry.lineno}  {entry.name}"
  echo ""
  echo "Each name above is declared `const NAME* = ...` in a policy"
  echo "module but neither appears in tuning_snapshot.nim nor in the"
  echo "SnapshotExempt whitelist in tools/check_tuning_snapshot.nim."
  echo "Wire it into the snapshot (preferred) or add an exempt entry"
  echo "with a one-line reason."
  quit(1)

when isMainModule:
  main()
