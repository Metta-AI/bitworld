"""``Agent`` — the public entry point.

Mirrors the Cursor SDK ``Agent.create(...)`` style. Composition order:

  1. Resolve config (TOML + env + kwargs).
  2. Resolve directives by parsing ``instructions=`` (LLM if available;
     keyword fallback otherwise).
  3. Instantiate cognitive modules (with directive-derived defaults).
  4. Load the FFI policy (``evidencebot_v2``) and bind override hooks.

The result is a stateful agent ready to ``run`` against a runtime.
"""

from __future__ import annotations

import logging
import random
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

import numpy as np
from pydantic import BaseModel, Field

if TYPE_CHECKING:
    from .opponents.models import OpponentProfile

from . import _cyborg
from .cognition import Directives, parse_instructions
from .config import SDKConfig
from .config import resolve as resolve_config
from .hooks import AgentHooks
from .modules import (
    Chatter,
    Memory,
    Navigator,
    Perception,
    Reporter,
    ScriptedChatter,
    ScriptedMemory,
    ScriptedNavigator,
    ScriptedPerception,
    ScriptedReporter,
    ScriptedVoter,
    SuspicionEntry,
    Vote,
    Voter,
    VotingContext,
)
from .modules.chatter import ChatContext
from .modules.navigator import NavigationContext
from .modules.reporter import ReportContext
from .policy import EvidenceBotV2Policy, OverrideHooks
from .policy.evidencebot_v2 import BITWORLD_ACTION_NAMES
from .runtime import LocalSim, MeetingEvent, RunResult, TickEvent
from .tracing import Tracer

logger = logging.getLogger("among_them_sdk.agent")


class AgentConfig(BaseModel):
    """Pydantic schema mostly for serialization / debugging."""

    role_hint: str = "auto"
    profile: str = "evidencebot_v2"
    instructions: str | None = None
    cognitive: dict[str, Any] = Field(default_factory=dict)
    seed: int = 42

    model_config = {"arbitrary_types_allowed": True}


@dataclass
class Agent:
    """The composable agent.

    Construct via :meth:`Agent.create`. Holds:

      * ``policy`` — the FFI-backed driver
      * ``directives`` — derived from ``instructions`` at create time
      * ``perception`` / ``memory`` / ``voter`` / ``navigator`` / ``chatter`` / ``reporter``
      * ``hooks`` — user-registered lifecycle callbacks
      * ``tracer`` — structlog (Langfuse stub for Phase 4)
    """

    config: AgentConfig
    directives: Directives
    policy: EvidenceBotV2Policy
    perception: Perception
    memory: Memory
    voter: Voter
    navigator: Navigator
    chatter: Chatter
    reporter: Reporter
    hooks: AgentHooks
    tracer: Tracer
    sdk_config: SDKConfig
    opponent_profiles: Mapping[str, OpponentProfile] | None = None
    _rng: random.Random = field(default_factory=random.Random)

    @classmethod
    def create(
        cls,
        *,
        instructions: str | None = None,
        cognitive: dict[str, Any] | None = None,
        role_hint: str = "auto",
        profile: str = "evidencebot_v2",
        seed: int = 42,
        perception: Perception | None = None,
        memory: Memory | None = None,
        voter: Voter | None = None,
        navigator: Navigator | None = None,
        chatter: Chatter | None = None,
        reporter: Reporter | None = None,
        hooks: AgentHooks | None = None,
        tracer: Tracer | None = None,
        num_agents: int = 1,
        auto_build: bool = True,
        use_llm_for_instructions: bool = True,
        instructions_model: str = "gpt-5.5",
        opponent_profiles: Mapping[str, OpponentProfile] | None = None,
        load_opponent_profiles: bool = True,
    ) -> Agent:
        sdk_config = resolve_config(profile=profile)
        cognitive = cognitive or {}

        if opponent_profiles is None and load_opponent_profiles:
            try:
                from .opponents import OpponentStore

                store = OpponentStore()
                if store.root.is_dir():
                    opponent_profiles = store.list_profiles() or None
            except Exception as exc:  # pragma: no cover - import-time guard
                logger.debug("could not auto-load opponent profiles: %s", exc)
                opponent_profiles = None

        directives = parse_instructions(
            instructions,
            use_llm=use_llm_for_instructions,
            model=instructions_model,
        )
        directives = directives.merged_with(
            suspicion_threshold=cognitive.get("suspicion_threshold"),
            report_eagerness=cognitive.get("report_eagerness"),
            kill_eagerness=cognitive.get("kill_eagerness"),
            chat_tone=cognitive.get("chat_tone"),
            voting_style=cognitive.get("voting_style"),
            trust_horizon_meetings=cognitive.get("trust_horizon_meetings"),
            avoid_central_room=cognitive.get("avoid_central_room"),
            follow_majority=cognitive.get("follow_majority"),
        )

        policy = EvidenceBotV2Policy(num_agents=num_agents, auto_build=auto_build)

        scripted_voter = ScriptedVoter(
            threshold=directives.suspicion_threshold,
            follow_majority=directives.follow_majority,
        )
        scripted_chatter = ScriptedChatter(tone=directives.chat_tone)
        scripted_reporter = ScriptedReporter(eagerness=directives.report_eagerness)

        # Inject opponent profiles into LLMVoter/LLMChatter when the user
        # supplied one without setting it explicitly. This keeps the
        # consumer wiring transparent — users who construct LLMVoter()
        # via Agent.create automatically get opponent intel without
        # having to pass it twice.
        if opponent_profiles:
            from .modules.chatter import LLMChatter
            from .modules.voter import LLMVoter

            if isinstance(voter, LLMVoter) and voter.opponent_profiles is None:
                voter.opponent_profiles = opponent_profiles
            if isinstance(chatter, LLMChatter) and chatter.opponent_profiles is None:
                chatter.opponent_profiles = opponent_profiles

        agent = cls(
            config=AgentConfig(
                role_hint=role_hint,
                profile=profile,
                instructions=instructions,
                cognitive=cognitive,
                seed=seed,
            ),
            directives=directives,
            policy=policy,
            perception=perception or ScriptedPerception(),
            memory=memory or ScriptedMemory(),
            voter=voter or scripted_voter,
            navigator=navigator or ScriptedNavigator(),
            chatter=chatter or scripted_chatter,
            reporter=reporter or scripted_reporter,
            hooks=hooks or AgentHooks(),
            tracer=tracer or Tracer(),
            sdk_config=sdk_config,
            opponent_profiles=opponent_profiles,
            _rng=random.Random(seed),
        )

        agent.tracer.event(
            "agent.created",
            profile=profile,
            num_agents=num_agents,
            cyborg_available=_cyborg.is_available(),
            directives=directives.model_dump(),
        )
        return agent

    def step(self, observations: np.ndarray) -> np.ndarray:
        ohooks = self._build_override_hooks()
        return self.policy.step_with_hooks(observations, ohooks)

    def vote(self, ctx: VotingContext) -> Vote:
        self.hooks.call("on_meeting", {"meeting_index": ctx.meeting_index})
        result = self.voter.vote(ctx)
        self.tracer.event(
            "agent.vote",
            meeting=ctx.meeting_index,
            target=result.target,
            reason=result.reason,
        )
        self.hooks.call(
            "on_vote",
            {
                "meeting": ctx.meeting_index,
                "target": result.target,
                "reason": result.reason,
            },
        )
        return result

    def consider_report(self, ctx: ReportContext) -> bool:
        result = self.reporter.should_report(ctx)
        self.tracer.event(
            "agent.report_decision",
            tick=ctx.tick,
            body=ctx.body_player_id,
            distance=ctx.distance_to_body,
            decided=result,
        )
        return result

    def speak(self, ctx: ChatContext) -> str | None:
        text = self.chatter.speak(ctx)
        self.tracer.event(
            "agent.chat",
            meeting=ctx.meeting_index,
            text=text,
        )
        if text:
            self.hooks.call("on_message", {"meeting": ctx.meeting_index, "text": text})
        return text

    def run(
        self,
        rounds: int = 1,
        *,
        runtime: LocalSim | None = None,
    ) -> RunResult:
        sim = runtime or LocalSim()
        rng = random.Random(self.config.seed)

        actions: list[int] = []
        meetings: list[MeetingEvent] = []
        votes: list[Vote] = []
        reports: list[bool] = []
        chat_messages: list[str] = []

        seed_players = [f"P{i:02d}" for i in range(sim.n_players)]

        total_ticks = sim.ticks_per_round * max(1, rounds)
        for tick in range(total_ticks):
            obs = sim._make_frame(rng)
            self.hooks.call("pre_tick", {"tick": tick})
            action_arr = self.step(obs)
            action = int(action_arr[0]) if action_arr.size else 0
            actions.append(action)
            self.hooks.call("post_tick", {"tick": tick}, action)
            self.memory.update(tick=tick)

            if sim.report_every and tick > 0 and tick % sim.report_every == 0:
                body_player = rng.choice(seed_players)
                rctx = ReportContext(
                    tick=tick,
                    self_id="self",
                    body_player_id=body_player,
                    distance_to_body=rng.uniform(0, 20),
                    seen_body_for_ticks=rng.randint(1, 10),
                )
                reports.append(self.consider_report(rctx))

            if sim.meeting_every and tick > 0 and tick % sim.meeting_every == 0:
                if isinstance(self.memory, ScriptedMemory):
                    for pid in seed_players[:3]:
                        self.memory.bump(pid, rng.uniform(0.05, 0.3),
                                         reason=f"observed at tick {tick}")
                    meeting_idx = self.memory.note_meeting()
                else:
                    meeting_idx = len(meetings) + 1
                vctx = self._make_voting_context(seed_players, meeting_idx, rng)
                meeting_event = MeetingEvent(
                    meeting_index=meeting_idx,
                    body_player_id=vctx.body_player_id,
                )
                meetings.append(meeting_event)
                self.hooks.call("on_meeting", {"meeting_index": meeting_idx})
                vote = self.vote(vctx)
                votes.append(vote)
                cctx = ChatContext(
                    self_id="self",
                    meeting_index=meeting_idx,
                    suspect_summary=", ".join(s.player_id for s in vctx.suspects[:3]),
                    body_player_id=vctx.body_player_id,
                    extras={"top_suspect": (vctx.by_score()[0].player_id if vctx.suspects else "?")},
                )
                msg = self.speak(cctx)
                if msg:
                    chat_messages.append(msg)

        action_names = [BITWORLD_ACTION_NAMES[a] if 0 <= a < len(BITWORLD_ACTION_NAMES) else "?" for a in actions]
        unique = sorted(set(action_names))
        summary = (
            f"{total_ticks} ticks against evidencebot_v2 (ABI {self.policy.abi_version}); "
            f"{len(meetings)} meetings, {len(votes)} votes, {len(chat_messages)} chats; "
            f"actions seen: {unique[:8]}"
        )
        self.tracer.event(
            "agent.run.complete",
            ticks=total_ticks,
            meetings=len(meetings),
            votes=len(votes),
            chats=len(chat_messages),
        )
        return RunResult(
            ticks=total_ticks,
            actions=actions,
            meetings=len(meetings),
            votes=votes,
            reports=reports,
            chat_messages=chat_messages,
            summary=summary,
            raw={
                "policy_summary": self.policy.summary(),
                "directives": self.directives.model_dump(),
                "cyborg": _cyborg.status(),
            },
        )

    def stream(self, rounds: int = 1, *, runtime: LocalSim | None = None) -> Iterable[TickEvent]:
        sim = runtime or LocalSim()
        rng = random.Random(self.config.seed)
        for tick in range(sim.ticks_per_round * max(1, rounds)):
            obs = sim._make_frame(rng)
            action_arr = self.step(obs)
            action = int(action_arr[0]) if action_arr.size else 0
            yield TickEvent(tick=tick, agent_id=0, action_index=action)

    def send(self, observation: np.ndarray) -> int:
        out = self.step(observation)
        return int(out[0]) if out.size else 0

    def _build_override_hooks(self) -> OverrideHooks:
        nav_hook = None
        if isinstance(self.navigator, Navigator) and not isinstance(self.navigator, ScriptedNavigator):
            nav = self.navigator

            def _nav(ctx_dict: dict[str, Any]) -> int | None:
                return nav.step(NavigationContext(
                    tick=ctx_dict.get("tick", 0),
                    agent_id=ctx_dict.get("agent_id", 0),
                    ffi_action=ctx_dict.get("ffi_action", 0),
                    extras=ctx_dict,
                ))
            nav_hook = _nav
        elif isinstance(self.navigator, ScriptedNavigator) and self.navigator.goal_injector is not None:
            nav = self.navigator

            def _nav(ctx_dict: dict[str, Any]) -> int | None:
                return nav.step(NavigationContext(
                    tick=ctx_dict.get("tick", 0),
                    agent_id=ctx_dict.get("agent_id", 0),
                    ffi_action=ctx_dict.get("ffi_action", 0),
                    extras=ctx_dict,
                ))
            nav_hook = _nav
        return OverrideHooks(on_navigate=nav_hook)

    def _make_voting_context(
        self,
        seed_players: list[str],
        meeting_idx: int,
        rng: random.Random,
    ) -> VotingContext:
        if isinstance(self.memory, ScriptedMemory) and self.memory.suspects:
            suspects = list(self.memory.suspects.values())
        else:
            suspects = [
                SuspicionEntry(
                    player_id=pid,
                    score=rng.random(),
                    reasons=["synthetic"],
                    last_seen_tick=meeting_idx * 30,
                )
                for pid in seed_players
            ]
        body_player = rng.choice(seed_players) if rng.random() < 0.7 else None
        return VotingContext(
            meeting_index=meeting_idx,
            self_id="self",
            suspects=suspects,
            body_player_id=body_player,
            extras={"top_suspect": max(suspects, key=lambda s: s.score).player_id},
        )


__all__ = ["Agent", "AgentConfig"]
