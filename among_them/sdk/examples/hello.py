"""5-line hello world: spin up the default agent and run for one round."""

from among_them_sdk import Agent

agent = Agent.create()
result = agent.run(rounds=10)
print(result.summary)
