# How to submit an AmongThem bot to the CoGames tournament

Operational guide for shipping an AmongThem policy to the Softmax CoGames
leaderboard. Optimized for an AI coding agent to execute. Sibling of
`how_to_make_a_bot.md`.

If anything in this file disagrees with `cogames --help`, follow `cogames`.
Live CLI is the source of truth.

---

## TL;DR

```bash
# 1. Preflight
cogames auth status        # if not logged in: cogames auth login
cogames season list        # find an AmongThem season name
docker info >/dev/null     # if not running: open -a Docker

# 2. From the bitworld repo root, ship an existing wrapped bot:
SEASON=<season-name> POLICY_NAME=$USER-<botname>-$(date +%Y%m%d-%H%M%S) \
  ./among_them/players/<botname>/cogames/ship.sh dry-run
# ... if dry-run fails ONLY with "Policy took no actions (all no-ops)":
./among_them/players/<botname>/cogames/ship.sh ship-skip-validation

# 3. Watch
cogames submissions --season "$SEASON" --policy "$POLICY_NAME"
cogames leaderboard "$SEASON" --policy "$POLICY_NAME"
```

If shipping a new bot for the first time, follow §3.

---

## 1. Preflight checklist

Before any submission action, all four must be true:

- [ ] **`cogames` on PATH.** `which cogames` returns a path. Installed at
      `~/.local/bin/cogames` if you used the standard installer.
- [ ] **Authenticated.** `cogames auth status` prints `Authenticated`. If
      not, run `cogames auth login` (browser flow at
      `https://softmax.com/cli-login`). Do **not** run `softmax login` or
      `uv run softmax login` — those rely on a separate `softmax-cli`
      package that may not be in your active venv. `cogames auth login`
      calls the same code path. The `cogames auth status` message
      "Run softmax login first" is misleading boilerplate; ignore it.
- [ ] **Active AmongThem season.** `cogames season list` shows a season
      whose description mentions Among Them or BitWorld. As of
      2026-04-30 it is `among-them`. Do **not** ship into `beta-cvc`,
      `beta-teams-tiny-fixed`, or `beta-four-score` — those are different
      games. Verify with `cogames season show <name>`.
- [ ] **Docker daemon running.** `docker info >/dev/null 2>&1`. If not,
      `open -a Docker` (macOS) and wait until `docker info` returns 0.
      Docker is required for `--dry-run` validation; not strictly
      required for `--skip-validation` shipping but install it anyway.

---

## 2. Two submission patterns

CoGames expects a Python class `AmongThemPolicy` subclassing
`mettagrid.policy.policy.MultiAgentPolicy`. There are two ways to satisfy
this contract:

### Pattern A — Pure-Python policy

Use this for ML / scripted policies that live entirely in Python. The
bundle is just one or more `.py` files plus optional weights.

Reference template (generate fresh, do not copy stale ones):

```bash
cogames tutorial make-policy --amongthem -o amongthem_policy.py
```

Edit `_choose_actions(raw_observations) -> np.ndarray`. Return integer
action indices in the BitWorld trainable action set. That's it.

### Pattern B — Nim-backed policy via ctypes

Use this when the bot is implemented in Nim (e.g. `nottoodumb`,
`modulabot`). The Python class is a thin ctypes wrapper that:

1. Builds `lib<bot>.{so,dylib,dll}` at policy init using the bot's
   `build_<bot>.py` helper.
2. Loads it via `ctypes.CDLL`.
3. Routes `step_batch` through `<bot>_step_batch`.

Canonical examples (copy these, do not write from scratch):

* `among_them/players/nottoodumb_policy.py` — the original.
* `among_them/players/modulabot/cogames/amongthem_policy.py` — same
  pattern, lives in a per-bot submission subdir.

Required FFI exports:

```nim
proc <bot>_abi_version*(): cint {.exportc, dynlib.}
proc <bot>_new_policy*(numAgents: cint): cint {.exportc, dynlib.}
proc <bot>_step_batch*(...) {.exportc, dynlib.}
```

ABI versioning is mandatory. Bump both:

* `<bot>_dir/ffi/lib.nim` → `<Bot>AbiVersion` constant
* `<bot>_dir/build_<bot>.py` → `<BOT>_ABI_VERSION` constant

The wrapper must check them at load time and refuse mismatches.
This catches stale binaries before they corrupt a tournament run.

---

## 3. Adding a new Nim-backed bot's submission package

Layout convention:

```
among_them/players/<bot>/
├── ffi/lib.nim                # FFI exports
├── build_<bot>.py             # ABI-versioned build helper
└── cogames/                   # submission packaging
    ├── amongthem_policy.py    # ctypes wrapper, class AmongThemPolicy
    ├── ship.sh                # convenience: dry-run | ship | ship-skip-validation
    └── README.md              # bot-specific notes
```

Steps:

1. Copy `among_them/players/modulabot/cogames/` to
   `among_them/players/<newbot>/cogames/` and substitute every
   `modulabot` → `<newbot>` (case-sensitive, including class/symbol
   names).
2. Add the matching `_abi_version` export and constants. See
   `among_them/players/modulabot/ffi/lib.nim` and `build_modulabot.py`.
3. Build locally: `python3 among_them/players/<newbot>/build_<newbot>.py`.
   Confirm `nm -gU` shows all three exports.
4. Smoke-test the wrapper without `mettagrid` installed by stubbing
   it. See the smoke-test pattern in `cogames/README.md` if needed.
5. Update `ship.sh` `INCLUDES` to list the bot's transitive Nim source
   dependencies (see §4).

---

## 4. Bundle layout — what to ship

`cogames upload` / `cogames ship` accepts `-f <path>` flags. Layout in the
shipped zip is governed by `cogames/cli/submit.py:_bundle_target_for_include`:

* The policy class file (basename matches the module from
  `class=<module>.AmongThemPolicy`) is **flattened to the bundle root**.
* Every other `-f` path **preserves its relative path** from cwd.

So always run `cogames` from the **bitworld repo root**. The provided
`ship.sh` does this automatically.

For a Nim-backed bot, the bundle must include enough Nim source to
rebuild the shared library inside the tournament Docker worker. The
worker has Nim 2.2.6 + nimby pre-installed (see
`packages/cogames/Dockerfile.episode_runner` in the metta repo) but
**does not have your repo**.

Required `-f` arguments for any modulabot-style bot:

```
-f among_them/players/<bot>/cogames/amongthem_policy.py    # policy wrapper, flattened
-f among_them/players/<bot>                                # bot source dir
-f among_them/sim.nim                                      # imported as `../../sim`
-f common                                                  # protocol.nim, server.nim
-f src/bitworld                                            # aseprite.nim
-f nimby.lock                                              # for `nimby sync`
```

If your bot imports additional modules from elsewhere in the repo, add
`-f` entries for those too. Find them with:

```bash
grep -hE "^import " among_them/players/<bot>/*.nim | sort -u
```

`build_<bot>.py` must pass `--path:common --path:src` to `nim c` (don't
rely on `config.nims` being present in the bundle — only files explicitly
included via `-f` end up in the worker).

---

## 5. The 10-step validation gate

`cogames upload --dry-run` and `cogames ship` (without `--skip-validation`)
run the policy in Docker for **exactly 10 steps**
(`cogames/cli/submit.py:_validation_job_spec` hard-codes `max_steps = 10`).
The validator then enforces:

```
non_noop_actions == 0  →  Validation failed
```

This is a problem for perception-based bots (modulabot, nottoodumb, etc.)
that return idle while localizing the camera. They typically need 30–100+
frames before emitting their first directional input. They will reliably
fail the 10-step gate even though they play correctly in real games.

### Decision tree

```
Run: ./ship.sh dry-run

Validation passed?
├─ YES → run: ./ship.sh ship
└─ NO
   ├─ Error: "Policy took no actions (all no-ops)" only?
   │   └─ run: ./ship.sh ship-skip-validation
   │      (this is a known limitation, sanctioned by cogames docs)
   └─ Any other error?
       └─ Fix it. Do NOT skip validation around real bugs.
          Common real failures:
            * Nim build error          → check transitive `-f` includes
            * ABI version mismatch     → rebuild .so, bump constants
            * Import error / Traceback → fix the wrapper
```

`--skip-validation` is **only** appropriate for the no-op-actions failure.
Skipping around an actual exception ships a broken bot to the tournament
where it will fail every match.

---

## 6. Iterating after submission

Matches are asynchronous and may take minutes to hours. Tournament servers
won't queue your bot instantly. Status commands:

```bash
# Has it been picked up?
cogames submissions --season <season> --policy <policy-name>

# Leaderboard score (empty until matches finish)
cogames leaderboard <season> --policy <policy-name>

# Recent matches involving this policy
cogames matches --season <season> --policy <policy-name>
```

If matches start failing in the worker, the failure mode is opaque from
`submissions` alone. Fetch artifacts:

```bash
cogames matches <match-id> --logs
cogames match-artifacts <match-id> logs
cogames match-artifacts <match-id> error-info
```

To re-submit a fix, run `ship.sh` again. The script generates a fresh
timestamped `POLICY_NAME` each invocation so versions don't collide. The
old submission stays on the leaderboard until you `--no-submit` or the
season operator removes it.

---

## 7. Common errors → fixes

Keyed by literal error text or symptom.

| Error / Symptom | Cause | Fix |
|---|---|---|
| `Not authenticated. Run softmax login first.` | No saved token. | `cogames auth login`. Do not run `softmax login`. |
| `error: Failed to spawn: softmax` | `uv run softmax` in a project that doesn't depend on `softmax-cli`. | `cogames auth login` instead. No `uv run`. |
| `Docker not found` / `Docker daemon is not running` | Need Docker for `--dry-run` validation. | macOS: `open -a Docker`; wait for `docker info` to succeed. |
| `Path does not exist: <path>` | `-f` arg references a file not present from cwd. | Run `cogames` from bitworld repo root. Verify the path. |
| `Policy took no actions (all no-ops)` | 10-step validation gate; perception bots can't localize that fast. | Use `--skip-validation`. See §5 decision tree. |
| `Modulabot library ... has ABI version N, expected M` | Stale `.dylib` cached on disk. | Delete `among_them/players/<bot>/lib<bot>.*` and let the wrapper rebuild. |
| `Modulabot library ... does not export an ABI version` | Built before the ABI export was added. | Rebuild from current source. |
| `cannot open file: protocol` (in dry-run Nim build) | Missing transitive Nim source in the bundle. | Add the missing dir to `ship.sh` `INCLUDES`. See §4. |
| `Could not locate modulabot source directory` | Wrapper can't find `build_<bot>.py`. | The `-f among_them/players/<bot>` include is missing or relative paths are off. Run from repo root. |
| `No leaderboard entries for season '<name>'` | Matches haven't completed yet, or season has no finished matches. | Wait. Re-check in 15–30 min. |
| `No matches found in season '<name>'` from `cogames matches` | Same as above, or filter combo returns empty. | Wait, then re-check. Try without `--policy` filter to see all matches. |

---

## 8. Things never to do

* **Never** ship into a non-AmongThem season. Verify with
  `cogames season show <name>`.
* **Never** use `--skip-validation` to bypass real bugs. Only the
  no-op-actions failure mode warrants it.
* **Never** edit `nottoodumb_policy.py` to ship a different bot — it's
  the canonical template. Copy it, rename, then edit.
* **Never** commit a built `lib<bot>.{so,dylib,dll}` to git. They're
  rebuilt on demand and platform-specific.
* **Never** hardcode an absolute path inside `amongthem_policy.py` or
  `build_<bot>.py`. The bundle layout differs from the source layout;
  paths must be resolved relative to `__file__` or by walking parents.
* **Never** trust an old submitted policy after changing the FFI.
  Bump the ABI version on both sides.

---

## 9. Useful references

In this repo:

* `among_them/players/how_to_make_a_bot.md` — writing a new bot.
* `among_them/players/nottoodumb_policy.py` — canonical Pattern B wrapper.
* `among_them/players/modulabot/cogames/` — canonical Pattern B
  submission package.
* `among_them/players/modulabot/cogames/README.md` — modulabot-specific
  notes; also a good starting point for new submission READMEs.

External:

* `https://softmax.com/play.md` — short walkthrough; sometimes lags
  the live CLI. Treat live CLI help as authoritative.
* `cogames docs amongthem_policy` — official walkthrough, lives in the
  CLI itself.
* `cogames tutorial make-policy --amongthem -o <out.py>` — generate a
  fresh starter template.
* `packages/cogames/Dockerfile.episode_runner` (metta repo) — exact
  image the tournament runs. Useful when debugging missing Nim deps or
  toolchain version skew.
