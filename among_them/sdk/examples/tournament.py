"""Spawn N variants in parallel and read the leaderboard."""

from among_them_sdk import Agent, Runner

agents = [
    Agent.create(seed=1, use_llm_for_instructions=False),
    Agent.create(
        seed=2,
        instructions="Be aggressive about reporting. Trust nobody.",
        use_llm_for_instructions=False,
    ),
    Agent.create(
        seed=3,
        instructions="Vote with the majority. Avoid the central room.",
        use_llm_for_instructions=False,
    ),
    Agent.create(seed=4, cognitive={"suspicion_threshold": 0.8},
                 use_llm_for_instructions=False),
]

runner = Runner(agents=agents, rounds=1, parallelism=2)
results = runner.run()
for row in runner.leaderboard(results):
    print(row)
