"""Cogames bundle packaging helper for SDK submissions.

Why this exists
---------------

Cogames calls ``SDKPolicy.__init__(policy_env_info, device)`` — there's no
seam to pass ``instructions=`` or ``cognitive={...}``. So the SDK ships a
JSON config file alongside the policy module. This script writes that
file in the right location and prints the exact ``cogames upload``
command an SDK user should run.

Usage
-----

::

    # 1. From a JSON config you wrote by hand:
    python -m among_them_sdk.package \\
        --config-json my_directives.json \\
        --policy-name "$USER-sdk-aggressive-imposter"

    # 2. From a Python script that builds an Agent locally (the recommended
    #    flow): the script must define a top-level ``agent = Agent.create(...)``
    #    or expose a ``build()`` callable returning an Agent.
    python -m among_them_sdk.package \\
        --from-agent examples/personas.py:aggressive_imposter \\
        --policy-name "$USER-sdk-aggressive-imposter"

    # 3. Inline:
    python -m among_them_sdk.package \\
        --instructions "Report bodies aggressively. Trust no one." \\
        --cognitive suspicion_threshold=0.7 \\
        --policy-name "$USER-sdk-paranoid"

What it produces
----------------

* ``among_them/sdk/src/among_them_sdk/policy/among_them_sdk_config.json``
  — the bundle config. Cogames flattens this into the bundle root next
  to ``cogames.py`` at upload time.
* A ``cogames upload`` command (printed to stdout, not executed) with
  every ``-f`` flag the validator needs.

Local users who don't want to submit can read the printed JSON and the
upload command, then iterate locally with ``LiveGame`` against the same
:class:`SDKPolicy` semantics (see ``examples/eight_player_game.py``).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import sys
from pathlib import Path
from typing import Any

from .cogames_config import (
    CONFIG_FILENAME,
    CogamesBundleConfig,
    ModuleSpec,
    write_config,
)

THIS_FILE = Path(__file__).resolve()
SDK_SRC_DIR = THIS_FILE.parent  # among_them/sdk/src/among_them_sdk
SDK_DIR = SDK_SRC_DIR.parent.parent
REPO_ROOT = SDK_DIR.parents[1]
POLICY_DIR = SDK_SRC_DIR / "policy"

# Files the cogames validator needs in the bundle. Order mirrors
# `among_them/players/SUBMIT_TO_TOURNAMENT.md` for review-friendliness.
DEFAULT_BUNDLE_FILES: tuple[str, ...] = (
    "among_them/players/evidencebot_v2_policy.py",
    "among_them/players/build_evidencebot_v2.py",
    "among_them/players/evidencebot_v2.nim",
    "among_them/players/evidencebot_v2",
    "among_them/sim.nim",
    "among_them/votereader.nim",
    "common",
    "src/bitworld",
    "nimby.lock",
    "among_them/sdk/src/among_them_sdk",
    "among_them/sdk/pyproject.toml",
)


def _parse_kv_list(raw: list[str] | None) -> dict[str, Any]:
    """Parse ``--cognitive key=value`` pairs into a dict, coercing scalars."""
    out: dict[str, Any] = {}
    if not raw:
        return out
    for item in raw:
        if "=" not in item:
            raise SystemExit(f"--cognitive expects key=value, got {item!r}")
        k, v = item.split("=", 1)
        k = k.strip()
        v = v.strip()
        # naive coercion
        if v.lower() in {"true", "false"}:
            out[k] = v.lower() == "true"
            continue
        try:
            out[k] = int(v)
            continue
        except ValueError:
            pass
        try:
            out[k] = float(v)
            continue
        except ValueError:
            pass
        out[k] = v
    return out


def _parse_module_spec(raw: list[str] | None) -> dict[str, ModuleSpec]:
    """Parse ``--module slot=type[:k=v[,k=v]*]`` into a ``modules`` dict."""
    out: dict[str, ModuleSpec] = {}
    if not raw:
        return out
    for item in raw:
        if "=" not in item:
            raise SystemExit(
                f"--module expects slot=type[:k=v,...], got {item!r}"
            )
        slot, body = item.split("=", 1)
        slot = slot.strip()
        kind, _, params_blob = body.partition(":")
        kind = kind.strip() or "scripted"
        params: dict[str, Any] = {}
        if params_blob:
            for kv in params_blob.split(","):
                if "=" not in kv:
                    raise SystemExit(
                        f"--module params expect k=v, got {kv!r} in {item!r}"
                    )
                k, v = kv.split("=", 1)
                params[k.strip()] = _parse_kv_list([f"x={v.strip()}"])["x"]
        out[slot] = ModuleSpec(type=kind, params=params)
    return out


def _config_from_agent(target: str) -> CogamesBundleConfig:
    """Import ``module:attr`` and read directives + modules from an Agent.

    The attr can be either an :class:`Agent` instance or a callable
    returning one (``build()``). We use already-resolved ``directives``
    when present so the validator doesn't have to re-run an LLM.
    """
    module_part, _, attr = target.partition(":")
    if not attr:
        raise SystemExit(
            f"--from-agent expects path/to/script.py:attr, got {target!r}"
        )
    spec = importlib.util.spec_from_file_location("_among_them_pkg_target", module_part)
    if spec is None or spec.loader is None:
        raise SystemExit(f"Could not import {module_part!r}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(spec.name, mod)
    spec.loader.exec_module(mod)
    obj = getattr(mod, attr, None)
    if obj is None:
        raise SystemExit(f"{module_part!r} has no attribute {attr!r}")
    if callable(obj):
        obj = obj()

    # Duck-type Agent: must have .directives and optional .voter/.chatter/.reporter.
    directives = getattr(obj, "directives", None)
    if directives is None or not hasattr(directives, "model_dump"):
        raise SystemExit(
            f"{target!r} did not produce an object with .directives "
            "(a Pydantic Directives model). Got: " + repr(obj)
        )
    directives_dump = directives.model_dump()

    # Extract module overrides as types we can serialize. Anything fancier
    # than a stock ScriptedX gets serialized as a stub; the user has to
    # ship a custom Voter class via -f if they want it to load remotely.
    modules: dict[str, ModuleSpec] = {}
    for slot in ("voter", "chatter", "reporter"):
        inst = getattr(obj, slot, None)
        if inst is None:
            continue
        cls = type(inst).__name__
        params = {
            k: v
            for k, v in vars(inst).items()
            if not k.startswith("_") and isinstance(v, (str, int, float, bool))
        }
        if cls.startswith("Scripted"):
            modules[slot] = ModuleSpec(type="scripted", params=params)
        elif cls == "SilentChatter":
            modules[slot] = ModuleSpec(type="silent", params={})
        elif cls.startswith("LLM"):
            # LLM modules don't run inside the cogames Docker (no API
            # keys). Mark as llm; the validator will swap for scripted.
            modules[slot] = ModuleSpec(type="llm", params=params)
        else:
            modules[slot] = ModuleSpec(
                type="scripted",
                params=params,
            )

    return CogamesBundleConfig(
        directives=directives_dump,
        modules=modules,
        notes=[
            f"packaged-from: {target}",
        ],
    )


def _build_upload_command(
    *,
    policy_class: str,
    policy_name: str,
    season: str,
    extra_files: list[str],
    dry_run: bool,
    skip_validation: bool,
) -> list[str]:
    cmd: list[str] = ["cogames", "upload", "-p", f"class={policy_class}"]
    files = list(DEFAULT_BUNDLE_FILES) + list(extra_files)
    seen: set[str] = set()
    for f in files:
        if f in seen:
            continue
        seen.add(f)
        cmd.extend(["-f", f])
    cmd.extend(["-n", policy_name, "--season", season])
    if dry_run:
        cmd.append("--dry-run")
    if skip_validation:
        cmd.append("--skip-validation")
    return cmd


def _format_command(cmd: list[str]) -> str:
    """Return a shell-quoted multi-line representation of the upload command."""
    quoted = [shlex.quote(part) for part in cmd]
    out_lines: list[str] = []
    pending: list[str] = []
    for part in quoted:
        # Group flag+value pairs onto the same continuation line for readability
        if pending and (pending[-1].startswith(("-f", "-p", "-n")) or pending[-1] == "--season"):
            pending.append(part)
            out_lines.append("  " + " ".join(pending))
            pending = []
        else:
            pending.append(part)
    if pending:
        out_lines.append("  " + " ".join(pending))
    return " \\\n".join(out_lines)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="python -m among_them_sdk.package",
        description="Package an SDK config bundle for `cogames upload`.",
    )
    p.add_argument(
        "--instructions",
        default=None,
        help="Natural-language instructions string. Parsed deterministically (no LLM).",
    )
    p.add_argument(
        "--cognitive",
        action="append",
        help="Cognitive overrides as key=value, repeatable. e.g. --cognitive suspicion_threshold=0.7",
    )
    p.add_argument(
        "--module",
        action="append",
        help="Module slot spec: slot=type[:k=v,...]. Repeatable. e.g. --module voter=scripted:threshold=0.7",
    )
    p.add_argument(
        "--config-json",
        type=Path,
        default=None,
        help="Path to a hand-written CogamesBundleConfig JSON file. Wins over --instructions.",
    )
    p.add_argument(
        "--from-agent",
        default=None,
        help="Import path:attr resolving to an Agent or zero-arg callable returning one. "
        "We extract its already-resolved Directives + module specs.",
    )
    p.add_argument(
        "--out",
        type=Path,
        default=POLICY_DIR / CONFIG_FILENAME,
        help=f"Where to write the bundle config. Default: {POLICY_DIR / CONFIG_FILENAME}",
    )
    p.add_argument(
        "--profiles-from",
        type=Path,
        default=None,
        help=(
            "Path to a local OpponentStore root (e.g. ~/.among-them/opponents). "
            "When set, freezes that store's profiles into a snapshot file shipped "
            "alongside the policy so the tournament bot can read opponent intel "
            "without making LLM calls in Docker."
        ),
    )
    p.add_argument(
        "--profiles-out",
        type=Path,
        default=None,
        help=(
            "Override snapshot path. Default: sibling of --out named "
            "among_them_sdk_opponents.json (auto-included as -f in the upload command)."
        ),
    )
    p.add_argument(
        "--policy-name",
        default=None,
        help="Cogames policy name (-n flag). Defaults to $USER-sdk-<short> if unset.",
    )
    p.add_argument(
        "--policy-class",
        default="among_them_sdk.policy.cogames.SDKPolicy",
        help="Class path passed to cogames -p. Default targets the SDK entrypoint.",
    )
    p.add_argument(
        "--season",
        default="among-them",
        help="Cogames season name (--season flag). Default: among-them.",
    )
    p.add_argument(
        "--extra-file",
        action="append",
        default=[],
        help="Add an extra -f path to the upload command. Repeatable.",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Add --dry-run to the printed upload command.",
    )
    p.add_argument(
        "--skip-validation",
        action="store_true",
        help="Add --skip-validation to the printed upload command.",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # 1. Resolve a CogamesBundleConfig from one of the three input modes.
    if sum(bool(x) for x in (args.config_json, args.from_agent, args.instructions)) > 1:
        print(
            "Use exactly one of --config-json, --from-agent, --instructions "
            "(--cognitive / --module compose with --instructions only).",
            file=sys.stderr,
        )
        return 2

    if args.config_json:
        with args.config_json.open() as fh:
            data = json.load(fh)
        config = CogamesBundleConfig.model_validate(data)
    elif args.from_agent:
        config = _config_from_agent(args.from_agent)
    else:
        config = CogamesBundleConfig(
            instructions=args.instructions,
            cognitive=_parse_kv_list(args.cognitive),
            modules=_parse_module_spec(args.module),
        )

    # 2. Write it to the policy directory so SDKPolicy.__init__ finds it.
    out_path = write_config(config, args.out)
    print(f"[package] wrote bundle config -> {out_path}")
    print("[package] resolved directives:")
    print(json.dumps(config.resolve_directives().model_dump(), indent=2))

    # 2.5 Optionally freeze opponent profiles next to the bundle config.
    extra_files: list[str] = list(args.extra_file or [])
    if args.profiles_from:
        from .opponents import OpponentStore, freeze_profiles

        store = OpponentStore(root=args.profiles_from)
        if not store.list_profiles():
            print(
                f"[package] WARNING: no profiles in {args.profiles_from} — "
                "snapshot will be empty.",
                file=sys.stderr,
            )
        snapshot_path = (
            args.profiles_out
            if args.profiles_out
            else out_path.parent / "among_them_sdk_opponents.json"
        )
        snapshot = freeze_profiles(store, snapshot_path)
        print(f"[package] froze {len(store.list_profiles())} profile(s) -> {snapshot}")
        # Compute a repo-relative path to add to the upload command's -f
        # flags. Falls back to absolute path if the snapshot lives
        # outside REPO_ROOT.
        try:
            rel_snapshot = snapshot.resolve().relative_to(REPO_ROOT.resolve())
            extra_files.append(str(rel_snapshot))
        except ValueError:
            extra_files.append(str(snapshot.resolve()))

    # 3. Print the cogames upload command.
    user = os.environ.get("USER", "user")
    policy_name = args.policy_name or f"{user}-sdk-{int(__import__('time').time())}"
    cmd = _build_upload_command(
        policy_class=args.policy_class,
        policy_name=policy_name,
        season=args.season,
        extra_files=extra_files,
        dry_run=args.dry_run,
        skip_validation=args.skip_validation,
    )
    rel_repo = REPO_ROOT
    print()
    print(f"[package] run from {rel_repo}:")
    print()
    print(_format_command(cmd))
    print()
    print(
        "[package] tip: see among_them/sdk/docs/tournament-submission.md for the full happy path."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
