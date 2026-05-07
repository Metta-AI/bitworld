"""Tests for the cross-game opponent-modeling module.

Coverage:

  * :class:`OpponentProfile` JSON round-trip
  * :class:`OpponentStore` write / read / list
  * :class:`ObservationCollector` translates ``on_message`` into
    ``ObservationEvent`` rows
  * :func:`analyze_opponent` deterministic-fallback path produces a
    non-empty profile
  * :func:`analyze_opponent` MERGES with any prior profile (game count
    grows monotonically; old ``freeform_notes`` aren't lost)
  * :func:`freeze_profiles` produces a snapshot
    :class:`BundledProfileLookup` can load
  * :class:`LLMVoter` accepts ``opponent_profiles=`` without breaking
"""

from __future__ import annotations

import json

import pytest

from among_them_sdk import (
    BundledProfileLookup,
    LLMVoter,
    ObservationCollector,
    ObservationEvent,
    OpponentProfile,
    OpponentStore,
    analyze_opponent,
    freeze_profiles,
)
from among_them_sdk.modules import VotingContext
from among_them_sdk.modules.memory import SuspicionEntry
from among_them_sdk.opponents.analyzer import (
    analyze_opponent_statistical,
    merge_profiles,
)

# --------------------------- model round-trip --------------------------- #


def test_opponent_profile_json_round_trip():
    profile = OpponentProfile(name="nottoodumb1", games_observed=3, confidence=0.42)
    profile.chat_style.tone_descriptors = ["defensive", "aggressive"]
    profile.vote_strategy.label = "bandwagoner"
    profile.freeform_notes = "noted in game 2"

    serialized = profile.model_dump_json()
    restored = OpponentProfile.model_validate_json(serialized)
    assert restored == profile
    assert restored.compact_summary().startswith("nottoodumb1")


def test_observation_event_round_trip():
    ev = ObservationEvent(
        type="vote",
        tick=1234,
        game_id="g1",
        payload={"target": "nottoodumb3", "is_skip": False, "meeting": 2},
    )
    rt = ObservationEvent.model_validate_json(ev.model_dump_json())
    assert rt == ev


# --------------------------- store --------------------------- #


def test_store_write_read_list(tmp_path):
    store = OpponentStore(root=tmp_path)

    ev1 = ObservationEvent(type="chat", tick=10, game_id="g1", payload={"text": "hi"})
    ev2 = ObservationEvent(type="vote", tick=15, game_id="g1", payload={"target": "x"})
    store.record("nottoodumb1", ev1)
    store.record("nottoodumb1", ev2)

    log = store.log_for("nottoodumb1")
    rows = log.all()
    assert len(rows) == 2
    assert rows[0].type == "chat"
    summary = log.summary()
    assert summary["events"] == 2
    assert summary["games"] == 1
    assert summary["type_counts"] == {"chat": 1, "vote": 1}

    profile = OpponentProfile(name="nottoodumb1", games_observed=1, confidence=0.2)
    profile_path = store.save_profile("nottoodumb1", profile)
    assert profile_path.exists()
    assert "nottoodumb1" in store.list_opponents()
    loaded = store.load_profile("nottoodumb1")
    assert loaded is not None
    assert loaded.games_observed == 1


def test_store_env_override(monkeypatch, tmp_path):
    """``AMONG_THEM_OPPONENTS_DIR`` overrides the default root."""
    monkeypatch.setenv("AMONG_THEM_OPPONENTS_DIR", str(tmp_path))
    store = OpponentStore()
    assert str(store.root) == str(tmp_path)


def test_store_iter_recent(tmp_path):
    """``iter_recent`` filters to the last K distinct game ids."""
    store = OpponentStore(root=tmp_path)
    for i in range(5):
        store.record(
            "n1",
            ObservationEvent(
                type="chat",
                tick=i,
                game_id=f"g{i}",
                payload={"text": str(i)},
            ),
        )
    log = store.log_for("n1")
    recent = log.iter_recent(n_games=2)
    assert len(recent) == 2
    assert {r.game_id for r in recent} == {"g3", "g4"}


# --------------------------- collector --------------------------- #


def test_collector_on_message_translation(tmp_path):
    store = OpponentStore(root=tmp_path)
    collector = ObservationCollector(
        store=store,
        game_id="g1",
        self_id="self",
        known_opponents=["nottoodumb1", "nottoodumb2", "self"],
    )

    collector.hooks.call(
        "on_message",
        {
            "actor": "nottoodumb1",
            "text": "I think nottoodumb2 is sus.",
            "meeting": 1,
            "tick": 100,
        },
    )

    events = store.log_for("nottoodumb1").all()
    types = [e.type for e in events]
    # The chat row + an "accused" row pointing at nottoodumb2.
    assert "chat" in types
    assert "accused" in types
    accused = next(e for e in events if e.type == "accused")
    assert accused.payload["target"] == "nottoodumb2"

    # The accused side gets an "accused_by" row stamped onto its log.
    accused_log = store.log_for("nottoodumb2").all()
    assert any(e.type == "accused_by" for e in accused_log)


def test_collector_skips_self(tmp_path):
    """Events where ``actor == self_id`` must be ignored."""
    store = OpponentStore(root=tmp_path)
    collector = ObservationCollector(store=store, game_id="g1", self_id="self")
    collector.hooks.call(
        "on_message",
        {"actor": "self", "text": "hello", "meeting": 1},
    )
    assert store.log_for("self").all() == []


def test_collector_on_vote_kill(tmp_path):
    store = OpponentStore(root=tmp_path)
    collector = ObservationCollector(store=store, game_id="g1")
    collector.hooks.call(
        "on_vote",
        {"actor": "n1", "target": "n2", "meeting": 1, "tick": 200, "reason": "x"},
    )
    collector.hooks.call(
        "on_vote",
        {"actor": "n3", "target": None, "meeting": 1, "tick": 200},
    )
    collector.hooks.call(
        "on_kill",
        {"actor": "n1", "target": "n4", "tick": 50},
    )
    n1_events = store.log_for("n1").all()
    assert any(e.type == "vote" and e.payload["target"] == "n2" for e in n1_events)
    assert any(e.type == "kill" and e.payload["victim"] == "n4" for e in n1_events)
    n3_events = store.log_for("n3").all()
    assert any(e.type == "vote" and e.payload["is_skip"] is True for e in n3_events)
    n4_events = store.log_for("n4").all()
    assert any(e.type == "killed" and e.payload["attacker"] == "n1" for e in n4_events)


def test_collector_flush_game_end(tmp_path):
    store = OpponentStore(root=tmp_path)
    collector = ObservationCollector(store=store, game_id="g1", self_id="self")
    collector.flush_game_end(
        roles={"n1": "imposter", "n2": "crew"},
        alive_at_end={"n2"},
    )
    n1 = store.log_for("n1").all()
    assert any(e.type == "role_revealed" and e.payload["role"] == "imposter" for e in n1)
    n2 = store.log_for("n2").all()
    assert any(e.type == "role_revealed" and e.payload["role"] == "crew" for e in n2)
    assert any(e.type == "alive_at_end" for e in n2)


def test_collector_stats(tmp_path):
    store = OpponentStore(root=tmp_path)
    c = ObservationCollector(store=store, game_id="g1", self_id="self")
    c.hooks.call("on_message", {"actor": "n1", "text": "hi", "meeting": 1})
    c.hooks.call("on_vote", {"actor": "n1", "target": "n2", "meeting": 1})
    c.hooks.call("on_kill", {"actor": "n1", "target": "n2"})
    s = c.stats()
    assert s["chats_observed"] == 1
    assert s["votes_observed"] == 1
    assert s["kills_observed"] == 1
    assert s["game_id"] == "g1"


# --------------------------- analyzer --------------------------- #


def _stuff_observations_for(name: str, store: OpponentStore, *, game_id: str = "g1") -> None:
    """Helper: add a representative slice of synthetic observations."""
    rows = [
        ObservationEvent(
            type="chat",
            tick=100,
            game_id=game_id,
            payload={"text": "It's not me. I was doing tasks.", "meeting": 1},
        ),
        ObservationEvent(
            type="chat",
            tick=110,
            game_id=game_id,
            payload={"text": "Vote nottoodumb3 — kinda sus.", "meeting": 1},
        ),
        ObservationEvent(
            type="vote",
            tick=200,
            game_id=game_id,
            payload={"target": "nottoodumb3", "meeting": 1, "is_skip": False},
        ),
        ObservationEvent(
            type="vote",
            tick=900,
            game_id=game_id,
            payload={"target": None, "meeting": 2, "is_skip": True},
        ),
        ObservationEvent(
            type="role_revealed",
            tick=1000,
            game_id=game_id,
            payload={"role": "crew"},
        ),
    ]
    for ev in rows:
        store.record(name, ev)


def test_analyze_no_llm_produces_profile(tmp_path):
    store = OpponentStore(root=tmp_path)
    _stuff_observations_for("nottoodumb1", store)

    profile = analyze_opponent("nottoodumb1", store, use_llm=False)
    assert profile.name == "nottoodumb1"
    assert profile.games_observed >= 1
    assert profile.vote_strategy.label != "unclassified"
    # Deterministic fallback caps confidence at 0.3 on first analysis.
    assert profile.confidence <= 0.35
    # Persisted to disk.
    on_disk = store.load_profile("nottoodumb1")
    assert on_disk is not None
    assert on_disk.name == "nottoodumb1"


def test_analyze_empty_store_does_not_crash(tmp_path):
    store = OpponentStore(root=tmp_path)
    profile = analyze_opponent("ghost", store, use_llm=False)
    assert profile.name == "ghost"
    assert profile.games_observed == 0
    assert profile.confidence == 0.0


def test_analyze_merges_with_prior_profile(tmp_path):
    store = OpponentStore(root=tmp_path)
    _stuff_observations_for("nottoodumb1", store, game_id="g1")
    p1 = analyze_opponent("nottoodumb1", store, use_llm=False)
    notes_after_first = p1.freeform_notes
    games_after_first = p1.games_observed
    assert games_after_first >= 1

    _stuff_observations_for("nottoodumb1", store, game_id="g2")
    p2 = analyze_opponent("nottoodumb1", store, use_llm=False)
    # Game count must grow monotonically.
    assert p2.games_observed >= games_after_first
    # Old freeform notes survive the merge as a "[prior @ ...]" prefix.
    assert "[prior @" in p2.freeform_notes
    assert notes_after_first.split("\n")[0].split("=")[0] in p2.freeform_notes


def test_merge_keeps_max_games_observed():
    p1 = OpponentProfile(name="x", games_observed=2, confidence=0.2)
    p2 = OpponentProfile(name="x", games_observed=1, confidence=0.5)
    merged = merge_profiles(p1, p2)
    assert merged.games_observed == 2
    assert merged.confidence >= max(p1.confidence, p2.confidence)


def test_statistical_fallback_chat_rate():
    rows = [
        ObservationEvent(
            type="chat",
            tick=t,
            game_id="g",
            payload={"text": "I was on tasks.", "meeting": m},
        )
        for t, m in ((10, 1), (20, 1), (30, 2))
    ]
    rows.append(
        ObservationEvent(
            type="vote",
            tick=40,
            game_id="g",
            payload={"target": "y", "meeting": 1, "is_skip": False},
        )
    )
    rows.append(
        ObservationEvent(
            type="vote",
            tick=50,
            game_id="g",
            payload={"target": "y", "meeting": 1, "is_skip": False},
        )
    )
    profile = analyze_opponent_statistical("x", rows)
    assert profile.games_observed == 1
    assert 0.0 <= profile.chat_style.chat_rate <= 1.0
    # "I was" / "tasks" → a defensive tone tag.
    assert "defensive" in profile.chat_style.tone_descriptors


# --------------------------- bundle / freeze --------------------------- #


def test_freeze_and_bundled_profile_lookup(tmp_path):
    store = OpponentStore(root=tmp_path / "store")
    store.save_profile("a", OpponentProfile(name="a", games_observed=2, confidence=0.5))
    store.save_profile("b", OpponentProfile(name="b", games_observed=1, confidence=0.3))

    snapshot = freeze_profiles(store, tmp_path / "snap.json")
    assert snapshot.exists()
    raw = json.loads(snapshot.read_text())
    assert raw["version"] == 1
    assert {p["name"] for p in raw["profiles"]} == {"a", "b"}

    lookup = BundledProfileLookup.from_path(snapshot)
    assert set(lookup.names()) == {"a", "b"}
    a = lookup["a"]
    assert isinstance(a, OpponentProfile)
    assert a.games_observed == 2
    assert lookup.get("c") is None


# --------------------------- consumer integration --------------------------- #


def test_llm_voter_accepts_opponent_profiles_kwarg():
    """Constructor must accept the kwarg without altering existing behavior.

    LLM is None (no API key in the test env), so the voter falls back
    to the scripted Voter — but the kwarg must still be accepted and
    stored.
    """
    profiles: dict[str, OpponentProfile] = {
        "nottoodumb1": OpponentProfile(name="nottoodumb1", games_observed=1),
    }
    voter = LLMVoter(opponent_profiles=profiles)
    assert voter.opponent_profiles is not None
    assert "nottoodumb1" in voter.opponent_profiles

    # Voting still works (scripted fallback) when llm is None.
    ctx = VotingContext(
        meeting_index=1,
        self_id="self",
        suspects=[
            SuspicionEntry(player_id="nottoodumb1", score=0.9, reasons=[], last_seen_tick=10)
        ],
    )
    vote = voter.vote(ctx)
    # Either scripted vote or skip — both are acceptable; we just need
    # the call to not raise from the kwarg plumbing.
    assert vote is not None


def test_llm_chatter_accepts_opponent_profiles_kwarg():
    from among_them_sdk import LLMChatter

    profiles = {"x": OpponentProfile(name="x", games_observed=1)}
    chatter = LLMChatter(opponent_profiles=profiles)
    assert chatter.opponent_profiles is profiles


def test_agent_create_loads_profiles_from_explicit_arg():
    from among_them_sdk import Agent

    profiles = {"x": OpponentProfile(name="x", games_observed=2, confidence=0.5)}
    agent = Agent.create(
        opponent_profiles=profiles,
        load_opponent_profiles=False,
        use_llm_for_instructions=False,
    )
    assert agent.opponent_profiles is profiles


# --------------------------- cli wiring sanity --------------------------- #


def test_cli_list_empty(tmp_path, capsys):
    """`python -m among_them_sdk.opponents list` prints friendly empty banner."""
    from among_them_sdk.opponents.__main__ import main as cli_main

    rc = cli_main(["--store-root", str(tmp_path), "list"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "no opponents" in out


def test_cli_freeze_empty_store_errors(tmp_path, capsys):
    from among_them_sdk.opponents.__main__ import main as cli_main

    snap = tmp_path / "snap.json"
    rc = cli_main(["--store-root", str(tmp_path), "freeze", "--output", str(snap)])
    assert rc == 1


def test_cli_freeze_writes_snapshot(tmp_path):
    """End-to-end: write a profile, then freeze via CLI."""
    from among_them_sdk.opponents.__main__ import main as cli_main

    store = OpponentStore(root=tmp_path)
    store.save_profile(
        "nottoodumb1", OpponentProfile(name="nottoodumb1", games_observed=2, confidence=0.4)
    )
    snap = tmp_path / "snap.json"
    rc = cli_main(["--store-root", str(tmp_path), "freeze", "--output", str(snap)])
    assert rc == 0
    assert snap.exists()
    lookup = BundledProfileLookup.from_path(snap)
    assert "nottoodumb1" in lookup


# --------------------------- edge cases --------------------------- #


def test_role_conditional_serializes_to_known_keys_only(tmp_path):
    """Unknown role keys must be silently dropped on validate."""
    raw = {
        "name": "x",
        "games_observed": 1,
        "role_conditional": {
            "crew": {"games_seen": 1, "play_pattern": "p", "chat_strategy": "", "notable_tells": []},
            "auto": {"games_seen": 1, "play_pattern": "p", "chat_strategy": "", "notable_tells": []},
        },
    }
    profile = OpponentProfile.model_validate(raw)
    assert "crew" in profile.role_conditional
    assert "auto" not in profile.role_conditional


@pytest.mark.parametrize(
    "name,is_self",
    [
        ("self", True),
        ("nottoodumb1", False),
        ("", False),
    ],
)
def test_collector_self_filtering(tmp_path, name, is_self):
    store = OpponentStore(root=tmp_path)
    c = ObservationCollector(store=store, game_id="g", self_id="self")
    c.hooks.call("on_message", {"actor": name, "text": "x", "meeting": 1})
    rows = store.log_for(name).all()
    if is_self or not name:
        assert rows == []
    else:
        assert len(rows) == 1
