"""Agent.create(instructions=...) — natural-language directives demo.

Pass a free-form instructions string. The SDK will try an LLM if a key is
present (default ``gpt-5.5``); otherwise it falls back to a deterministic
keyword parser. Either way, ``agent.directives`` is a typed Pydantic model
that the scripted modules consult while making decisions.
"""

from among_them_sdk import Agent

agent = Agent.create(
    instructions=(
        "Report bodies aggressively. Trust no one after meeting 2. "
        "Vote with the majority unless you have direct evidence."
    ),
    cognitive={"suspicion_threshold": 0.6},
    use_llm_for_instructions=False,
)

print("directives:", agent.directives.model_dump_json(indent=2))

result = agent.run(rounds=1)
print(result.summary)
