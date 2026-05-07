"""Chatter module — meeting-time text emission."""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

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
    """Generate one-line meeting messages with an LLM."""

    def __init__(
        self,
        llm: object | None = None,
        *,
        model: str = "gpt-5.5",
        tone: str = "neutral",
        fallback: Chatter | None = None,
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

    def speak(self, ctx: ChatContext) -> str | None:
        if self.llm is None:
            return self.fallback.speak(ctx)
        try:
            resp = self.llm.complete(  # type: ignore[attr-defined]
                system=(
                    f"You are an Among Them player chatting in a meeting. "
                    f"Tone: {self.tone}. Keep it under 20 words. "
                    "Plain text only, no quotes."
                ),
                user=(
                    f"Meeting #{ctx.meeting_index}. Body: {ctx.body_player_id or 'none'}. "
                    f"Suspects: {ctx.suspect_summary or 'unknown'}."
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
