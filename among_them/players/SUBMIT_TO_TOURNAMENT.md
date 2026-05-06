# Submitting EvidenceBot v2 to the Among Them Leaderboard

*Last updated: May 6, 2026*

## Prerequisites

- Python 3.12
- `cogames` CLI (`uv pip install cogames`)
- Nim 2.2.4 (auto-installed by the build script if missing)
- Docker (required for `--dry-run` validation)

## 1. Authenticate

```bash
cogames auth login
```

Open the printed URL in a browser and complete the login.

## 2. Build locally (optional smoke test)

```bash
cd bitworld
python among_them/players/build_evidencebot_v2.py
```

This compiles `libevidencebot_v2.dylib` (macOS) / `.so` (Linux) and writes an `.abi` stamp file.

## 3. Find the Among Them season

```bash
cogames season list
```

Look for a season with "Among Them" in the description (currently `among-them`).

## 4. Upload and submit

```bash
cd bitworld

POLICY_NAME="$USER-evidencebot-v2-$(date +%Y%m%d-%H%M%S)"
SEASON=among-them

cogames upload \
  -p class=evidencebot_v2_policy.EvidenceBotV2NimPolicy \
  -f among_them/players/evidencebot_v2_policy.py \
  -f among_them/players/build_evidencebot_v2.py \
  -f among_them/players/evidencebot_v2.nim \
  -f among_them/sim.nim \
  -f common \
  -f src/bitworld \
  -f nimby.lock \
  -n "$POLICY_NAME" \
  --season "$SEASON"
```

If Docker validation fails due to infrastructure issues (server crash, not a policy error), add `--skip-validation`:

```bash
cogames upload \
  -p class=evidencebot_v2_policy.EvidenceBotV2NimPolicy \
  -f among_them/players/evidencebot_v2_policy.py \
  -f among_them/players/build_evidencebot_v2.py \
  -f among_them/players/evidencebot_v2.nim \
  -f among_them/sim.nim \
  -f common \
  -f src/bitworld \
  -f nimby.lock \
  -n "$POLICY_NAME" \
  --season "$SEASON" \
  --skip-validation
```

## 5. Check submission status

```bash
cogames submissions --season "$SEASON" --policy "$POLICY_NAME"
cogames leaderboard "$SEASON"
```

## Dry-run validation (no upload)

Add `--dry-run` to test the bundle in Docker without uploading:

```bash
cogames upload \
  -p class=evidencebot_v2_policy.EvidenceBotV2NimPolicy \
  -f among_them/players/evidencebot_v2_policy.py \
  -f among_them/players/build_evidencebot_v2.py \
  -f among_them/players/evidencebot_v2.nim \
  -f among_them/sim.nim \
  -f common \
  -f src/bitworld \
  -f nimby.lock \
  -n "$POLICY_NAME" \
  --season "$SEASON" \
  --dry-run
```

## Bundle contents

The `-f` flags tell the tournament worker which files to include. The worker compiles the Nim library from source inside Docker -- do **not** include built artifacts (`.dylib`, `.so`, `.dll`, `.abi`, `.out`).

| File | Purpose |
|------|---------|
| `among_them/players/evidencebot_v2_policy.py` | Python policy class (`EvidenceBotV2NimPolicy`) |
| `among_them/players/build_evidencebot_v2.py` | Build script: installs Nim, compiles the shared library |
| `among_them/players/evidencebot_v2.nim` | Nim bot source (localization, tasks, voting, imposter play) |
| `among_them/sim.nim` | Among Them simulation types and logic |
| `common` | Shared Nim modules (`protocol.nim`, `server.nim`) |
| `src/bitworld` | BitWorld engine modules (`aseprite.nim`, `clients.nim`) |
| `nimby.lock` | Nim dependency lock file |

If you split the bot into submodules under `among_them/players/evidencebot_v2/`, add that directory to the bundle:

```
-f among_them/players/evidencebot_v2
```

## Creating a variant

Copy the three files instead of editing in place:

```bash
BOT=my_variant

cp among_them/players/evidencebot_v2.nim        among_them/players/${BOT}.nim
cp among_them/players/build_evidencebot_v2.py   among_them/players/build_${BOT}.py
cp among_them/players/evidencebot_v2_policy.py  among_them/players/${BOT}_policy.py
```

Then rename in each file:
- **Nim:** FFI exports `evidencebot_v2_abi_version`, `evidencebot_v2_new_policy`, `evidencebot_v2_step_batch` to `${BOT}_*`
- **Build:** `EVIDENCEBOT_V2_ABI_VERSION` constant, `build_evidencebot_v2()` function, library output name
- **Policy:** import paths, class name, `short_names`, FFI symbol references, `AmongThemPolicy` alias

## ABI versioning

`EVIDENCEBOT_V2_ABI_VERSION` in `build_evidencebot_v2.py` must match the value returned by `evidencebot_v2_abi_version()` in the Nim source. Bump both when the FFI signature or observation contract changes.
