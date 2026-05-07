"""Write a per-game NDJSON transcript by wiring AgentHooks.

Demonstrates the hook system: every meeting / vote / chat message is appended
as one JSON line to ``./transcripts/<run_id>.ndjson``. The on_kill hook is
also registered for completeness, but note LocalSim doesn't currently emit
kill events, so it will never fire under this runtime.

Output: prints the path to the transcript file, then a 3-line preview.

Run:
  uv run python examples/transcript_logger.py
"""

from __future__ import annotations

import argparse
import json
import logging
import time
import uuid
from pathlib import Path
from typing import Any

from among_them_sdk import Agent, AgentHooks

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)


def _make_writer(path: Path):
    fh = path.open("a", encoding="utf-8")

    def write(event: str, payload: dict[str, Any]) -> None:
        record = {"t": time.time(), "event": event, **payload}
        fh.write(json.dumps(record) + "\n")
        fh.flush()

    return write, fh


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--out-dir", default="./transcripts")
    args = parser.parse_args()

    # NOTE: resolve to an absolute path *before* Agent.create — the FFI loader
    # mutates cwd as a side-effect, so any relative path opened later breaks.
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex[:8]
    transcript = out_dir / f"{run_id}.ndjson"
    write, fh = _make_writer(transcript)

    hooks = AgentHooks(
        on_meeting=lambda p: write("meeting", p),
        on_vote=lambda p: write("vote", p),
        on_message=lambda p: write("message", p),
        on_kill=lambda p: write("kill", p),  # never fires in current LocalSim
    )

    agent = Agent.create(
        instructions="Be suspicious. Vote with the majority.",
        hooks=hooks,
        use_llm_for_instructions=False,
        seed=2026,
    )
    result = agent.run(rounds=args.rounds)
    fh.close()

    print(f"transcript: {transcript}")
    print(f"events:     {sum(1 for _ in transcript.open())}")
    print(f"summary:    {result.summary}")
    print()
    print("preview (first 3 lines):")
    with transcript.open() as f:
        for i, line in enumerate(f):
            if i >= 3:
                break
            print(" ", line.rstrip())


if __name__ == "__main__":
    main()
