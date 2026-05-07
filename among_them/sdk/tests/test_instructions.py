"""Instructions string parsing — keyword path is hermetic, LLM path mocked."""

from __future__ import annotations

from among_them_sdk import Directives, parse_instructions
from among_them_sdk.cognition.instructions import parse_instructions_keyword


def test_empty_instructions_yields_defaults():
    d = parse_instructions_keyword("")
    assert d == Directives.scripted_defaults()
    d2 = parse_instructions(None, use_llm=False)
    assert d2 == Directives.scripted_defaults()


def test_aggressive_reporting():
    d = parse_instructions_keyword("Report bodies aggressively no matter what.")
    assert d.report_eagerness == "high"


def test_trust_nobody():
    d = parse_instructions_keyword("Trust nobody, ever.")
    assert d.suspicion_threshold == 0.8


def test_majority_voting():
    d = parse_instructions_keyword("Vote with the majority always.")
    assert d.voting_style == "majority"
    assert d.follow_majority is True


def test_meeting_horizon():
    d = parse_instructions_keyword("Trust no one after meeting 3.")
    assert d.trust_horizon_meetings == 3


def test_combined_phrase():
    d = parse_instructions_keyword(
        "Report bodies aggressively. Trust no one after meeting 2. "
        "Vote with the majority unless you have direct evidence."
    )
    assert d.report_eagerness == "high"
    assert d.trust_horizon_meetings == 2
    assert d.follow_majority is True


def test_directives_merge():
    d = parse_instructions_keyword("Trust nobody.")
    merged = d.merged_with(report_eagerness="low")
    assert merged.suspicion_threshold == 0.8
    assert merged.report_eagerness == "low"
    assert merged.raw == "Trust nobody."


def test_high_level_parse_no_llm():
    d = parse_instructions("Be paranoid. Avoid central.", use_llm=False)
    assert d.chat_tone == "paranoid"
    assert d.avoid_central_room is True
