"""Per-player state tracking and suspicion scoring."""

from __future__ import annotations

from dataclasses import dataclass, field

from .memory import PLAYER_COLOR_NAMES, WorkingMemory


SUSPICION_DECAY = 0.995
SUSPICION_NEAR_BODY = 0.3
SUSPICION_ACCUSED = 0.2
SUSPICION_ALONE_IN_LOW_TRAFFIC = 0.1
SUSPICION_QUIET = 0.05
SUSPICION_CLEARED_BY_EJECTION = -0.4

HIGH_TRAFFIC_ROOMS = {
  'Cafeteria', 'West Cafeteria', 'East Cafeteria', 'North Cafeteria',
  'South Cafeteria', 'MedBay', 'Admin',
}


@dataclass
class PlayerInfo:
  color: int
  status: str = 'alive'
  last_room: str = 'unknown'
  last_seen_tick: int = 0
  last_x: int = 0
  last_y: int = 0
  suspicion: float = 0.0
  alibi: str = ''
  times_accused: int = 0
  times_spoke: int = 0
  was_with: list[int] = field(default_factory=list)
  rooms_visited: list[str] = field(default_factory=list)

  @property
  def is_alive(self) -> bool:
    return self.status == 'alive'


class PlayerModel:

  def __init__(self):
    self.players: dict[int, PlayerInfo] = {}

  def get_or_create(self, color: int) -> PlayerInfo:
    if color not in self.players:
      self.players[color] = PlayerInfo(color=color)
    return self.players[color]

  def update_sighting(self, color: int, x: int, y: int, room: str, tick: int) -> None:
    info = self.get_or_create(color)
    info.last_room = room
    info.last_seen_tick = tick
    info.last_x = x
    info.last_y = y
    if not info.rooms_visited or info.rooms_visited[-1] != room:
      info.rooms_visited.append(room)
      if len(info.rooms_visited) > 20:
        info.rooms_visited = info.rooms_visited[-20:]

  def mark_dead(self, color: int) -> None:
    info = self.get_or_create(color)
    info.status = 'dead'

  def mark_ejected(self, color: int) -> None:
    info = self.get_or_create(color)
    info.status = 'ejected'

  def add_suspicion(self, color: int, amount: float, reason: str = '') -> None:
    info = self.get_or_create(color)
    info.suspicion = max(0.0, min(1.0, info.suspicion + amount))

  def decay_all(self) -> None:
    for info in self.players.values():
      if info.is_alive:
        info.suspicion *= SUSPICION_DECAY

  def record_accusation(self, accused_color: int) -> None:
    info = self.get_or_create(accused_color)
    info.times_accused += 1
    self.add_suspicion(accused_color, SUSPICION_ACCUSED, 'accused in chat')

  def record_near_body(self, color: int) -> None:
    self.add_suspicion(color, SUSPICION_NEAR_BODY, 'near body')

  def record_spoke(self, color: int) -> None:
    info = self.get_or_create(color)
    info.times_spoke += 1

  def set_alibi(self, color: int, alibi: str) -> None:
    info = self.get_or_create(color)
    info.alibi = alibi

  def update_from_working_memory(self, wm: WorkingMemory) -> None:
    """Batch-update sightings from the current frame's visible players."""
    for vp in wm.visible_players:
      self.update_sighting(vp.color, vp.x, vp.y, vp.room, wm.tick)

    # track who is together
    visible_colors = [vp.color for vp in wm.visible_players]
    for vp in wm.visible_players:
      info = self.get_or_create(vp.color)
      companions = [c for c in visible_colors if c != vp.color]
      info.was_with = companions

    self.decay_all()

  def most_suspicious(self, exclude: set[int] | None = None) -> PlayerInfo | None:
    exclude = exclude or set()
    best = None
    for info in self.players.values():
      if info.color in exclude:
        continue
      if not info.is_alive:
        continue
      if best is None or info.suspicion > best.suspicion:
        best = info
    return best

  def alive_players(self) -> list[PlayerInfo]:
    return [p for p in self.players.values() if p.is_alive]

  def clear(self) -> None:
    self.players.clear()
