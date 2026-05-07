"""Parse one instruction string into a Directives JSON dump and exit.

A tiny, no-game iteration tool for tuning instruction wording. Calls the
exact same ``parse_instructions`` the Agent uses, so the printed JSON is what
``Agent.create(instructions=...)`` would produce.

Behavior:
  * with no API key  -> uses the deterministic keyword parser (always OK)
  * with an API key  -> attempts the LLM parser; falls back to keyword on
                        any failure (the SDK does this for you)

Run:
  uv run python examples/debug_directives.py "Trust nobody. Vote with the majority."
  uv run python examples/debug_directives.py --no-llm "Be paranoid"
  uv run python examples/debug_directives.py   # uses a built-in default string
"""

from __future__ import annotations

import argparse
import logging
import os

from among_them_sdk import parse_instructions

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)

DEFAULT_TEXT = (
    "Be aggressive about reporting bodies. Trust nobody after meeting 2. "
    "Vote with the majority."
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("instructions", nargs="?", default=DEFAULT_TEXT)
    parser.add_argument("--model", default="gpt-5.5")
    parser.add_argument("--no-llm", action="store_true",
                        help="Force the deterministic keyword parser.")
    args = parser.parse_args()

    use_llm = not args.no_llm
    have_key = bool(os.environ.get("OPENAI_API_KEY")
                    or os.environ.get("ANTHROPIC_API_KEY"))

    if use_llm and have_key:
        path = f"LLM ({args.model})"
    elif use_llm:
        path = "LLM requested but no key found -> keyword fallback"
    else:
        path = "keyword parser (forced)"

    print(f"input:  {args.instructions!r}")
    print(f"parser: {path}")
    print()

    directives = parse_instructions(args.instructions, use_llm=use_llm, model=args.model)
    print(directives.model_dump_json(indent=2))


if __name__ == "__main__":
    main()
