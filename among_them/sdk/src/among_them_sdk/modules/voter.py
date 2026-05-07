"""Voter module — meeting-time vote selection."""

from __future__ import annotations

import logging
import random
from abc import ABC, abstractmethod
from dataclasses import dataclass

from .memory import VotingContext

logger = logging.getLogger("among_them_sdk.modules.voter")


@dataclass
class Vote:
    target: str | None  # ``None`` == skip
    reason: str = ""

    @classmethod
    def skip(cls, reason: str = "") -> Vote:
        return cls(target=None, reason=reason or "skip")


class Voter(ABC):
    @abstractmethod
    def vote(self, ctx: VotingContext) -> Vote: ...


class ScriptedVoter(Voter):
    """Default heuristic that mirrors evidencebot_v2's evidence-first voting.

    Decision rules (in priority order):

      1. If any suspect has score >= ``threshold`` → vote for the highest.
      2. If ``follow_majority`` is set and there's a clear group consensus
         (encoded in ``ctx.extras['majority_target']``) → vote with them.
      3. Otherwise skip.

    All knobs come from :class:`among_them_sdk.cognition.Directives`. This is
    the **scripted default** that the FFI bot would also do; we reimplement
    it here so module overrides composing with directives still get sane
    behavior at the meeting layer.
    """

    def __init__(
        self,
        threshold: float = 0.6,
        follow_majority: bool = False,
        rng: random.Random | None = None,
    ):
        self.threshold = threshold
        self.follow_majority = follow_majority
        self.rng = rng or random.Random()

    def vote(self, ctx: VotingContext) -> Vote:
        if not ctx.suspects:
            return Vote.skip("no suspects in memory")

        ranked = ctx.by_score()
        top = ranked[0]
        if top.score >= self.threshold:
            return Vote(
                target=top.player_id,
                reason=f"suspicion {top.score:.2f} >= {self.threshold:.2f}",
            )

        if self.follow_majority:
            majority = ctx.extras.get("majority_target")
            if majority and majority != ctx.self_id:
                return Vote(target=str(majority), reason="follow majority")

        return Vote.skip(f"top suspicion {top.score:.2f} below threshold")


class LLMVoter(Voter):
    """Vote via an LLM tool loop — falls back to scripted behavior on failure."""

    def __init__(
        self,
        llm: object | None = None,
        *,
        model: str = "gpt-5.5",
        fallback: Voter | None = None,
    ):
        from ..cognition.llm import LLM, LLMUnavailableError

        if llm is not None:
            self.llm = llm
        else:
            try:
                self.llm = LLM(model=model)
            except LLMUnavailableError:
                self.llm = None
        self.fallback = fallback or ScriptedVoter()
        self.model = model

    def vote(self, ctx: VotingContext) -> Vote:
        if self.llm is None:
            return self.fallback.vote(ctx)
        try:
            resp = self.llm.complete(  # type: ignore[attr-defined]
                system=(
                    "You are a careful Among Them voter. Given a list of suspects, "
                    "respond with a JSON object: "
                    '{"target": "<player_id>" or null, "reason": "<short reason>"}.'
                ),
                user=ctx.to_prompt(),
                response_format="json",
            )
        except Exception as exc:
            logger.warning("LLMVoter: completion failed (%s); falling back.", exc)
            return self.fallback.vote(ctx)
        import json

        try:
            data = json.loads(resp.text)
        except Exception:
            return self.fallback.vote(ctx)
        target = data.get("target")
        reason = data.get("reason", "llm")
        return Vote(target=target if target else None, reason=str(reason))


__all__ = ["LLMVoter", "ScriptedVoter", "Vote", "Voter"]
