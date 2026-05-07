"""Run named personas (instructions + cognitive + module overrides bundled).

Each persona is a small dict that gets unpacked into ``Agent.create``. After
each game we print the parsed ``agent.directives`` JSON so you can see how a
persona spec is translated into typed Directives by the SDK.

Run:
  uv run python examples/personas.py
"""

from __future__ import annotations

import logging
from typing import Any

from among_them_sdk import Agent, ScriptedChatter, SilentChatter

logging.getLogger("among_them_sdk").setLevel(logging.WARNING)


PERSONAS: dict[str, dict[str, Any]] = {
    "aggressive_imposter": {
        "instructions": (
            "Kill aggressively. Never report bodies. Skip votes unless you "
            "must blame someone."
        ),
        "cognitive": {"kill_eagerness": "high", "report_eagerness": "low"},
        "modules": {"chatter": SilentChatter()},
    },
    "paranoid_crewmate": {
        "instructions": (
            "Trust nobody. Report bodies aggressively. Vote on evidence."
        ),
        "cognitive": {"suspicion_threshold": 0.4, "chat_tone": "paranoid"},
        "modules": {"chatter": ScriptedChatter(tone="paranoid")},
    },
    "social_butterfly": {
        "instructions": (
            "Be friendly. Vote with the majority. Avoid the central room."
        ),
        "cognitive": {"chat_tone": "friendly", "follow_majority": True},
        "modules": {"chatter": ScriptedChatter(tone="friendly")},
    },
}


def _build_aggressive() -> Agent:
    """Zero-arg builder for `python -m among_them_sdk.package --from-agent`."""
    return _build(PERSONAS["aggressive_imposter"], seed=42)


def _build_paranoid() -> Agent:
    """Zero-arg builder for `python -m among_them_sdk.package --from-agent`."""
    return _build(PERSONAS["paranoid_crewmate"], seed=42)


def _build(persona_spec: dict[str, Any], seed: int) -> Agent:
    return Agent.create(
        instructions=persona_spec["instructions"],
        cognitive=persona_spec["cognitive"],
        seed=seed,
        use_llm_for_instructions=False,
        **persona_spec.get("modules", {}),
    )


def main() -> None:
    for i, (name, spec) in enumerate(PERSONAS.items()):
        print(f"=== {name} ===")
        agent = _build(spec, seed=100 + i)
        result = agent.run(rounds=1)

        print(agent.directives.model_dump_json(indent=2))
        sample_chat = result.chat_messages[0] if result.chat_messages else "(none)"
        print(f"sample chat: {sample_chat}")
        print(f"summary:     {result.summary}")
        print()


if __name__ == "__main__":
    main()
