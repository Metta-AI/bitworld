"""Filesystem persistence for opponent observations and profiles.

Layout:

::

    <root>/<opponent_name>/
        observations.ndjson  # one ObservationEvent per line, append-only
        profile.json         # latest OpponentProfile

Default ``<root>`` is ``~/.among-them/opponents/`` so a user accumulates
intel across all SDK projects on the machine. Override:

  * ``OpponentStore(root=...)`` — explicit constructor arg
  * ``AMONG_THEM_OPPONENTS_DIR`` env var (used when no root passed)

The on-disk format is intentionally text-friendly so users can grep,
diff, and check it into a private repo if they want a per-project
opponent dossier instead of a machine-wide one.

Name-to-path translation only sanitizes for filesystem safety. The
in-memory key is the raw player name.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any

from .models import ObservationEvent, OpponentProfile

logger = logging.getLogger("among_them_sdk.opponents.store")

DEFAULT_ROOT_ENV = "AMONG_THEM_OPPONENTS_DIR"
DEFAULT_ROOT = Path.home() / ".among-them" / "opponents"

OBSERVATIONS_FILENAME = "observations.ndjson"
PROFILE_FILENAME = "profile.json"

# Filesystem-safe slug: keep alphanum, dash, underscore. Anything else →
# underscore. This means two opponents whose names collapse to the same
# slug will *share* a folder; we accept that risk because the local
# server uses simple ASCII names like ``nottoodumb1``.
_SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]")


def _safe_dirname(name: str) -> str:
    """Translate an opponent name to a safe directory name."""
    cleaned = _SAFE_NAME_RE.sub("_", name).strip("._")
    return cleaned or "_unnamed"


class ObservationLog:
    """In-memory + on-disk log of one opponent's observations.

    Append-only on disk (NDJSON). The in-memory list mirrors the file so
    callers can iterate without re-reading. Constructed lazily by
    :class:`OpponentStore`; users typically don't instantiate this
    directly.
    """

    def __init__(self, name: str, path: Path):
        self.name = name
        self.path = path
        self._events: list[ObservationEvent] = []
        self._loaded = False

    def _load(self) -> None:
        if self._loaded:
            return
        self._events = list(self._iter_disk())
        self._loaded = True

    def _iter_disk(self) -> Iterator[ObservationEvent]:
        if not self.path.is_file():
            return
        try:
            with self.path.open("r", encoding="utf-8") as fh:
                for lineno, raw in enumerate(fh, start=1):
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        data = json.loads(raw)
                        yield ObservationEvent.model_validate(data)
                    except (json.JSONDecodeError, ValueError) as exc:
                        logger.warning(
                            "skipping malformed obs at %s:%d: %s",
                            self.path,
                            lineno,
                            exc,
                        )
        except OSError as exc:
            logger.warning("could not read %s: %s", self.path, exc)

    def append(self, event: ObservationEvent) -> None:
        """Append one event to disk + in-memory list."""
        self._load()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(event.model_dump_json() + "\n")
        except OSError as exc:
            logger.warning("could not append to %s: %s", self.path, exc)
            return
        self._events.append(event)

    def all(self) -> list[ObservationEvent]:
        """Return all events, oldest first. Loads from disk on first call."""
        self._load()
        return list(self._events)

    def iter_recent(self, n_games: int | None = None) -> list[ObservationEvent]:
        """Return events from the most recent ``n_games`` distinct ``game_id``s.

        ``None`` returns all events. Game order is the order in which
        new ``game_id`` values appear on disk; chronological by append
        time, not by the game's wall clock.
        """
        self._load()
        if n_games is None or n_games <= 0:
            return list(self._events)
        seen: list[str] = []
        for ev in self._events:
            if ev.game_id and ev.game_id not in seen:
                seen.append(ev.game_id)
        recent_ids = set(seen[-n_games:])
        if not recent_ids:
            return list(self._events)
        return [ev for ev in self._events if ev.game_id in recent_ids]

    def summary(self) -> dict[str, Any]:
        """Lightweight stats — games observed, event-type histogram, etc."""
        self._load()
        games: set[str] = set()
        type_counts: dict[str, int] = {}
        for ev in self._events:
            if ev.game_id:
                games.add(ev.game_id)
            type_counts[ev.type] = type_counts.get(ev.type, 0) + 1
        return {
            "name": self.name,
            "events": len(self._events),
            "games": len(games),
            "type_counts": type_counts,
            "path": str(self.path),
        }

    def prune_keeping_last_games(self, n_games: int) -> int:
        """Keep only the events from the most recent ``n_games`` games.

        Rewrites the NDJSON file. Returns the number of events removed.
        """
        self._load()
        if n_games <= 0:
            return 0
        keep = self.iter_recent(n_games=n_games)
        removed = len(self._events) - len(keep)
        if removed <= 0:
            return 0
        self._events = list(keep)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(self.path.suffix + ".tmp")
            with tmp.open("w", encoding="utf-8") as fh:
                for ev in self._events:
                    fh.write(ev.model_dump_json() + "\n")
            tmp.replace(self.path)
        except OSError as exc:
            logger.warning("could not rewrite %s: %s", self.path, exc)
            return 0
        return removed


class OpponentStore:
    """Filesystem-backed store of per-opponent observations + profiles.

    Two paths per opponent: ``observations.ndjson`` (append-only event
    log) and ``profile.json`` (latest analyzed profile).
    """

    def __init__(self, root: Path | str | None = None):
        if root is None:
            env_root = os.environ.get(DEFAULT_ROOT_ENV)
            root = Path(env_root) if env_root else DEFAULT_ROOT
        self.root: Path = Path(root)
        self._logs: dict[str, ObservationLog] = {}

    @property
    def observations_root(self) -> Path:
        return self.root

    def _opponent_dir(self, name: str) -> Path:
        return self.root / _safe_dirname(name)

    def log_for(self, name: str) -> ObservationLog:
        """Return the (lazy) :class:`ObservationLog` for ``name``."""
        if name not in self._logs:
            log_path = self._opponent_dir(name) / OBSERVATIONS_FILENAME
            self._logs[name] = ObservationLog(name, log_path)
        return self._logs[name]

    def record(self, name: str, event: ObservationEvent) -> None:
        """Append an :class:`ObservationEvent` to the named opponent's log."""
        self.log_for(name).append(event)

    def record_many(self, name: str, events: Iterable[ObservationEvent]) -> int:
        """Bulk variant of :meth:`record`. Returns count appended."""
        log = self.log_for(name)
        count = 0
        for ev in events:
            log.append(ev)
            count += 1
        return count

    def load_observations(
        self, name: str, *, recent_games: int | None = None
    ) -> list[ObservationEvent]:
        """Load observations for ``name``. Optionally restrict to recent games."""
        return self.log_for(name).iter_recent(n_games=recent_games)

    def load_profile(self, name: str) -> OpponentProfile | None:
        """Load the latest profile for ``name`` or ``None`` if not present."""
        path = self._opponent_dir(name) / PROFILE_FILENAME
        if not path.is_file():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            logger.warning("could not read profile %s: %s", path, exc)
            return None
        try:
            return OpponentProfile.model_validate(data)
        except Exception as exc:  # pragma: no cover - schema drift
            logger.warning("profile at %s failed validation: %s", path, exc)
            return None

    def save_profile(self, name: str, profile: OpponentProfile) -> Path:
        """Persist ``profile`` to disk, overwriting any prior profile."""
        path = self._opponent_dir(name) / PROFILE_FILENAME
        path.parent.mkdir(parents=True, exist_ok=True)
        profile = profile.model_copy(update={"last_updated_at": time.time()})
        path.write_text(profile.model_dump_json(indent=2) + "\n", encoding="utf-8")
        return path

    def list_opponents(self) -> list[str]:
        """List opponent names with at least one observation or profile on disk."""
        if not self.root.is_dir():
            return []
        names: set[str] = set()
        # Persisted opponents are folders; emit the *original* names by
        # reading any profile (which carries the unsanitized name).
        for child in self.root.iterdir():
            if not child.is_dir():
                continue
            profile_path = child / PROFILE_FILENAME
            if profile_path.is_file():
                try:
                    data = json.loads(profile_path.read_text(encoding="utf-8"))
                    nm = data.get("name")
                    if isinstance(nm, str) and nm:
                        names.add(nm)
                        continue
                except (OSError, json.JSONDecodeError):
                    pass
            obs_path = child / OBSERVATIONS_FILENAME
            if obs_path.is_file():
                try:
                    with obs_path.open("r", encoding="utf-8") as fh:
                        first = fh.readline().strip()
                    if first:
                        # Prefer name from observation payload if present
                        data = json.loads(first)
                        # We didn't store the name in ObservationEvent,
                        # so fall back to the slug.
                        names.add(child.name)
                        continue
                except (OSError, json.JSONDecodeError):
                    pass
            names.add(child.name)
        return sorted(names)

    def list_profiles(self) -> dict[str, OpponentProfile]:
        """Load every profile currently on disk."""
        out: dict[str, OpponentProfile] = {}
        for name in self.list_opponents():
            profile = self.load_profile(name)
            if profile is not None:
                out[name] = profile
        return out

    def prune_old(self, *, max_games_per_opponent: int) -> dict[str, int]:
        """Trim each opponent's log to the most recent ``max_games_per_opponent``.

        Returns a ``{name: events_removed}`` map for accountability.
        """
        removed: dict[str, int] = {}
        for name in self.list_opponents():
            log = self.log_for(name)
            r = log.prune_keeping_last_games(max_games_per_opponent)
            if r > 0:
                removed[name] = r
        return removed


__all__ = [
    "DEFAULT_ROOT",
    "DEFAULT_ROOT_ENV",
    "OBSERVATIONS_FILENAME",
    "PROFILE_FILENAME",
    "ObservationLog",
    "OpponentStore",
]
