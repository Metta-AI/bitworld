"""A custom module actually replaces the default."""

from __future__ import annotations

from among_them_sdk import (
    Agent,
    LocalSim,
    Vote,
    Voter,
    VotingContext,
)
from among_them_sdk.modules import ScriptedReporter
from among_them_sdk.modules.chatter import ChatContext
from among_them_sdk.modules.reporter import ReportContext


class TaggingVoter(Voter):
    """Always votes for the same target and tags every call."""

    def __init__(self):
        self.calls = 0

    def vote(self, ctx: VotingContext) -> Vote:
        self.calls += 1
        return Vote(target="P00", reason=f"tagging-call-{self.calls}")


def test_voter_override_replaces_default():
    tagger = TaggingVoter()
    agent = Agent.create(voter=tagger, use_llm_for_instructions=False)

    sim = LocalSim(ticks_per_round=12, meeting_every=4, report_every=99, seed=5)
    result = agent.run(rounds=1, runtime=sim)

    assert tagger.calls > 0
    assert tagger.calls == len(result.votes)
    for v in result.votes:
        assert v.target == "P00"
        assert v.reason.startswith("tagging-call-")


def test_directives_drive_scripted_reporter():
    eager_agent = Agent.create(
        instructions="Report bodies aggressively.",
        use_llm_for_instructions=False,
    )
    cautious_agent = Agent.create(
        instructions="Never report bodies.",
        use_llm_for_instructions=False,
    )

    assert isinstance(eager_agent.reporter, ScriptedReporter)
    assert eager_agent.reporter.eagerness == "high"
    assert cautious_agent.reporter.eagerness == "low"

    far_ctx = ReportContext(
        tick=10, self_id="self", body_player_id="P03",
        distance_to_body=15.0, seen_body_for_ticks=2,
    )
    assert eager_agent.consider_report(far_ctx) is True
    assert cautious_agent.consider_report(far_ctx) is False


def test_chat_tone_propagates_from_directives():
    agent = Agent.create(
        instructions="Be defensive in meetings.",
        use_llm_for_instructions=False,
    )
    assert agent.directives.chat_tone == "defensive"
    msg = agent.speak(ChatContext(self_id="self", meeting_index=1, suspect_summary=""))
    assert msg is not None
    assert "Don't pin this on me" in msg
