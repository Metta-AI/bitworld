# Modulabot — CoGames AmongThem submission package

This directory packages the Nim modulabot for the Softmax CoGames AmongThem
tournament. It is a thin wrapper, not a fork: the bot's source-of-truth lives
one directory up at `among_them/players/modulabot/`.

## Layout

```
among_them/players/modulabot/cogames/
├── amongthem_policy.py   # ctypes wrapper, class AmongThemPolicy
├── ship.sh               # convenience: dry-run then ship
└── README.md             # this file
```

## How it works

`amongthem_policy.AmongThemPolicy` is the class the tournament worker loads.
At init it:

1. Locates the `modulabot/` source tree (handles both the in-repo source
   layout and the flattened layout `cogames ship` produces).
2. Imports `build_modulabot.py` directly via `importlib` (the repo has no
   `__init__.py` files, so package imports won't work).
3. Compiles `libmodulabot.{dylib,so,dll}` if the cached binary is missing
   or its ABI stamp doesn't match `MODULABOT_ABI_VERSION`.
4. Loads the library through `ctypes` and routes the BitWorld AmongThem
   `step_batch` interface to `modulabot_step_batch`.

The tournament Docker image (see
`packages/cogames/Dockerfile.episode_runner` in the metta repo) ships with
Nim 2.2.6 + nimby pre-installed, so the build runs inside the worker without
any cross-compilation.

## Pre-flight checklist

Before shipping:

- [ ] An AmongThem season is listed in `cogames season list`. As of the most
      recent check only `beta-cvc` and `beta-teams-tiny-fixed` were live —
      *those are not AmongThem*. Wait for `among-them` (or whatever the
      operators name it) before submitting.
- [ ] Authenticated: `cogames auth status` reports a logged-in user. If not,
      run `cogames auth login` (opens a browser at `https://softmax.com/cli-login`).
      Note: `cogames auth status` may instruct you to "Run softmax login first" —
      that's a misleading message from the underlying `softmax-cli` package.
      `cogames auth login` calls the same code path and is the only command
      you need; you do **not** need a separate `softmax` binary or `uv run softmax`.
- [ ] Docker daemon running (the `--dry-run` validation runs locally in the
      same image the tournament uses).
- [ ] Modulabot smoke-tested against a local AmongThem server. Validation
      catches crashes, not bad behavior.

## Validate (no upload)

Run from the bitworld repo root so relative `-f` paths resolve correctly:

```bash
cd /Users/jamesboggs/coding/bitworld

POLICY_NAME="$USER-modulabot-$(date +%Y%m%d-%H%M%S)"
SEASON=<actual-amongthem-season-name>

cogames upload \
  -p class=amongthem_policy.AmongThemPolicy \
  -f among_them/players/modulabot/cogames/amongthem_policy.py \
  -f among_them/players/modulabot \
  -f among_them/sim.nim \
  -f common \
  -f src/bitworld \
  -f nimby.lock \
  -n "$POLICY_NAME" \
  --season "$SEASON" \
  --dry-run
```

The `among_them/sim.nim`, `common/`, and `src/bitworld/` includes are
modulabot's transitive Nim source dependencies — `build_modulabot.py`
needs them on disk to compile.

Expected result: `Policy validated successfully` after a brief AmongThem
episode runs in Docker.

## Ship (upload + submit)

Same command without `--dry-run`, or use `cogames ship`:

```bash
cogames ship \
  -p class=amongthem_policy.AmongThemPolicy \
  -f among_them/players/modulabot/cogames/amongthem_policy.py \
  -f among_them/players/modulabot \
  -f among_them/sim.nim \
  -f common \
  -f src/bitworld \
  -f nimby.lock \
  -n "$POLICY_NAME" \
  --season "$SEASON"
```

Or use the convenience wrapper:

```bash
SEASON=<season> POLICY_NAME=<name> ./among_them/players/modulabot/cogames/ship.sh ship
```

## Watch it score

```bash
cogames submissions --season "$SEASON" --policy "$POLICY_NAME"
cogames leaderboard "$SEASON" --policy "$POLICY_NAME"
cogames matches --season "$SEASON" --policy "$POLICY_NAME"
```

Matches are asynchronous — scores can take minutes to hours to appear.

## Bumping the ABI version

Change the FFI surface of `libmodulabot` (signatures, action table, exports)
→ bump **both**:

* `among_them/players/modulabot/ffi/lib.nim` → `ModulabotAbiVersion`
* `among_them/players/modulabot/build_modulabot.py` → `MODULABOT_ABI_VERSION`

The Python wrapper checks them against each other at load time and refuses
mismatches. This prevents shipping a stale `.dylib` that disagrees with the
Python signatures.

## Troubleshooting

* **`Could not locate modulabot source directory`** — you ran cogames from
  the wrong cwd or didn't pass `-f among_them/players/modulabot`.
* **`Modulabot library ... does not export an ABI version`** — the Nim build
  pre-dates the ABI change. Rebuild from a clean checkout.
* **`Modulabot library ... has ABI version N, expected M`** — the cached
  `.dylib` is stale. Delete `among_them/players/modulabot/libmodulabot.*`
  and let the wrapper rebuild.
* **Docker validation fails on Nim build** — check that `nimby.lock` made it
  into the bundle (`-f nimby.lock` from repo root).
* **Validation passes but tournament matches fail** — fetch artifacts:

  ```bash
  cogames matches <match-id> --logs
  cogames match-artifacts <match-id> logs
  cogames match-artifacts <match-id> error-info
  ```
