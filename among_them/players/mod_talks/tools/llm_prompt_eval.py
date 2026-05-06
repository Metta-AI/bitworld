#!/usr/bin/env -S uv run
"""mod_talks prompt-eval harness (Sprint 5.1).

Replays captured LLM dispatched contexts against a candidate prompt
configuration and scores responses on mechanical checks. Lets us
iterate on prompts without running live games.

## Capturing fixtures

Run a live or mock-LLM game with `MODTALKS_LLM_CAPTURE=1` and the
trace writer enabled. Each dispatched context is written to
`<trace-root>/<bot>/<session>/round-NNNN/llm_contexts/ctx_<seq>_<kind>_t<tick>.json`.
A few hundred entries across multiple games is plenty for
mechanical-check signal.

Example:

    AWS_PROFILE=softmax CLAUDE_CODE_USE_BEDROCK=1 \
      MODULABOT_TRACE_DIR=/tmp/eval_capture \
      MODTALKS_LLM_CAPTURE=1 \
      python among_them/players/mod_talks/scripts/launch_mod_talks_llm_local.py \
      --port 8095 --max-steps 4000 --no-browser

## Running eval

    python among_them/players/mod_talks/tools/llm_prompt_eval.py \
      --captures /tmp/eval_capture \
      --output /tmp/eval_results.csv \
      [--limit 50] [--kind hypothesis,strategize] [--mock /path/to/canned.jsonl]

When `--mock` is set, responses come from the supplied JSONL fixture
(matching the same format as `--llm-mock`); useful for offline CI
without burning provider tokens. Otherwise the harness calls
Anthropic Bedrock / direct API and uses real responses.

## Scoring rubric (mechanical checks)

Each response is scored against the dispatched context for:

  * `valid_json` — parsed JSON object cleanly.
  * `living_player_target` — chosen target appears in
    `context.living_players`.
  * `respects_safe_colors` — imposter `best_target` not in
    `context.safe_colors`.
  * `chat_within_max_len` — chat message length ≤ LlmMaxChatLen
    (72 chars).
  * `no_ai_reveal` — chat doesn't contain phrases that reveal the
    model identity ("as an AI", "language model", etc.).

Output: a CSV with one row per (capture, kind, score-key, value),
plus a stdout summary table by call kind.
"""

from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Mirror the Nim `LlmMaxChatLen` constant. Kept inline rather than
# imported so the harness has zero Nim dependency.
LLM_MAX_CHAT_LEN = 72

# Phrases that indicate the model leaked its AI identity.
AI_REVEAL_PHRASES = [
    "as an ai",
    "as a language model",
    "i'm an ai",
    "i am an ai",
    "i'm a large language model",
    "i can't help with that",  # Anthropic refusal pattern
    "i don't have personal experiences",
]


def _list_capture_files(root: Path) -> list[Path]:
    """Walks a trace root and yields all `llm_contexts/ctx_*.json` files."""
    return sorted(root.rglob("llm_contexts/ctx_*.json"))


def _parse_kind_from_filename(path: Path) -> str:
    # Filename: ctx_<seq>_<kind>_t<tick>.json
    parts = path.stem.split("_")
    if len(parts) < 3:
        return "unknown"
    # kind may itself contain underscore (imposter_react)
    return "_".join(parts[2:-1])


def _load_capture(path: Path) -> tuple[str, dict[str, Any]] | None:
    try:
        ctx = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("skipping %s: %s", path, exc)
        return None
    if not isinstance(ctx, dict):
        return None
    kind = _parse_kind_from_filename(path)
    return kind, ctx


def _score_response(
    *, kind: str, context: dict[str, Any], response_text: str
) -> dict[str, Any]:
    """Returns a score dict for one (context, response) pair."""
    score: dict[str, Any] = {
        "valid_json": False,
        "living_player_target": None,
        "respects_safe_colors": None,
        "chat_within_max_len": None,
        "chat_present": None,
        "no_ai_reveal": None,
        "raw_response_len": len(response_text),
    }
    if not response_text:
        return score
    try:
        payload = json.loads(response_text)
    except json.JSONDecodeError:
        return score
    if not isinstance(payload, dict):
        return score
    score["valid_json"] = True

    living = set(context.get("living_players") or [])
    safe = set(context.get("safe_colors") or [])

    # Target check (where applicable).
    target = None
    if kind == "strategize":
        target = payload.get("best_target")
    elif kind in ("hypothesis", "react"):
        suspects = payload.get("suspects") or []
        if suspects and isinstance(suspects, list):
            top = suspects[0]
            if isinstance(top, dict):
                target = top.get("color")
    elif kind == "accuse":
        target = payload.get("suspect") or context.get("suspect")
    if target is not None and living:
        score["living_player_target"] = target in living
    if kind == "strategize" and target is not None and safe:
        score["respects_safe_colors"] = target not in safe

    # Chat checks.
    chat_text = None
    for key in ("chat", "initial_chat"):
        v = payload.get(key)
        if isinstance(v, str) and v.strip():
            chat_text = v.strip()
            break
    if chat_text is not None:
        score["chat_present"] = True
        score["chat_within_max_len"] = len(chat_text) <= LLM_MAX_CHAT_LEN
        lc = chat_text.lower()
        score["no_ai_reveal"] = not any(p in lc for p in AI_REVEAL_PHRASES)
    else:
        score["chat_present"] = False

    return score


def _provider_complete(
    kind: str, context: dict[str, Any], role: int
) -> str:
    """Calls Anthropic via the same controller mod_talks uses live."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cogames"))
    import amongthem_policy
    controller = amongthem_policy._AnthropicController()
    if not controller.enabled:
        return ""
    return controller.complete(
        role=role,
        kind=kind,
        context_json=json.dumps(context),
        timeout_seconds=amongthem_policy.PER_KIND_TIMEOUT_SECONDS.get(kind, 15.0),
    )


def _mock_responses(path: Path) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        out.append(json.loads(line))
    return out


def _role_for_kind(kind: str) -> int:
    # `_ROLE_CREWMATE = 1`, `_ROLE_IMPOSTER = 2` in amongthem_policy.
    if kind in ("strategize", "imposter_react"):
        return 2
    return 1


def _summarise(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    summary: dict[str, dict[str, Any]] = {}
    for row in rows:
        s = summary.setdefault(row["kind"], {
            "n": 0,
            "valid_json": 0,
            "living_player_target_pass": 0,
            "living_player_target_n": 0,
            "respects_safe_colors_pass": 0,
            "respects_safe_colors_n": 0,
            "chat_within_max_len_pass": 0,
            "chat_within_max_len_n": 0,
            "no_ai_reveal_pass": 0,
            "no_ai_reveal_n": 0,
        })
        s["n"] += 1
        if row["valid_json"]:
            s["valid_json"] += 1
        for k in ("living_player_target", "respects_safe_colors",
                  "chat_within_max_len", "no_ai_reveal"):
            if row.get(k) is not None:
                s[f"{k}_n"] += 1
                if row[k]:
                    s[f"{k}_pass"] += 1
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, required=True,
                        help="Trace root with captured llm_contexts/ dirs")
    parser.add_argument("--output", type=Path, required=True,
                        help="CSV output path")
    parser.add_argument("--limit", type=int, default=0,
                        help="Max contexts to evaluate (0 = all)")
    parser.add_argument("--kind", type=str, default="",
                        help="Comma-separated kinds to include "
                             "(default: all)")
    parser.add_argument("--mock", type=Path, default=None,
                        help="JSONL of canned responses (skip provider)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    files = _list_capture_files(args.captures)
    if not files:
        print(f"no captures under {args.captures}", file=sys.stderr)
        return 2
    if args.limit > 0:
        files = files[: args.limit]
    kind_filter: set[str] | None = None
    if args.kind:
        kind_filter = set(k.strip() for k in args.kind.split(","))

    mock_responses: list[dict[str, Any]] | None = None
    mock_idx = 0
    if args.mock is not None:
        mock_responses = _mock_responses(args.mock)
        print(f"mock mode: {len(mock_responses)} responses loaded")

    rows: list[dict[str, Any]] = []
    for path in files:
        loaded = _load_capture(path)
        if loaded is None:
            continue
        kind, ctx = loaded
        if kind_filter and kind not in kind_filter:
            continue
        if mock_responses is not None:
            entry = (
                mock_responses[mock_idx % len(mock_responses)]
                if mock_responses else {}
            )
            mock_idx += 1
            response_text = json.dumps(entry.get("response", {}))
            if entry.get("errored"):
                response_text = ""
        else:
            response_text = _provider_complete(kind, ctx, _role_for_kind(kind))
        score = _score_response(
            kind=kind, context=ctx, response_text=response_text
        )
        score["kind"] = kind
        score["capture"] = str(path.relative_to(args.captures))
        rows.append(score)
        print(f"{path.name}: kind={kind} valid_json={score['valid_json']} "
              f"len={len(response_text)}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as f:
        if rows:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
    print(f"\nwrote {len(rows)} rows to {args.output}")

    print("\n=== summary by kind ===")
    summary = _summarise(rows)
    for kind in sorted(summary.keys()):
        s = summary[kind]
        n = s["n"]
        if n == 0:
            continue
        print(f"\n{kind}: n={n}")
        print(f"  valid_json: {s['valid_json']}/{n}")
        for label in ("living_player_target", "respects_safe_colors",
                      "chat_within_max_len", "no_ai_reveal"):
            denom = s[f"{label}_n"]
            num = s[f"{label}_pass"]
            if denom == 0:
                print(f"  {label}: n/a (0 applicable)")
            else:
                pct = 100.0 * num / denom
                print(f"  {label}: {num}/{denom} ({pct:.0f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
