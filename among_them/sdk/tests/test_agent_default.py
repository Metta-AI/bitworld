"""Default Agent runs against LocalSim for K ticks without crashing."""

from __future__ import annotations

from among_them_sdk import Agent, LocalSim


def test_default_agent_runs():
    agent = Agent.create(use_llm_for_instructions=False)
    sim = LocalSim(ticks_per_round=8, meeting_every=4, report_every=3, seed=7)
    result = agent.run(rounds=1, runtime=sim)

    assert result.ticks == 8
    assert len(result.actions) == 8
    assert result.meetings >= 1
    assert "evidencebot_v2" in result.summary
    assert "ABI 1" in result.summary


def test_default_agent_send_step():
    import numpy as np

    agent = Agent.create(use_llm_for_instructions=False)
    obs = np.zeros((1, 1, 128, 128), dtype=np.uint8)
    out = agent.send(obs)
    assert isinstance(out, int)
    assert 0 <= out < 256


def test_default_agent_summary_payload():
    agent = Agent.create(use_llm_for_instructions=False)
    sim = LocalSim(ticks_per_round=4, meeting_every=2, report_every=2, seed=11)
    result = agent.run(rounds=1, runtime=sim)
    raw = result.raw
    assert raw["policy_summary"]["policy"] == "evidencebot_v2"
    assert raw["policy_summary"]["abi_version"] == 1
    assert "directives" in raw
    assert "cyborg" in raw
