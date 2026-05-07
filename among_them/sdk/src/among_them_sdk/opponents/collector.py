"""Translate runtime hooks into per-opponent :class:`ObservationEvent` rows.

Usage::

    collector = ObservationCollector(store=OpponentStore(), game_id="abc")
    agent = Agent.create(hooks=collector.hooks)
    ...
    collector.flush_game_end(roles={"nottoodumb1": "imposter", ...},
                              alive_at_end={"nottoodumb1", "nottoodumb3"})

The collector listens to ``on_message``, ``on_vote``, ``on_meeting``, and
``on_kill`` (the four hooks declared in :class:`AgentHooks`). For each
event it derives one or more :class:`ObservationEvent` rows and records
them on the relevant opponents.

Hook payload conventions
------------------------

The SDK's runtime fires hooks with dict payloads but the *shape* of those
payloads varies a bit across runtimes (the synthetic ``LocalSim`` path
fires synthesized payloads, ``LiveGame`` only fires ``on_message`` for
chat the SDK player itself sent). The collector tolerates missing keys
and ignores events about ``self_id`` (we never record the SDK player as
its own opponent).

Recognized payload keys (all optional except ``type``-implied ones):

  * ``actor`` / ``speaker`` / ``author`` — the opponent who *did* the
    thing. Aliases for "whose action is this".
  * ``target`` — the opponent who was *targeted* (vote target, kill
    victim, accusation target).
  * ``text`` — chat string (``on_message``).
  * ``meeting`` / ``meeting_index`` — meeting number.
  * ``tick`` — tick at which the event happened.
  * ``self_id`` — optional self-tag so the collector skips events
    about its own player.
  * ``role`` — when present on game-end events, recorded as
    ``role_revealed``.

Anything else is forwarded into ``ObservationEvent.payload`` verbatim.
"""

from __future__ import annotations

import logging
import re
import uuid
from dataclasses import dataclass, field
from typing import Any

from ..hooks import AgentHooks
from .models import ObservationEvent
from .store import OpponentStore

logger = logging.getLogger("among_them_sdk.opponents.collector")


def _new_game_id() -> str:
    return uuid.uuid4().hex[:8]


@dataclass
class ObservationCollector:
    """Hooks-into-store translator.

    One instance per game. Construct, attach the ``hooks`` attribute to
    an :class:`Agent`, run the game, then call
    :meth:`flush_game_end` with the per-opponent role/alive info that
    the SDK can only see post-game.

    Attributes
    ----------
    store: OpponentStore
        Where observations get persisted.
    game_id: str
        Stable id stamped onto every event in this game. Auto-generated
        if not provided.
    self_id: str | None
        The SDK player's own name. Events about ``self_id`` are skipped
        — we never record ourselves as an opponent.
    known_opponents: list[str]
        Optional hint for opponent name detection inside chat strings.
        When set, ``on_message`` events scan ``text`` for these names
        and emit ``accused_by`` / ``accused`` rows when a name appears.
    """

    store: OpponentStore
    game_id: str = field(default_factory=_new_game_id)
    self_id: str | None = None
    known_opponents: list[str] = field(default_factory=list)
    _meeting_index: int = 0
    _votes_observed: int = 0
    _chats_observed: int = 0
    _kills_observed: int = 0
    _meetings_observed: int = 0

    @property
    def hooks(self) -> AgentHooks:
        """Build an :class:`AgentHooks` wired to this collector's translators.

        Re-creates the AgentHooks each call (cheap) so the collector can
        be plugged into multiple agents in the same game without sharing
        a single hooks object.
        """
        return AgentHooks(
            on_message=self._on_message,
            on_vote=self._on_vote,
            on_meeting=self._on_meeting,
            on_kill=self._on_kill,
        )

    # ------------------------------ helpers ------------------------------ #

    def _is_self(self, who: str | None) -> bool:
        return bool(who) and self.self_id is not None and who == self.self_id

    def _record(
        self,
        name: str,
        event_type: str,
        *,
        tick: int = 0,
        payload: dict[str, Any] | None = None,
    ) -> None:
        if not name:
            return
        if self._is_self(name):
            return
        try:
            event = ObservationEvent(
                type=event_type,  # type: ignore[arg-type]
                tick=int(tick) if isinstance(tick, (int, float)) else 0,
                game_id=self.game_id,
                payload=dict(payload or {}),
            )
        except Exception as exc:  # pragma: no cover - schema drift
            logger.debug("skipping event %s/%s: %s", name, event_type, exc)
            return
        self.store.record(name, event)

    @staticmethod
    def _actor_of(payload: dict[str, Any]) -> str | None:
        for key in ("actor", "speaker", "author", "from", "name", "player"):
            v = payload.get(key)
            if isinstance(v, str) and v:
                return v
        return None

    @staticmethod
    def _target_of(payload: dict[str, Any]) -> str | None:
        for key in ("target", "victim", "to", "accused"):
            v = payload.get(key)
            if isinstance(v, str) and v:
                return v
        return None

    @staticmethod
    def _tick_of(payload: dict[str, Any]) -> int:
        for key in ("tick", "frame", "ticks"):
            v = payload.get(key)
            if isinstance(v, (int, float)):
                return int(v)
        return 0

    def _detect_accusations(self, speaker: str, text: str) -> list[str]:
        """Return opponent names mentioned in ``text`` as accusation targets.

        Naive: substring match against ``known_opponents``. The
        analyzer reading this signal weights it gently — false positives
        from someone defending themselves by name don't break the
        profile.
        """
        if not text or not self.known_opponents:
            return []
        targets: list[str] = []
        lo = text.lower()
        for name in self.known_opponents:
            if name == speaker:
                continue
            # Word-boundary match where possible; fall back to substring
            # for names with non-word characters.
            if re.search(rf"\b{re.escape(name.lower())}\b", lo):
                targets.append(name)
            elif name.lower() in lo:
                targets.append(name)
        return targets

    # ------------------------------ hooks ------------------------------ #

    def _on_message(self, payload: dict[str, Any]) -> None:
        speaker = self._actor_of(payload) or ""
        text = str(payload.get("text") or "").strip()
        meeting = int(
            payload.get("meeting") or payload.get("meeting_index") or 0 or 0
        )
        tick = self._tick_of(payload)
        if not speaker:
            return
        self._chats_observed += 1
        chat_payload: dict[str, Any] = {
            "text": text,
            "meeting": meeting,
        }
        # Attach any non-conventional keys verbatim for downstream analysis.
        for k, v in payload.items():
            if k not in {
                "actor", "speaker", "author", "from", "name", "player",
                "text", "meeting", "meeting_index", "tick", "self_id",
            }:
                chat_payload[k] = v
        self._record(speaker, "chat", tick=tick, payload=chat_payload)

        for target in self._detect_accusations(speaker, text):
            if self._is_self(target):
                # Someone accused *us*.
                self._record(
                    speaker,
                    "accused",
                    tick=tick,
                    payload={"target": "self", "via": "chat", "snippet": text[:80]},
                )
                continue
            self._record(
                speaker,
                "accused",
                tick=tick,
                payload={"target": target, "via": "chat", "snippet": text[:80]},
            )
            self._record(
                target,
                "accused_by",
                tick=tick,
                payload={"by": speaker, "via": "chat", "snippet": text[:80]},
            )

    def _on_vote(self, payload: dict[str, Any]) -> None:
        actor = self._actor_of(payload) or ""
        target = self._target_of(payload)
        meeting = int(
            payload.get("meeting") or payload.get("meeting_index") or 0 or 0
        )
        reason = str(payload.get("reason") or "")
        tick = self._tick_of(payload)

        if not actor:
            return
        self._votes_observed += 1
        self._record(
            actor,
            "vote",
            tick=tick,
            payload={
                "target": target,
                "is_skip": target is None,
                "meeting": meeting,
                "reason": reason,
            },
        )

    def _on_meeting(self, payload: dict[str, Any]) -> None:
        index = int(
            payload.get("meeting_index") or payload.get("meeting") or 0
        )
        self._meeting_index = max(self._meeting_index, index)
        self._meetings_observed += 1
        caller = self._actor_of(payload) or payload.get("called_by")
        body = payload.get("body_player_id") or payload.get("body")
        tick = self._tick_of(payload)
        if isinstance(caller, str) and caller:
            self._record(
                caller,
                "meeting_called",
                tick=tick,
                payload={
                    "meeting": index,
                    "body": body,
                },
            )
        # We also stamp a "meeting_called" event on the body's victim
        # if known, since the body finder is interesting too. The
        # analyzer can use this as a who-finds-bodies signal.
        if isinstance(body, str) and body and isinstance(caller, str) and caller:
            self._record(
                body,
                "killed",
                tick=tick,
                payload={"discovered_by": caller, "meeting": index},
            )

    def _on_kill(self, payload: dict[str, Any]) -> None:
        attacker = self._actor_of(payload) or ""
        victim = self._target_of(payload) or ""
        tick = self._tick_of(payload)
        if not attacker and not victim:
            return
        self._kills_observed += 1
        if attacker:
            self._record(
                attacker,
                "kill",
                tick=tick,
                payload={"victim": victim or "?"},
            )
        if victim:
            self._record(
                victim,
                "killed",
                tick=tick,
                payload={"attacker": attacker or "?"},
            )

    # ------------------------------ post-game ------------------------------ #

    def flush_game_end(
        self,
        *,
        roles: dict[str, str] | None = None,
        alive_at_end: set[str] | list[str] | None = None,
    ) -> None:
        """Stamp post-game role + alive observations onto each named opponent.

        Call exactly once per game, after the server's final
        ``scores.json`` (or equivalent) has been read. ``roles`` maps
        opponent name → ``"crew" | "imposter" | "unknown"``;
        ``alive_at_end`` is the set of opponent names still alive at
        the end.
        """
        roles = roles or {}
        alive_set: set[str] = set(alive_at_end or [])
        all_named: set[str] = set(roles) | alive_set
        for name in all_named:
            if self._is_self(name):
                continue
            if name in roles:
                self._record(
                    name,
                    "role_revealed",
                    payload={
                        "role": roles[name],
                        "meetings_observed": self._meetings_observed,
                    },
                )
            if name in alive_set:
                self._record(
                    name,
                    "alive_at_end",
                    payload={"alive": True},
                )

    def stats(self) -> dict[str, Any]:
        """Counters for sanity checks. Used by the CLI's `record` subcommand."""
        return {
            "game_id": self.game_id,
            "self_id": self.self_id,
            "chats_observed": self._chats_observed,
            "votes_observed": self._votes_observed,
            "meetings_observed": self._meetings_observed,
            "kills_observed": self._kills_observed,
            "store_root": str(self.store.root),
        }


__all__ = ["ObservationCollector"]
