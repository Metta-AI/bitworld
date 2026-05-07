"""Chatter module — meeting-time text emission."""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from collections.abc import Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from ..opponents.models import OpponentProfile

logger = logging.getLogger("among_them_sdk.modules.chatter")


@dataclass
class ChatContext:
    self_id: str
    meeting_index: int
    suspect_summary: str = ""
    body_player_id: str | None = None
    last_messages: list[str] | None = None
    extras: dict[str, Any] | None = None


class Chatter(ABC):
    @abstractmethod
    def speak(self, ctx: ChatContext) -> str | None: ...


class SilentChatter(Chatter):
    """Emit nothing — match evidencebot_v2's silent-by-default posture."""

    def speak(self, ctx: ChatContext) -> str | None:
        return None


class ScriptedChatter(Chatter):
    """Templated chat: a few stock lines parameterized by tone + body info."""

    _TEMPLATES = {
        "neutral": "I have nothing useful yet. What did everyone see?",
        "suspicious": "Something feels off. Who can vouch for {top_suspect}?",
        "defensive": "I was doing tasks. Don't pin this on me.",
        "paranoid": "Could be anyone. Watch each other carefully.",
        "friendly": "Anyone want to share what they saw?",
    }

    def __init__(self, tone: str = "neutral"):
        self.tone = tone

    def speak(self, ctx: ChatContext) -> str | None:
        template = self._TEMPLATES.get(self.tone, self._TEMPLATES["neutral"])
        top = ctx.extras.get("top_suspect", "someone") if ctx.extras else "someone"
        return template.format(top_suspect=top)


class LLMChatter(Chatter):
    """Generate one-line meeting messages with an LLM.

    Optional ``opponent_profiles`` argument injects a compact summary of
    relevant opponents into the prompt so the LLM can taunt the
    bandwagoner, soften the paranoid one, etc. Set to ``None`` (default)
    to keep the pre-existing behavior.
    """

    def __init__(
        self,
        llm: object | None = None,
        *,
        model: str = "gpt-5.5",
        tone: str = "neutral",
        fallback: Chatter | None = None,
        opponent_profiles: Mapping[str, OpponentProfile] | None = None,
    ):
        from ..cognition.llm import LLM, LLMUnavailableError

        if llm is not None:
            self.llm = llm
        else:
            try:
                self.llm = LLM(model=model)
            except LLMUnavailableError:
                self.llm = None
        self.tone = tone
        self.fallback = fallback or ScriptedChatter(tone=tone)
        self.opponent_profiles: Mapping[str, OpponentProfile] | None = opponent_profiles

    def _intel_block(self, ctx: ChatContext) -> str:
        if not self.opponent_profiles:
            return ""
        # Pick names from extras['lobby_members'] when available, else
        # the body player + the rest of the catalog (capped).
        names: list[str] = []
        if ctx.extras and isinstance(ctx.extras.get("lobby_members"), (list, tuple)):
            names = [str(n) for n in ctx.extras["lobby_members"]]  # type: ignore[index]
        elif ctx.body_player_id:
            names = [ctx.body_player_id]
        else:
            names = list(self.opponent_profiles.keys())
        # Always include known suspects; strip self.
        names = [n for n in dict.fromkeys(names) if n != ctx.self_id]
        lines: list[str] = []
        for name in names[:6]:
            profile = self.opponent_profiles.get(name)
            if profile is None or profile.games_observed <= 0:
                continue
            lines.append(f"  - {profile.compact_summary()}")
        if not lines:
            return ""
        return "\nOpponent intel from prior games:\n" + "\n".join(lines)

    def speak(self, ctx: ChatContext) -> str | None:
        if self.llm is None:
            return self.fallback.speak(ctx)
        try:
            resp = self.llm.complete(  # type: ignore[attr-defined]
                system=(
                    f"You are an Among Them player chatting in a meeting. "
                    f"Tone: {self.tone}. Keep it under 20 words. "
                    "Plain text only, no quotes. Use opponent intel to "
                    "shape your message but don't quote it."
                ),
                user=(
                    f"Meeting #{ctx.meeting_index}. "
                    f"Body: {ctx.body_player_id or 'none'}. "
                    f"Suspects: {ctx.suspect_summary or 'unknown'}."
                    f"{self._intel_block(ctx)}"
                ),
            )
            text = resp.text.strip()
            if not text:
                return self.fallback.speak(ctx)
            return text
        except Exception as exc:
            logger.warning("LLMChatter failed (%s); falling back.", exc)
            return self.fallback.speak(ctx)


__all__ = ["ChatContext", "Chatter", "LLMChatter", "ScriptedChatter", "SilentChatter"]
