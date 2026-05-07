"""Swap the chatter for an LLM-backed one. Falls back to scripted on no key."""

import os

from among_them_sdk import Agent, LLMChatter

agent = Agent.create(
    chatter=LLMChatter(model="gpt-5.5", tone="suspicious"),
    use_llm_for_instructions=False,
)

if not os.environ.get("OPENAI_API_KEY"):
    print("(no OPENAI_API_KEY — chatter will use scripted fallback)")

result = agent.run(rounds=1)
print(result.summary)
print("messages:")
for m in result.chat_messages:
    print(" -", m)
