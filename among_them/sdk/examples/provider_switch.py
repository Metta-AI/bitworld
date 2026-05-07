"""Switch LLM provider per cognitive module.

Wires LLMVoter to OpenAI and LLMChatter to Anthropic to demonstrate the
multi-provider story. Each module is constructed independently — a missing
API key for one provider does not break the other.

The LLM-backed modules already fall back to their scripted siblings on
LLMUnavailableError, so this script always exits 0 even with no keys set.
The output reports which providers were live vs. degraded.

Provider strings follow ``among_them_sdk.cognition.llm`` routing:
  "gpt-5.5"                     -> OpenAI
  "openai/gpt-5.5"              -> OpenAI (explicit)
  "anthropic/claude-sonnet-4-5" -> Anthropic

Run:
  uv run python examples/provider_switch.py
"""

from __future__ import annotations

import logging
import os

from among_them_sdk import Agent, LLMChatter, LLMVoter

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)


def _provider_status(env_var: str, label: str) -> str:
    return f"{label}: {'live' if os.environ.get(env_var) else 'no key (will degrade)'}"


def main() -> None:
    print(_provider_status("OPENAI_API_KEY", "OPENAI_API_KEY"))
    print(_provider_status("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"))
    print()

    voter = LLMVoter(model="openai/gpt-5.5")
    chatter = LLMChatter(model="anthropic/claude-sonnet-4-5", tone="suspicious")

    voter_status = "LLM" if voter.llm is not None else "scripted-fallback"
    chatter_status = "LLM" if chatter.llm is not None else "scripted-fallback"

    print(f"voter   -> openai/gpt-5.5              [{voter_status}]")
    print(f"chatter -> anthropic/claude-sonnet-4-5 [{chatter_status}]")
    print()

    agent = Agent.create(
        voter=voter,
        chatter=chatter,
        use_llm_for_instructions=False,
        seed=42,
    )
    result = agent.run(rounds=1)
    print(result.summary)
    if result.chat_messages:
        print("first chat:", result.chat_messages[0])


if __name__ == "__main__":
    main()
