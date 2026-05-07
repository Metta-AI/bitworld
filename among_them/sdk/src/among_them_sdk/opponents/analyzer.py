"""Build :class:`OpponentProfile` from accumulated observations.

Two paths, mirroring :mod:`cognition.instructions`:

  * :func:`analyze_opponent_with_llm` — calls an LLM with a structured
    JSON prompt and parses the response into :class:`OpponentProfile`.
    Used when an API key is available.
  * :func:`analyze_opponent_statistical` — pure-Python statistical
    summary. Caps confidence at 0.3 because deterministic counting is a
    weaker signal than an LLM that can read chat tone. Always
    available; the verification suite relies on this path.

Both paths take the same arguments and produce the same model. The
top-level :func:`analyze_opponent` picks the right one and merges with
any prior profile so confidence + game count grow monotonically.
"""

from __future__ import annotations

import json
import logging
import re
import time
from collections import Counter
from typing import Any

from .models import (
    AccusationProfile,
    ChatStyleProfile,
    ConditionalBehavior,
    DefenseProfile,
    ObservationEvent,
    OpponentProfile,
    Role,
    VoteStrategyProfile,
)
from .store import OpponentStore

logger = logging.getLogger("among_them_sdk.opponents.analyzer")


# ----------------------------- helpers ----------------------------- #


def _events_by_game(events: list[ObservationEvent]) -> dict[str, list[ObservationEvent]]:
    out: dict[str, list[ObservationEvent]] = {}
    for ev in events:
        out.setdefault(ev.game_id or "_nogame", []).append(ev)
    return out


def _safe_str(v: Any) -> str:
    return v if isinstance(v, str) else ""


# ----------------------------- statistical fallback ----------------------------- #


def analyze_opponent_statistical(
    name: str,
    events: list[ObservationEvent],
) -> OpponentProfile:
    """Deterministic fallback profile from observed events.

    Pure-Python counting + thresholds. Output ``confidence`` is capped at
    0.3 because a few statistics shouldn't outrank an LLM-derived
    profile when one becomes available later. The merge step in
    :func:`analyze_opponent` respects this ordering.
    """
    by_game = _events_by_game(events)
    games_observed = len([g for g in by_game if g != "_nogame"]) or (
        1 if events else 0
    )

    # ---- Chat style stats. ---- #
    chats = [ev for ev in events if ev.type == "chat"]
    meetings_seen_with_chat: set[tuple[str, int]] = set()
    chat_lengths: list[int] = []
    common_words: Counter[str] = Counter()
    addresses_others = 0
    for ev in chats:
        text = _safe_str(ev.payload.get("text"))
        meeting = ev.payload.get("meeting") or 0
        if ev.game_id:
            meetings_seen_with_chat.add((ev.game_id, int(meeting)))
        chat_lengths.append(len(text))
        # Word frequency for common phrases — lowercased, alpha-only,
        # ignore single-char tokens. Don't bother with stemming.
        for w in re.findall(r"[a-zA-Z']{3,}", text.lower()):
            common_words[w] += 1
        if re.search(r"\b[A-Z][a-zA-Z0-9_-]+\b", text):
            addresses_others += 1

    total_meetings = len({
        (ev.game_id, int(ev.payload.get("meeting") or 0))
        for ev in events
        if ev.type in {"chat", "vote"} and ev.game_id
    }) or 1
    chat_rate = min(1.0, len(meetings_seen_with_chat) / max(1, total_meetings))
    avg_msg_len = sum(chat_lengths) / len(chat_lengths) if chat_lengths else 0.0
    addresses_rate = (addresses_others / len(chats)) if chats else 0.0
    common_phrases = [w for w, _ in common_words.most_common(5)]

    # Naive tone heuristics from common keywords.
    text_blob = " ".join(_safe_str(ev.payload.get("text")) for ev in chats).lower()
    tone_descriptors: list[str] = []
    if any(k in text_blob for k in ("not me", "wasn't me", "i was", "i didn't")):
        tone_descriptors.append("defensive")
    if any(k in text_blob for k in ("sus", "suspicious", "kinda sus")):
        tone_descriptors.append("suspicious")
    if any(k in text_blob for k in ("trust", "team", "with you")):
        tone_descriptors.append("conciliatory")
    if any(k in text_blob for k in ("kill", "imposter", "vent")):
        tone_descriptors.append("aggressive")
    if not tone_descriptors and chats:
        tone_descriptors.append("neutral")

    chat_style = ChatStyleProfile(
        avg_message_length=round(avg_msg_len, 2),
        chat_rate=round(chat_rate, 3),
        tone_descriptors=tone_descriptors,
        common_phrases=common_phrases,
        addresses_others=addresses_rate >= 0.3,
    )

    # ---- Voting stats. ---- #
    votes = [ev for ev in events if ev.type == "vote"]
    skips = sum(1 for ev in votes if ev.payload.get("is_skip"))
    skip_rate = (skips / len(votes)) if votes else 0.0
    # Majority approximation: per (game_id, meeting), the most-frequent
    # non-skip target is the "majority". We can't compute that without
    # *all* voters' rows; statistical approximation here is just "did
    # this opponent vote for the same target as anyone else?". The
    # analyzer's caller can layer richer logic.
    follow_majority = 0
    counted = 0
    for _game_id, group in by_game.items():
        per_meeting: dict[int, list[str]] = {}
        for ev in group:
            if ev.type != "vote":
                continue
            tgt = ev.payload.get("target")
            meeting = int(ev.payload.get("meeting") or 0)
            if isinstance(tgt, str) and tgt:
                per_meeting.setdefault(meeting, []).append(tgt)
        for tgts in per_meeting.values():
            if len(tgts) <= 1:
                continue
            counts = Counter(tgts)
            top, top_n = counts.most_common(1)[0]
            for t in tgts:
                counted += 1
                if t == top and top_n >= 2:
                    follow_majority += 1
    follow_rate = (follow_majority / counted) if counted else 0.0

    label = "unclassified"
    if votes:
        if skip_rate >= 0.5:
            label = "skipper"
        elif follow_rate >= 0.5:
            label = "bandwagoner"
        elif skip_rate < 0.2 and follow_rate < 0.3:
            label = "evidence_grounded"
        else:
            label = "erratic"

    avg_meet_to_first = 0.0
    if votes:
        first_meeting_per_game: dict[str, int] = {}
        for ev in votes:
            gid = ev.game_id or "_nogame"
            meeting = int(ev.payload.get("meeting") or 0)
            if gid not in first_meeting_per_game or meeting < first_meeting_per_game[gid]:
                first_meeting_per_game[gid] = meeting
        if first_meeting_per_game:
            avg_meet_to_first = sum(first_meeting_per_game.values()) / len(
                first_meeting_per_game
            )

    vote_strategy = VoteStrategyProfile(
        label=label,
        skip_rate=round(skip_rate, 3),
        follow_majority_rate=round(follow_rate, 3),
        avg_meetings_to_first_vote=round(avg_meet_to_first, 2),
        notes=[
            f"votes_seen={len(votes)}",
            f"skips={skips}",
            f"counted_majority_pairs={counted}",
        ],
    )

    # ---- Accusations. ---- #
    accuses = [ev for ev in events if ev.type == "accused"]
    typical_targets: list[str] = []
    for ev in accuses:
        t = _safe_str(ev.payload.get("target"))
        if t and t not in typical_targets:
            typical_targets.append(t)
    accuses_per_meeting = (len(accuses) / max(1, total_meetings)) if accuses else 0.0
    accusation = AccusationProfile(
        accusations_per_meeting=round(accuses_per_meeting, 3),
        accuses_aggressively=accuses_per_meeting >= 1.0,
        typical_targets=typical_targets[:5],
    )

    # ---- Defensiveness. ---- #
    accused_by = [ev for ev in events if ev.type == "accused_by"]
    defensive_chats = sum(
        1
        for ev in chats
        if any(
            k in _safe_str(ev.payload.get("text")).lower()
            for k in ("not me", "i was", "i didn't", "wasn't me", "don't")
        )
    )
    defensiveness_score = 0.0
    counter_accuses = False
    goes_silent = False
    if accused_by:
        defensiveness_score = min(1.0, defensive_chats / len(accused_by))
        # If they almost never speak when accused, we mark "goes silent."
        speaks_when_accused = sum(
            1 for ev in accused_by if any(
                ch.tick >= ev.tick - 60 and ch.tick <= ev.tick + 600
                for ch in chats
            )
        )
        if accused_by and speaks_when_accused / max(1, len(accused_by)) < 0.2:
            goes_silent = True
        counter_accuses = (
            sum(1 for ev in accuses if ev.tick >= 0) >= len(accused_by) * 0.5
        )
    defense = DefenseProfile(
        defensiveness_score=round(defensiveness_score, 3),
        counter_accuses=counter_accuses,
        goes_silent_when_pressured=goes_silent,
        typical_defenses=[],
    )

    # ---- Role-conditional behavior. ---- #
    role_conditional: dict[Role, ConditionalBehavior] = {}
    role_events = [ev for ev in events if ev.type == "role_revealed"]
    role_counts: Counter[str] = Counter()
    for ev in role_events:
        role = _safe_str(ev.payload.get("role"))
        if role in {"crew", "imposter", "unknown"}:
            role_counts[role] += 1
    for role_name, count in role_counts.items():
        kills_in_role = sum(
            1 for ev in events if ev.type == "kill" and ev.game_id and any(
                rev.game_id == ev.game_id and _safe_str(rev.payload.get("role")) == role_name
                for rev in role_events
            )
        )
        role_conditional[role_name] = ConditionalBehavior(  # type: ignore[index]
            games_seen=count,
            play_pattern=(
                f"observed {count} games as {role_name}; {kills_in_role} kills"
            ),
            chat_strategy="",
            notable_tells=[],
        )

    # ---- Confidence. ---- #
    # Cap at 0.3 to leave headroom for the LLM analyzer to claim more.
    raw_confidence = min(0.3, 0.05 + 0.05 * games_observed)
    notes = (
        f"deterministic-fallback analyzer; "
        f"games={games_observed}, votes={len(votes)}, chats={len(chats)}, "
        f"accusations={len(accuses)}"
    )

    profile = OpponentProfile(
        name=name,
        games_observed=games_observed,
        last_updated_at=time.time(),
        chat_style=chat_style,
        vote_strategy=vote_strategy,
        accusation_tendency=accusation,
        defensiveness=defense,
        alliance_patterns=[],
        role_conditional=role_conditional,
        confidence=round(raw_confidence, 2),
        freeform_notes=notes,
    )
    return profile


# ----------------------------- LLM path ----------------------------- #


_LLM_SYSTEM = """You are an analyst building a behavioral profile of an Among Them
opponent. Given a list of observation events (chat lines, vote choices,
kills/deaths, role reveals), produce a strict JSON object matching this
schema. Do not invent fields. Use plain, observation-grounded language.

Schema:

{
  "name": str,
  "games_observed": int,
  "chat_style": {
    "avg_message_length": float,
    "chat_rate": float in [0,1],
    "tone_descriptors": list[str],
    "common_phrases": list[str],
    "addresses_others": bool
  },
  "vote_strategy": {
    "label": str,                          // evidence_grounded | bandwagoner |
                                            //   contrarian | skipper | erratic |
                                            //   aggressive_imposter | unclassified
    "skip_rate": float in [0,1],
    "follow_majority_rate": float in [0,1],
    "avg_meetings_to_first_vote": float,
    "notes": list[str]
  },
  "accusation_tendency": {
    "accusations_per_meeting": float,
    "accuses_aggressively": bool,
    "typical_targets": list[str]
  },
  "defensiveness": {
    "defensiveness_score": float in [0,1],
    "counter_accuses": bool,
    "goes_silent_when_pressured": bool,
    "typical_defenses": list[str]
  },
  "alliance_patterns": list[str],
  "role_conditional": {
    "crew": {"games_seen": int, "play_pattern": str, "chat_strategy": str,
              "notable_tells": list[str]},
    "imposter": {...same shape...}
  },
  "confidence": float in [0,1],
  "freeform_notes": str
}

Output ONLY the JSON object. Do not include markdown fences."""


def _events_to_prompt(name: str, events: list[ObservationEvent]) -> str:
    """Render the observations as a compact event log for the LLM."""
    by_game = _events_by_game(events)
    lines: list[str] = [f"Opponent: {name}", f"Games observed: {len(by_game)}"]
    for game_id, group in by_game.items():
        lines.append("")
        lines.append(f"Game {game_id}:")
        for ev in group[:80]:  # cap to keep token budget bounded
            payload_summary = ", ".join(
                f"{k}={v!r}"
                for k, v in ev.payload.items()
                if k not in {"snippet", "via"}
            )
            snippet = ev.payload.get("snippet") or ev.payload.get("text") or ""
            if isinstance(snippet, str):
                snippet = snippet[:60]
            line = f"  t={ev.tick} {ev.type}: {payload_summary}"
            if snippet:
                line += f" :: {snippet!r}"
            lines.append(line)
        if len(group) > 80:
            lines.append(f"  ... {len(group) - 80} more events")
    return "\n".join(lines)


def analyze_opponent_with_llm(
    name: str,
    events: list[ObservationEvent],
    *,
    llm: Any,
    fallback: OpponentProfile,
) -> OpponentProfile:
    """Call the LLM and coerce the response into :class:`OpponentProfile`.

    On any failure (network, JSON parse, schema), returns ``fallback``
    unchanged. The deterministic fallback always produces a valid
    profile, so the analyzer never blows up.
    """
    user_prompt = _events_to_prompt(name, events)
    try:
        resp = llm.complete(
            system=_LLM_SYSTEM,
            user=user_prompt,
            response_format="json",
            temperature=0.2,
            max_tokens=1500,
        )
    except Exception as exc:
        logger.warning("LLM analyze_opponent failed (%s); using fallback", exc)
        return fallback

    text = (resp.text or "").strip()
    try:
        match = re.search(r"\{.*\}", text, re.DOTALL)
        if match is None:
            raise ValueError("no JSON object in LLM response")
        data = json.loads(match.group(0))
        # Force the analyzer to honor the input name regardless of what
        # the model echoes back.
        data["name"] = name
        # Keep at least the games count from observations even if the
        # model under-counts; we own that signal.
        data.setdefault("games_observed", fallback.games_observed)
        data.setdefault(
            "freeform_notes",
            f"LLM analyzer; n={fallback.games_observed}",
        )
        data["last_updated_at"] = time.time()
        profile = OpponentProfile.model_validate(data)
        # LLM gets a higher confidence floor than the fallback (0.3 cap)
        # but we still bound it from blowing up to 1.0 on tiny samples.
        observed = profile.games_observed or fallback.games_observed
        ceiling = min(0.95, 0.5 + 0.05 * max(0, observed - 1))
        profile = profile.model_copy(
            update={"confidence": min(profile.confidence or 0.5, ceiling)}
        )
        return profile
    except Exception as exc:
        logger.warning(
            "LLM response did not match schema (%s); falling back. raw=%r",
            exc,
            text[:240],
        )
        return fallback


# ----------------------------- merge ----------------------------- #


def merge_profiles(
    prior: OpponentProfile | None, fresh: OpponentProfile
) -> OpponentProfile:
    """Combine ``prior`` and ``fresh`` so prior intel isn't lost.

    Rules:

      * Prior wins on monotonic counters (games_observed = max).
      * Fresh wins on the analyzed fields (confidence-weighted).
      * Freeform notes are concatenated, prior first, separated by a
        timestamped divider so the history is auditable.
      * Role-conditional dicts merge per role: prior + fresh, fresh
        wins on overlap, but prior's tells are preserved.
    """
    if prior is None:
        return fresh

    fresh_w = max(0.0, min(1.0, fresh.confidence or 0.0))
    prior_w = max(0.0, min(1.0, prior.confidence or 0.0))
    total_w = fresh_w + prior_w
    if total_w <= 0.0:
        # Neither side is confident; simple union.
        prior_w = fresh_w = 0.5
        total_w = 1.0

    def _blend(a: float, b: float) -> float:
        return (a * prior_w + b * fresh_w) / total_w

    chat_style = ChatStyleProfile(
        avg_message_length=round(
            _blend(prior.chat_style.avg_message_length, fresh.chat_style.avg_message_length),
            2,
        ),
        chat_rate=round(
            _blend(prior.chat_style.chat_rate, fresh.chat_style.chat_rate), 3
        ),
        tone_descriptors=list(
            dict.fromkeys(prior.chat_style.tone_descriptors + fresh.chat_style.tone_descriptors)
        )[:6],
        common_phrases=list(
            dict.fromkeys(prior.chat_style.common_phrases + fresh.chat_style.common_phrases)
        )[:8],
        addresses_others=fresh.chat_style.addresses_others or prior.chat_style.addresses_others,
    )

    vote = VoteStrategyProfile(
        label=fresh.vote_strategy.label or prior.vote_strategy.label,
        skip_rate=round(
            _blend(prior.vote_strategy.skip_rate, fresh.vote_strategy.skip_rate), 3
        ),
        follow_majority_rate=round(
            _blend(
                prior.vote_strategy.follow_majority_rate,
                fresh.vote_strategy.follow_majority_rate,
            ),
            3,
        ),
        avg_meetings_to_first_vote=round(
            _blend(
                prior.vote_strategy.avg_meetings_to_first_vote,
                fresh.vote_strategy.avg_meetings_to_first_vote,
            ),
            2,
        ),
        notes=list(dict.fromkeys(prior.vote_strategy.notes + fresh.vote_strategy.notes))[:8],
    )

    accusation = AccusationProfile(
        accusations_per_meeting=round(
            _blend(
                prior.accusation_tendency.accusations_per_meeting,
                fresh.accusation_tendency.accusations_per_meeting,
            ),
            3,
        ),
        accuses_aggressively=fresh.accusation_tendency.accuses_aggressively
        or prior.accusation_tendency.accuses_aggressively,
        typical_targets=list(
            dict.fromkeys(
                prior.accusation_tendency.typical_targets
                + fresh.accusation_tendency.typical_targets
            )
        )[:8],
    )

    defense = DefenseProfile(
        defensiveness_score=round(
            _blend(prior.defensiveness.defensiveness_score, fresh.defensiveness.defensiveness_score),
            3,
        ),
        counter_accuses=fresh.defensiveness.counter_accuses or prior.defensiveness.counter_accuses,
        goes_silent_when_pressured=(
            fresh.defensiveness.goes_silent_when_pressured
            or prior.defensiveness.goes_silent_when_pressured
        ),
        typical_defenses=list(
            dict.fromkeys(
                prior.defensiveness.typical_defenses + fresh.defensiveness.typical_defenses
            )
        )[:8],
    )

    role_conditional: dict[Role, ConditionalBehavior] = {}
    for role in {*prior.role_conditional.keys(), *fresh.role_conditional.keys()}:
        p = prior.role_conditional.get(role)  # type: ignore[index]
        f = fresh.role_conditional.get(role)  # type: ignore[index]
        if p is None and f is None:
            continue
        if p is None:
            role_conditional[role] = f  # type: ignore[index,assignment]
            continue
        if f is None:
            role_conditional[role] = p  # type: ignore[index,assignment]
            continue
        role_conditional[role] = ConditionalBehavior(  # type: ignore[index]
            games_seen=max(p.games_seen, f.games_seen),
            play_pattern=f.play_pattern or p.play_pattern,
            chat_strategy=f.chat_strategy or p.chat_strategy,
            notable_tells=list(dict.fromkeys(p.notable_tells + f.notable_tells))[:8],
        )

    alliance = list(dict.fromkeys(prior.alliance_patterns + fresh.alliance_patterns))[:6]

    # Confidence: bounded average + a small bonus for repeated analysis.
    new_conf = max(prior.confidence, fresh.confidence)
    new_conf = min(0.99, new_conf + 0.02)

    notes_parts: list[str] = []
    if prior.freeform_notes:
        notes_parts.append(f"[prior @ {time.strftime('%Y-%m-%dT%H:%M', time.gmtime(prior.last_updated_at))}]")
        notes_parts.append(prior.freeform_notes.strip())
    if fresh.freeform_notes:
        notes_parts.append(f"[fresh @ {time.strftime('%Y-%m-%dT%H:%M', time.gmtime(fresh.last_updated_at))}]")
        notes_parts.append(fresh.freeform_notes.strip())
    notes = "\n".join(notes_parts)
    # Cap notes length so the file doesn't grow unbounded across many merges.
    if len(notes) > 4000:
        notes = notes[-4000:]

    return OpponentProfile(
        name=fresh.name or prior.name,
        games_observed=max(prior.games_observed, fresh.games_observed),
        last_updated_at=time.time(),
        chat_style=chat_style,
        vote_strategy=vote,
        accusation_tendency=accusation,
        defensiveness=defense,
        alliance_patterns=alliance,
        role_conditional=role_conditional,
        confidence=round(new_conf, 3),
        freeform_notes=notes,
    )


# ----------------------------- entrypoint ----------------------------- #


def analyze_opponent(
    name: str,
    store: OpponentStore,
    *,
    llm: Any | None = None,
    recent_games: int = 10,
    use_llm: bool = True,
    model: str = "gpt-5.5",
) -> OpponentProfile:
    """Analyze ``name`` and persist the resulting profile to disk.

    Parameters
    ----------
    name:
        Opponent name (matches what the collector recorded).
    store:
        :class:`OpponentStore` to read observations and write profile.
    llm:
        Optional pre-built LLM. ``None`` → try to construct one if
        ``use_llm`` is True and an API key is available.
    recent_games:
        Restrict analysis to the last K games' observations.
    use_llm:
        If False, skip the LLM path entirely (deterministic fallback).
    model:
        Model id passed to :class:`among_them_sdk.cognition.llm.LLM`.

    Returns
    -------
    OpponentProfile
        The merged profile (prior on disk + freshly analyzed). Always
        valid even when no observations exist.
    """
    events = store.load_observations(name, recent_games=recent_games)
    if not events:
        # No observations yet — return / persist an empty profile so
        # downstream consumers can still find this name.
        empty = OpponentProfile(
            name=name,
            games_observed=0,
            confidence=0.0,
            freeform_notes="no observations yet",
        )
        prior = store.load_profile(name)
        merged = merge_profiles(prior, empty)
        store.save_profile(name, merged)
        return merged

    fallback = analyze_opponent_statistical(name, events)

    fresh: OpponentProfile = fallback
    if use_llm:
        active_llm = llm
        if active_llm is None:
            from ..cognition.llm import LLM, LLMUnavailableError

            try:
                active_llm = LLM(model=model)
            except LLMUnavailableError:
                active_llm = None
        if active_llm is not None:
            fresh = analyze_opponent_with_llm(
                name, events, llm=active_llm, fallback=fallback
            )

    prior = store.load_profile(name)
    merged = merge_profiles(prior, fresh)
    store.save_profile(name, merged)
    return merged


def analyze_all(
    store: OpponentStore,
    *,
    llm: Any | None = None,
    recent_games: int = 10,
    use_llm: bool = True,
    model: str = "gpt-5.5",
) -> dict[str, OpponentProfile]:
    """Run :func:`analyze_opponent` for every known opponent.

    Returns a ``{name: profile}`` map of every analyzed opponent.
    """
    out: dict[str, OpponentProfile] = {}
    for name in store.list_opponents():
        out[name] = analyze_opponent(
            name,
            store,
            llm=llm,
            recent_games=recent_games,
            use_llm=use_llm,
            model=model,
        )
    return out


__all__ = [
    "analyze_all",
    "analyze_opponent",
    "analyze_opponent_statistical",
    "analyze_opponent_with_llm",
    "merge_profiles",
]
