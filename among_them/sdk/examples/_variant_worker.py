"""One-variant worker subprocess for ``variant_arena.py``.

Loads a :class:`CogamesBundleConfig` from JSON, builds a
:class:`LocalSDKPolicy` from it, connects to a running Among Them server
via :class:`LiveGame`, and runs to completion. On exit it writes a
per-variant metrics JSON the orchestrator slurps to build the comparison
table.

Why a subprocess
----------------

Each :class:`LocalSDKPolicy` instance allocates its own
``EvidenceBotV2Policy`` FFI handle (separate ``new_policy()`` call), but
the underlying Nim shared library is a process-wide singleton with its
own GC + global state. Running 8 variants in 8 subprocesses sidesteps
any in-process FFI re-entrancy or asyncio-loop conflicts and matches
how the tournament actually deploys ("one process per player"). It also
means a crashing variant only takes itself down, not the whole arena.

Run by hand (rarely needed)::

    uv run python examples/_variant_worker.py \\
        --name baseline --port 2000 \\
        --config /tmp/variant_baseline.json \\
        --metrics-out /tmp/metrics_baseline.json
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sys
import time
import traceback
from pathlib import Path
from typing import Any

# Make the SDK importable regardless of cwd.
_THIS_FILE = Path(__file__).resolve()
SDK_SRC = _THIS_FILE.parent.parent / "src"
sys.path.insert(0, str(SDK_SRC))

from among_them_sdk import (  # noqa: E402
    CogamesBundleConfig,
    LiveGame,
    LocalSDKPolicy,
)

logger = logging.getLogger("variant_worker")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run one SDK variant against a live server.")
    p.add_argument("--name", required=True, help="Player display name (= variant name).")
    p.add_argument("--host", default="127.0.0.1", help="Server host (default 127.0.0.1).")
    p.add_argument("--port", type=int, required=True, help="Server TCP port.")
    p.add_argument(
        "--config",
        required=True,
        help="Path to a JSON file matching CogamesBundleConfig.",
    )
    p.add_argument(
        "--metrics-out",
        required=True,
        help="Where to write the per-variant metrics JSON when this worker exits.",
    )
    p.add_argument(
        "--max-ticks",
        type=int,
        default=200_000,
        help="Hard cap on ticks before the worker forcibly disconnects.",
    )
    p.add_argument(
        "--connect-timeout",
        type=float,
        default=30.0,
        help="Seconds to wait for the server socket before giving up.",
    )
    p.add_argument(
        "--check-llm-key",
        action="store_true",
        help=(
            "Print a warning if any module is `type=llm` and no usable API "
            "key is in the environment. Exit 0 either way (LLM modules "
            "degrade to scripted on missing keys)."
        ),
    )
    return p.parse_args()


def _load_bundle(path: str) -> CogamesBundleConfig:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"variant config at {path} is not a JSON object")
    return CogamesBundleConfig.model_validate(data)


def _has_llm_key() -> bool:
    """Best-effort check: do we have any LLM credentials configured?"""
    return bool(
        os.environ.get("AWS_PROFILE")            # Bedrock via SSO
        or os.environ.get("AWS_ACCESS_KEY_ID")   # Bedrock via static creds
        or os.environ.get("OPENAI_API_KEY")
        or os.environ.get("ANTHROPIC_API_KEY")
    )


def _wants_llm(bundle: CogamesBundleConfig) -> bool:
    return any(
        (spec.type or "").lower() == "llm" for spec in bundle.modules.values()
    )


def _write_metrics(path: str, payload: dict[str, Any]) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(payload, indent=2, default=str) + "\n")


def main() -> int:
    args = parse_args()
    logging.basicConfig(level=logging.WARNING, format="[%(name)s] %(message)s")

    bundle = _load_bundle(args.config)

    if args.check_llm_key and _wants_llm(bundle) and not _has_llm_key():
        # Per the prompt: variant 8 (LLM) gracefully degrades. The
        # LLMVoter / LLMChatter constructors silently fall back to
        # ScriptedVoter / ScriptedChatter when no key is present, so we
        # only warn — we never crash.
        print(
            f"[{args.name}] WARNING: variant requested LLM modules but "
            "no OPENAI_API_KEY / ANTHROPIC_API_KEY in env; "
            "LLM modules will degrade to scripted fallback.",
            file=sys.stderr,
        )

    started = time.time()
    metrics: dict[str, Any] = {
        "name": args.name,
        "started_at": started,
        "config": bundle.model_dump(exclude_none=True),
    }

    # Build the policy + LiveGame up front so the SIGTERM handler can
    # snapshot live state even if termination interrupts the run loop.
    try:
        policy = LocalSDKPolicy(config=bundle)
    except Exception as exc:
        metrics["error"] = f"policy_init_failed: {exc!r}"
        metrics["traceback"] = traceback.format_exc()
        metrics["finished_at"] = time.time()
        _write_metrics(args.metrics_out, metrics)
        print(f"[{args.name}] ERROR (policy init): {exc!r}", file=sys.stderr)
        return 1

    live = LiveGame(
        host=args.host,
        port=args.port,
        name=args.name,
        max_ticks=args.max_ticks,
        connect_timeout=args.connect_timeout,
    )

    def _snapshot(reason: str) -> None:
        """Write whatever engine state we've accumulated so far.

        Idempotent — safe to call from a signal handler and again at
        normal exit. We always write *something* so the orchestrator
        never sees a missing metrics file even when the worker is
        SIGTERM'd mid-run.
        """
        try:
            stats = policy.engine.stats
            metrics.setdefault("partial_reason", reason)
            metrics.setdefault("finished_at", time.time())
            metrics.setdefault("directives", policy.directives.model_dump())
            metrics["engine_stats"] = {
                "ticks_seen": stats.ticks_seen,
                "reports_passed": stats.reports_passed,
                "reports_suppressed": stats.reports_suppressed,
                "voter_advisories": list(stats.voter_advisories),
                "chatter_advisories": list(stats.chatter_advisories),
            }
            _write_metrics(args.metrics_out, metrics)
        except Exception as snap_exc:  # noqa: BLE001 - last-ditch
            print(f"[{args.name}] snapshot failed: {snap_exc!r}", file=sys.stderr)

    def _term_handler(sig: int, _frame: Any) -> None:
        print(
            f"[{args.name}] caught signal {sig}; flushing partial metrics",
            file=sys.stderr,
        )
        _snapshot(reason=f"signal_{sig}")
        # Use os._exit so we don't fight the asyncio loop's shutdown path;
        # we've already saved everything we care about.
        os._exit(0)

    signal.signal(signal.SIGTERM, _term_handler)

    try:
        result, transcript = live.run_local_sdk_policy(policy)
    except Exception as exc:
        metrics["error"] = repr(exc)
        metrics["traceback"] = traceback.format_exc()
        _snapshot(reason="exception")
        print(f"[{args.name}] ERROR: {exc!r}", file=sys.stderr)
        return 1

    stats = policy.engine.stats
    metrics.update(
        {
            "finished_at": time.time(),
            "directives": policy.directives.model_dump(),
            "summary": result.summary,
            "frames_received": transcript.frames_received,
            "masks_sent": transcript.masks_sent,
            "actions_seen": dict(transcript.actions_seen),
            "transcript_error": transcript.error,
            "engine_stats": {
                "ticks_seen": stats.ticks_seen,
                "reports_passed": stats.reports_passed,
                "reports_suppressed": stats.reports_suppressed,
                "voter_advisories": list(stats.voter_advisories),
                "chatter_advisories": list(stats.chatter_advisories),
            },
        }
    )
    _write_metrics(args.metrics_out, metrics)
    print(
        f"[{args.name}] done frames={transcript.frames_received} "
        f"masks={transcript.masks_sent} reports_passed={stats.reports_passed} "
        f"reports_suppressed={stats.reports_suppressed}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
