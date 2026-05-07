"""Replace just the voter module with a custom Python heuristic."""

from among_them_sdk import Agent, Vote, Voter, VotingContext


class GrudgeVoter(Voter):
    """Always vote for the suspect with the highest suspicion score, no skip."""

    def vote(self, ctx: VotingContext) -> Vote:
        if not ctx.suspects:
            return Vote.skip("no suspects")
        top = max(ctx.suspects, key=lambda s: s.score)
        return Vote(target=top.player_id, reason=f"holding a grudge ({top.score:.2f})")


agent = Agent.create(voter=GrudgeVoter())
result = agent.run(rounds=2)
print(result.summary)
print("votes:", [(v.target, v.reason) for v in result.votes])
