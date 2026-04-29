"""Three-tier memory system for Among Them smart bot.

Tier 1: WorkingMemory  — volatile per-frame snapshot
Tier 2: EpisodicMemory — ring buffer of categorized game events
Tier 3: StrategicMemory — key-value facts with temporal supersession
"""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PLAYER_COLOR_NAMES = [
  'red', 'orange', 'yellow', 'light blue', 'pink', 'lime',
  'blue', 'pale blue', 'gray', 'white', 'dark brown', 'brown',
  'dark teal', 'green', 'dark navy', 'black',
]

MAX_EPISODIC_EVENTS = 200


class GamePhase(Enum):
  PREGAME = 'pregame'
  PLAYING = 'playing'
  VOTING = 'voting'
  RESULTS = 'results'
  GAMEOVER = 'gameover'


class EventHall(Enum):
  SIGHTINGS = 'sightings'
  KILLS = 'kills'
  MEETINGS = 'meetings'
  MOVEMENT = 'movement'
  SOCIAL = 'social'
  SUSPICION = 'suspicion'


# ---------------------------------------------------------------------------
# Tier 1 — Working Memory
# ---------------------------------------------------------------------------

@dataclass
class VisiblePlayer:
  color: int
  x: int
  y: int
  room: str


@dataclass
class WorkingMemory:
  tick: int = 0
  phase: GamePhase = GamePhase.PREGAME
  self_color: int = -1
  room: str = 'unknown'
  is_ghost: bool = False
  is_imposter: bool = False
  kill_ready: bool = False
  voting: bool = False
  player_x: int = 0
  player_y: int = 0
  camera_x: int = 0
  camera_y: int = 0
  camera_locked: bool = False
  alive_count: int = 0
  visible_players: list[VisiblePlayer] = field(default_factory=list)
  visible_bodies: list[dict] = field(default_factory=list)
  visible_ghosts: list[dict] = field(default_factory=list)
  task_mandatory: int = 0
  task_completed: int = 0
  task_checkout: int = 0
  task_total: int = 0
  task_progress: float = 0.0
  vote_cursor: int = -1
  vote_chat_text: str = ''
  vote_slots: list[dict] = field(default_factory=list)
  home_x: int = 0
  home_y: int = 0
  intent: str = ''
  stuck_frames: int = 0

  @property
  def visible_player_colors(self) -> set[int]:
    return {p.color for p in self.visible_players}

  def update_from_snapshot(self, snap: dict) -> None:
    self.tick = snap.get('tick', self.tick)
    phase_str = snap.get('phase', 'playing')
    try:
      self.phase = GamePhase(phase_str)
    except ValueError:
      self.phase = GamePhase.PLAYING
    self.room = snap.get('room', 'unknown')
    self.is_ghost = snap.get('is_ghost', False)
    self.is_imposter = snap.get('role', 'crewmate') == 'imposter'
    self.kill_ready = snap.get('kill_ready', False)
    self.voting = snap.get('voting', False)
    self.player_x = snap.get('player_x', 0)
    self.player_y = snap.get('player_y', 0)
    self.camera_x = snap.get('camera_x', 0)
    self.camera_y = snap.get('camera_y', 0)
    self.camera_locked = snap.get('camera_locked', False)
    self.home_x = snap.get('home_x', 0)
    self.home_y = snap.get('home_y', 0)
    self.intent = snap.get('intent', '')
    self.stuck_frames = snap.get('stuck_frames', 0)
    self.vote_cursor = snap.get('vote_cursor', -1)
    self.vote_chat_text = snap.get('vote_chat_text', '')
    self.vote_slots = snap.get('vote_slots', [])

    tasks = snap.get('task_states', {})
    self.task_mandatory = tasks.get('mandatory', 0)
    self.task_completed = tasks.get('completed', 0)
    self.task_checkout = tasks.get('checkout', 0)
    self.task_total = tasks.get('total', 0)
    self.task_progress = (
      self.task_completed / self.task_total if self.task_total > 0 else 0.0
    )

    self.visible_players = [
      VisiblePlayer(c['color'], c['x'], c['y'], c.get('room', 'unknown'))
      for c in snap.get('visible_crewmates', [])
    ]
    self.visible_bodies = snap.get('visible_bodies', [])
    self.visible_ghosts = snap.get('visible_ghosts', [])
    self.self_color = snap.get('self_color', self.self_color)

    alive = snap.get('alive_count', -1)
    self.alive_count = alive if alive >= 0 else len(self.vote_slots)


# ---------------------------------------------------------------------------
# Tier 2 — Episodic Memory
# ---------------------------------------------------------------------------

@dataclass
class GameEvent:
  tick: int
  hall: EventHall
  text: str
  landmark: bool = False
  data: dict = field(default_factory=dict)
  timestamp: float = field(default_factory=time.time)


class EpisodicMemory:

  def __init__(self, max_events: int = MAX_EPISODIC_EVENTS):
    self.max_events = max_events
    self.events: deque[GameEvent] = deque()
    self._landmarks: list[GameEvent] = []

  def record(self, event: GameEvent) -> None:
    if event.landmark:
      self._landmarks.append(event)
    if len(self.events) >= self.max_events:
      self._evict_oldest_non_landmark()
    self.events.append(event)

  def _evict_oldest_non_landmark(self) -> None:
    for i, ev in enumerate(self.events):
      if not ev.landmark:
        del self.events[i]
        return
    if self.events:
      self.events.popleft()

  def recent(self, n: int = 10) -> list[GameEvent]:
    return list(self.events)[-n:]

  def by_hall(self, hall: EventHall, n: int = 10) -> list[GameEvent]:
    return [e for e in self.events if e.hall == hall][-n:]

  @property
  def landmarks(self) -> list[GameEvent]:
    return list(self._landmarks)

  def clear(self) -> None:
    self.events.clear()
    self._landmarks.clear()


# ---------------------------------------------------------------------------
# Tier 3 — Strategic Memory
# ---------------------------------------------------------------------------

@dataclass
class StrategicFact:
  key: str
  value: Any
  tick: int
  category: str = 'general'
  history: list[tuple[Any, int]] = field(default_factory=list)


class StrategicMemory:

  def __init__(self):
    self.facts: dict[str, StrategicFact] = {}

  def set(self, key: str, value: Any, tick: int, category: str = 'general') -> None:
    existing = self.facts.get(key)
    if existing is not None:
      existing.history.append((existing.value, existing.tick))
      existing.value = value
      existing.tick = tick
    else:
      self.facts[key] = StrategicFact(
        key=key, value=value, tick=tick, category=category
      )

  def get(self, key: str, default: Any = None) -> Any:
    fact = self.facts.get(key)
    return fact.value if fact is not None else default

  def get_fact(self, key: str) -> StrategicFact | None:
    return self.facts.get(key)

  def history(self, key: str) -> list[tuple[Any, int]]:
    fact = self.facts.get(key)
    if fact is None:
      return []
    return list(fact.history) + [(fact.value, fact.tick)]

  def by_category(self, category: str) -> dict[str, StrategicFact]:
    return {k: v for k, v in self.facts.items() if v.category == category}

  def clear(self) -> None:
    self.facts.clear()

  def snapshot(self) -> dict[str, Any]:
    return {k: {'value': f.value, 'tick': f.tick, 'category': f.category}
            for k, f in self.facts.items()}


# ---------------------------------------------------------------------------
# Game Memory Container
# ---------------------------------------------------------------------------

class GameMemory:

  def __init__(self):
    self.working = WorkingMemory()
    self.episodic = EpisodicMemory()
    self.strategic = StrategicMemory()
    self.game_id: str = ''
    self.role: str = 'unknown'

  def reset_for_new_game(self, game_id: str) -> None:
    self.game_id = game_id
    self.role = 'unknown'
    self.working = WorkingMemory()
    self.episodic.clear()
    self.strategic.clear()
