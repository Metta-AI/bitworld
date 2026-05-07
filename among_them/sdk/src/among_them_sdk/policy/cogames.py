"""Cogames tournament entrypoint — :class:`SDKPolicy`.

What this module is
-------------------

The SDK's tournament-uploadable policy. Cogames calls
``__init__(policy_env_info, device='cpu')`` (no kwargs allowed) and runs
``step_batch(raw_observations, raw_actions)`` per tick. ``SDKPolicy``
composes :class:`evidencebot_v2_policy.EvidenceBotV2NimPolicy` for the
heavy Nim FFI lifting, then layers SDK directives + module overrides on
top of the inner policy's actions.

Architectural shape
-------------------

The Nim FFI surface is **action-indices-out only** (see ``policy/evidencebot_v2.py``
for the long-form note). That means the SDK can't intercept the bot's
inner voting / reporting / chat decisions directly — we can only see
*what action it emitted this tick* and decide whether to override.
Concretely:

* If the inner policy emits a ``report*`` action and the user's
  :class:`Reporter` says "no", we collapse the action to ``noop``.
* If the inner policy emits a ``noop`` while a body is "in our context"
  (we don't know that — Phase 2) and the user's ``Reporter`` says "yes",
  we'd want to *promote* a report action; that path requires Nim FFI
  changes and is documented as a Phase 2 gap below.
* Voter / Chatter overrides land at meeting time, not per-tick. They run
  inside the local-dev :class:`among_them_sdk.LiveGame` runtime today
  but the cogames action stream doesn't surface meeting boundaries, so
  the cogames path treats them as *advisory* — the SDK records what the
  user's Voter would have done into a sidecar log, and the inner Nim
  policy still controls the actual vote button. This is the lossy edge
  the redirect calls out as "Phase 2 Nim FFI extension, not in scope".

Two concrete classes
--------------------

* :class:`SDKPolicy` (subclasses ``mettagrid.policy.policy.MultiAgentPolicy``)
  — the cogames upload entrypoint. Requires mettagrid in the environment.
* :class:`LocalSDKPolicy` — same override engine, sans mettagrid. Used by
  the local :class:`LiveGame` runtime so the 8-player example exercises
  the same override pipeline the tournament will. It does **not**
  inherit ``MultiAgentPolicy`` and isn't uploadable.

Both classes share :class:`_DirectiveOverrideEngine` so behavior is
guaranteed identical across paths.
"""

from __future__ import annotations

import importlib
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np

from ..cogames_config import (
    CONFIG_FILENAME,
    CogamesBundleConfig,
    build_modules,
    find_config_file,
    load_config,
)
from ..cognition.instructions import Directives
from .evidencebot_v2 import BITWORLD_ACTION_NAMES, EvidenceBotV2Policy

if TYPE_CHECKING:
    from ..modules import Chatter, Reporter, Voter
    from ..modules.chatter import ChatContext
    from ..modules.voter import Vote, VotingContext

logger = logging.getLogger("among_them_sdk.policy.cogames")


# ----------------------------- mettagrid import gate -------------------- #
#
# Cogames installs ``mettagrid`` inside the validator Docker image. Local
# dev environments usually don't have it. We import lazily and raise a
# helpful error only when the cogames-flavoured class is actually
# constructed; importing this module never fails.

_METTAGRID_IMPORT_ERROR: ImportError | None = None
try:
    from mettagrid.policy.policy import (  # type: ignore[import-not-found]
        AgentPolicy,
        MultiAgentPolicy,
    )
    from mettagrid.policy.policy_env_interface import (  # type: ignore[import-not-found]
        PolicyEnvInterface,
    )
    from mettagrid.simulator import (  # type: ignore[import-not-found]
        Action,
        AgentObservation,
    )

    _METTAGRID_AVAILABLE = True
except ImportError as exc:
    _METTAGRID_IMPORT_ERROR = exc
    _METTAGRID_AVAILABLE = False

    # Stubs so type-checking + class definition still load locally. These
    # are *only* used when mettagrid isn't installed, which is exactly the
    # case where ``SDKPolicy`` won't actually be instantiated either.
    class _UnavailableShim:
        def __init__(self, *args: Any, **kwargs: Any):
            raise ImportError(
                "mettagrid is required for SDKPolicy at construction time. "
                "Install via cogames Docker validation or `pip install mettagrid`. "
                f"Original error: {_METTAGRID_IMPORT_ERROR}"
            )

    class MultiAgentPolicy(_UnavailableShim):  # type: ignore[no-redef]
        pass

    class AgentPolicy(_UnavailableShim):  # type: ignore[no-redef]
        pass

    class PolicyEnvInterface(_UnavailableShim):  # type: ignore[no-redef]
        pass

    class Action(_UnavailableShim):  # type: ignore[no-redef]
        pass

    class AgentObservation(_UnavailableShim):  # type: ignore[no-redef]
        pass


# --------------------- evidencebot_v2_policy import resolver ------------ #
#
# Cogames adds the *entry-point class's* package directory to sys.path
# (here that's ``among_them/sdk/src/`` so ``among_them_sdk`` resolves).
# The original ``evidencebot_v2_policy.py`` lives at
# ``among_them/players/evidencebot_v2_policy.py`` and is NOT importable
# under that layout. We discover it by walking up from this module to
# find the bundle root, then prepending ``among_them/players/`` to
# sys.path so ``from evidencebot_v2_policy import ...`` resolves.

_EVIDENCEBOT_POLICY_MODULE = "evidencebot_v2_policy"


def _candidate_player_dirs() -> list[Path]:
    """Locations to search for ``evidencebot_v2_policy.py``."""
    here = Path(__file__).resolve()
    cwd = Path.cwd().resolve()
    candidates: list[Path] = []
    for base in [here, *here.parents, cwd, *cwd.parents]:
        candidates.append(base / "among_them" / "players")
        candidates.append(base / "players")
    seen: set[Path] = set()
    unique: list[Path] = []
    for c in candidates:
        if c in seen:
            continue
        seen.add(c)
        unique.append(c)
    return unique


def _import_evidencebot_v2_policy() -> Any:
    try:
        module = importlib.import_module(_EVIDENCEBOT_POLICY_MODULE)
    except ModuleNotFoundError:
        module = None

    if module is None:
        for candidate in _candidate_player_dirs():
            policy_file = candidate / f"{_EVIDENCEBOT_POLICY_MODULE}.py"
            if not policy_file.is_file():
                continue
            candidate_str = str(candidate)
            if candidate_str not in sys.path:
                sys.path.insert(0, candidate_str)
                logger.info(
                    "SDKPolicy: added %s to sys.path to resolve %s",
                    candidate_str,
                    _EVIDENCEBOT_POLICY_MODULE,
                )
            try:
                module = importlib.import_module(_EVIDENCEBOT_POLICY_MODULE)
                break
            except ModuleNotFoundError:
                continue

    if module is None:
        searched = "\n  ".join(str(p) for p in _candidate_player_dirs())
        raise ModuleNotFoundError(
            f"SDKPolicy could not import {_EVIDENCEBOT_POLICY_MODULE}. Searched:\n  {searched}"
        )

    try:
        return module.EvidenceBotV2NimPolicy
    except AttributeError as exc:
        raise ImportError(
            f"{_EVIDENCEBOT_POLICY_MODULE} loaded from {module.__file__} "
            "but does not export EvidenceBotV2NimPolicy."
        ) from exc


# ----------------------------- override engine -------------------------- #
#
# Action-name → "is this a report-flavoured action" detection. Names
# come from ``BITWORLD_ACTION_NAMES``; the FFI returns indices into this
# table. Keep in sync with the SDK's ``policy/evidencebot_v2.py`` table.

_REPORT_ACTIONS = {
    name for name in BITWORLD_ACTION_NAMES if name.startswith("report")
}
_NOOP_ACTION_INDEX = (
    BITWORLD_ACTION_NAMES.index("noop") if "noop" in BITWORLD_ACTION_NAMES else 0
)


@dataclass
class _OverrideStats:
    """How the override engine has rewritten actions in this game.

    Public so the local example + tests can inspect what fired.
    """

    ticks_seen: int = 0
    reports_suppressed: int = 0
    reports_passed: int = 0
    voter_advisories: list[Any] = field(default_factory=list)
    chatter_advisories: list[str] = field(default_factory=list)


class _DirectiveOverrideEngine:
    """Apply SDK directives + module overrides to a stream of FFI actions.

    Used by both :class:`SDKPolicy` and :class:`LocalSDKPolicy` so the
    behavior is identical between the cogames Docker validator and the
    local :class:`LiveGame` runtime.
    """

    def __init__(
        self,
        directives: Directives,
        *,
        voter: Voter | None = None,
        chatter: Chatter | None = None,
        reporter: Reporter | None = None,
    ):
        self.directives = directives
        self.voter = voter
        self.chatter = chatter
        self.reporter = reporter
        self.stats = _OverrideStats()

    def apply_per_tick(self, action_indices: np.ndarray) -> np.ndarray:
        """Mutate-in-place action indices according to directive overrides.

        Only the per-tick (per-action-index) overrides happen here. Vote
        / chat overrides are surfaced on demand via ``advise_vote`` /
        ``advise_chat`` because they don't have an action-index proxy.
        """
        self.stats.ticks_seen += int(action_indices.size)
        if not self.reporter:
            return action_indices

        for i in range(action_indices.shape[0]):
            idx = int(action_indices[i])
            name = (
                BITWORLD_ACTION_NAMES[idx]
                if 0 <= idx < len(BITWORLD_ACTION_NAMES)
                else None
            )
            if name in _REPORT_ACTIONS:
                # Phase-2 gap: we'd love to feed the Reporter real
                # "distance to body" / "ticks since seen" telemetry but
                # the FFI doesn't surface it. Pass the eagerness directive
                # as a degraded signal instead. ``ScriptedReporter``
                # respects ``low|normal|high`` so the directive still has
                # teeth even with no game state.
                from ..modules.reporter import ReportContext

                ctx = ReportContext(
                    tick=self.stats.ticks_seen,
                    self_id="self",
                    body_player_id="<unknown>",
                    distance_to_body=None,
                    seen_body_for_ticks=0,
                    extras={
                        "directive_eagerness": self.directives.report_eagerness,
                    },
                )
                if self.reporter.should_report(ctx):
                    self.stats.reports_passed += 1
                else:
                    action_indices[i] = _NOOP_ACTION_INDEX
                    self.stats.reports_suppressed += 1
        return action_indices

    def advise_vote(self, ctx: VotingContext) -> Vote | None:
        """Run the user's ``Voter`` (if any) and record the advisory."""
        if self.voter is None:
            return None
        vote = self.voter.vote(ctx)
        self.stats.voter_advisories.append(
            {"target": vote.target, "reason": vote.reason}
        )
        return vote

    def advise_chat(self, ctx: ChatContext) -> str | None:
        """Run the user's ``Chatter`` (if any) and record the advisory."""
        if self.chatter is None:
            return None
        msg = self.chatter.speak(ctx)
        if msg:
            self.stats.chatter_advisories.append(msg)
        return msg


# ----------------------------- local mirror ----------------------------- #


class LocalSDKPolicy:
    """Local-dev mirror of :class:`SDKPolicy` that doesn't need mettagrid.

    Same override engine, same config loader, same observable behavior —
    just implemented against :class:`EvidenceBotV2Policy` (the SDK's
    self-contained FFI wrapper) rather than the mettagrid-flavoured
    ``EvidenceBotV2NimPolicy``. The :class:`among_them_sdk.LiveGame`
    runtime uses this so the 8-player example exercises *the same code
    path* the tournament does.

    NOT a ``MultiAgentPolicy`` subclass — cogames will never instantiate
    this. Use :class:`SDKPolicy` for upload.
    """

    def __init__(
        self,
        *,
        config: CogamesBundleConfig | None = None,
        config_path: Path | str | None = None,
        num_agents: int = 1,
        auto_build: bool = True,
    ):
        self.config = (
            config
            if config is not None
            else (load_config(config_path) if config_path else CogamesBundleConfig())
        )
        self.directives = self.config.resolve_directives()
        modules = build_modules(self.config, llm_safe_in_docker=False)
        self._inner = EvidenceBotV2Policy(
            num_agents=num_agents, auto_build=auto_build
        )
        self.engine = _DirectiveOverrideEngine(
            self.directives,
            voter=modules.get("voter"),
            chatter=modules.get("chatter"),
            reporter=modules.get("reporter"),
        )

    @property
    def num_agents(self) -> int:
        return self._inner.num_agents

    @property
    def abi_version(self) -> int:
        return self._inner.abi_version

    @property
    def library_path(self) -> str:
        return self._inner.library_path

    def step_batch(self, observations: np.ndarray) -> np.ndarray:
        """Tournament-shape ``step_batch`` for local use.

        Mirrors :meth:`SDKPolicy.step_batch` but returns the array
        instead of writing to an out-buffer (the cogames signature uses
        an out-buffer; the SDK's local style is to return).
        """
        actions = self._inner.step(observations)
        return self.engine.apply_per_tick(actions)

    def summary(self) -> dict[str, Any]:
        return {
            "policy": "among_them_sdk.LocalSDKPolicy",
            "inner": self._inner.summary(),
            "directives": self.directives.model_dump(),
            "config": self.config.model_dump(),
            "stats": {
                "ticks_seen": self.engine.stats.ticks_seen,
                "reports_suppressed": self.engine.stats.reports_suppressed,
                "reports_passed": self.engine.stats.reports_passed,
                "voter_advisories": list(self.engine.stats.voter_advisories),
                "chatter_advisories": list(self.engine.stats.chatter_advisories),
            },
        }


# ----------------------------- tournament class ------------------------- #


class _SDKAgentPolicy(AgentPolicy):
    """One-agent shim, mirrors ``_EvidenceBotV2NimAgentPolicy``."""

    def __init__(
        self,
        policy_env_info: PolicyEnvInterface,
        parent: SDKPolicy,
        agent_id: int,
    ):
        super().__init__(policy_env_info)
        self._parent = parent
        self._agent_id = agent_id

    def step(self, obs: AgentObservation) -> Action:
        del obs
        action_index = self._parent.step_agent(self._agent_id)
        return Action(name=self._policy_env_info.action_names[action_index])


class SDKPolicy(MultiAgentPolicy):  # type: ignore[misc, valid-type]
    """Cogames tournament entrypoint — wraps ``EvidenceBotV2NimPolicy``.

    This is what the tournament runner instantiates per game. The class
    composes the existing :class:`evidencebot_v2_policy.EvidenceBotV2NimPolicy`
    (no surgery on that file) and layers SDK directives + module overrides
    on top of its actions.

    Configuration is read from a JSON file (``among_them_sdk_config.json``)
    that ships in the upload bundle alongside this module. See
    :mod:`among_them_sdk.cogames_config` for the schema and
    :mod:`among_them_sdk.package` for the helper that builds it.
    """

    short_names = ["among_them_sdk"]

    def __init__(self, policy_env_info: PolicyEnvInterface, device: str = "cpu"):
        if not _METTAGRID_AVAILABLE:
            raise ImportError(
                "SDKPolicy requires mettagrid (provided by cogames at validation/run time). "
                f"Original error: {_METTAGRID_IMPORT_ERROR}"
            )
        super().__init__(policy_env_info, device=device)

        # Load + validate the bundled config. We resolve it to typed
        # Directives + a dict of module instances *before* we touch the
        # inner Nim policy so a malformed config fails fast and clearly.
        cfg_dir = Path(__file__).resolve().parent
        cfg_path = find_config_file(cfg_dir)
        if cfg_path is None:
            # Also look at the bundle root — cogames flattens uploaded
            # files; in some bundle shapes the config sits at the top
            # level.
            top = Path.cwd()
            cfg_path = top / CONFIG_FILENAME
            if not cfg_path.is_file():
                cfg_path = None
        config = load_config(cfg_path) if cfg_path else CogamesBundleConfig()
        if cfg_path is not None:
            logger.info("SDKPolicy loaded config from %s", cfg_path)
        else:
            logger.info(
                "SDKPolicy: no %s found near %s; using defaults",
                CONFIG_FILENAME,
                cfg_dir,
            )
        self._config = config
        self._directives = config.resolve_directives()

        modules = build_modules(config, llm_safe_in_docker=False)
        self._engine = _DirectiveOverrideEngine(
            self._directives,
            voter=modules.get("voter"),
            chatter=modules.get("chatter"),
            reporter=modules.get("reporter"),
        )

        # Compose (don't subclass) EvidenceBotV2NimPolicy. We import
        # locally so this module loads even when the existing
        # evidencebot_v2_policy.py isn't on sys.path (e.g. during the
        # mettagrid-less local-dev test).
        #
        # Cogames adds the directory of the entry-point class to sys.path,
        # so when our class is ``among_them_sdk.policy.cogames.SDKPolicy``
        # cogames puts ``among_them/sdk/src/`` on the path — but NOT
        # ``among_them/players/`` where ``evidencebot_v2_policy.py`` lives.
        # We discover the bundle root by walking up from this file and add
        # the players dir to sys.path before importing.
        EvidenceBotV2NimPolicy = _import_evidencebot_v2_policy()

        self._inner = EvidenceBotV2NimPolicy(policy_env_info, device=device)
        self._num_agents = self._inner._num_agents  # mirror the inner state

    # --------- MultiAgentPolicy contract --------- #

    def agent_policy(self, agent_id: int) -> AgentPolicy:
        return _SDKAgentPolicy(self._policy_env_info, self, agent_id)

    def step_batch(
        self,
        raw_observations: np.ndarray,
        raw_actions: np.ndarray,
    ) -> None:
        """Run inner Nim policy, then apply SDK overrides in place.

        We let the inner policy write into an internal scratch array so
        we can rewrite specific entries before publishing them to
        ``raw_actions``. This keeps the contract with mettagrid identical
        to ``EvidenceBotV2NimPolicy.step_batch``.
        """
        scratch = np.zeros_like(raw_actions)
        self._inner.step_batch(raw_observations, scratch)
        # apply_per_tick mutates the array in place.
        scratch_int32 = scratch.astype(np.int32, copy=False)
        self._engine.apply_per_tick(scratch_int32)
        raw_actions[:] = scratch_int32.astype(raw_actions.dtype, copy=False)

    def step_agent(self, agent_id: int) -> int:
        # Delegate to inner; the per-tick overrides only matter at
        # ``step_batch`` time. ``step_agent`` is the cached fallback that
        # mettagrid uses when an env replays the last action.
        return self._inner.step_agent(agent_id)

    # --------- introspection helpers (used by tests + packaging) --------- #

    @property
    def directives(self) -> Directives:
        return self._directives

    @property
    def config(self) -> CogamesBundleConfig:
        return self._config

    @property
    def engine_stats(self) -> _OverrideStats:
        return self._engine.stats


# ----------------------------- alias ----------------------------------- #
#
# Existing convention from ``evidencebot_v2_policy.py:203``: `AmongThemPolicy
# = EvidenceBotV2NimPolicy`. We mirror it so cogames can be configured with
# either explicit class path.

AmongThemPolicy = SDKPolicy


__all__ = [
    "AmongThemPolicy",
    "LocalSDKPolicy",
    "SDKPolicy",
]
