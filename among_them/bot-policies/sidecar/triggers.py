"""Event detection from consecutive snapshot diffs.

Compares previous and current WorkingMemory to fire prioritized,
debounced triggers that drive LLM consultation.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum

from .memory import GamePhase, WorkingMemory


class TriggerType(Enum):
  BODY_DISCOVERED = 'body_discovered'
  MEETING_CALLED = 'meeting_called'
  KILL_OPPORTUNITY = 'kill_opportunity'
  ACCUSED_IN_CHAT = 'accused_in_chat'
  EJECTION_RESULT = 'ejection_result'
  KILL_COOLDOWN_READY = 'kill_cooldown_ready'
  PLAYER_MISSING = 'player_missing'
  ROOM_TRANSITION = 'room_transition'
  ROUND_START = 'round_start'
  GAME_OVER = 'game_over'
  STUCK_DETECTED = 'stuck_detected'
  IDLE_IN_ROOM = 'idle_in_room'
  PERIODIC = 'periodic'


TRIGGER_PRIORITY: dict[TriggerType, int] = {
  TriggerType.BODY_DISCOVERED: 100,
  TriggerType.MEETING_CALLED: 90,
  TriggerType.KILL_OPPORTUNITY: 80,
  TriggerType.ACCUSED_IN_CHAT: 70,
  TriggerType.EJECTION_RESULT: 60,
  TriggerType.KILL_COOLDOWN_READY: 50,
  TriggerType.PLAYER_MISSING: 40,
  TriggerType.ROOM_TRANSITION: 30,
  TriggerType.ROUND_START: 25,
  TriggerType.GAME_OVER: 20,
  TriggerType.STUCK_DETECTED: 15,
  TriggerType.IDLE_IN_ROOM: 12,
  TriggerType.PERIODIC: 10,
}

DEBOUNCE_TICKS: dict[TriggerType, int] = {
  TriggerType.BODY_DISCOVERED: 60,
  TriggerType.MEETING_CALLED: 120,
  TriggerType.KILL_OPPORTUNITY: 30,
  TriggerType.ACCUSED_IN_CHAT: 60,
  TriggerType.EJECTION_RESULT: 120,
  TriggerType.KILL_COOLDOWN_READY: 120,
  TriggerType.PLAYER_MISSING: 60,
  TriggerType.ROOM_TRANSITION: 40,
  TriggerType.ROUND_START: 120,
  TriggerType.GAME_OVER: 300,
  TriggerType.STUCK_DETECTED: 60,
  TriggerType.IDLE_IN_ROOM: 200,
  TriggerType.PERIODIC: 100,
}

STUCK_FRAME_THRESHOLD = 30
IDLE_ROOM_THRESHOLD = 200
PERIODIC_INTERVAL = 100


@dataclass
class Trigger:
  type: TriggerType
  tick: int
  priority: int
  data: dict = field(default_factory=dict)


class EventDetector:

  def __init__(self):
    self._prev: WorkingMemory | None = None
    self._last_fired: dict[TriggerType, int] = {}
    self._room_entry_tick: int = 0
    self._last_periodic_tick: int = 0
    self._prev_visible_colors: set[int] = set()

  def detect(self, current: WorkingMemory) -> Trigger | None:
    """Compare previous vs current state. Return highest-priority non-debounced trigger."""
    candidates: list[Trigger] = []
    prev = self._prev
    tick = current.tick

    if prev is not None:
      # meeting_called: transition to voting
      if not prev.voting and current.voting:
        candidates.append(Trigger(
          TriggerType.MEETING_CALLED, tick,
          TRIGGER_PRIORITY[TriggerType.MEETING_CALLED],
        ))

      # round_start: leaving interstitial back to playing
      if prev.phase in (GamePhase.VOTING, GamePhase.RESULTS) and \
         current.phase == GamePhase.PLAYING:
        candidates.append(Trigger(
          TriggerType.ROUND_START, tick,
          TRIGGER_PRIORITY[TriggerType.ROUND_START],
        ))

      # game_over
      if prev.phase != GamePhase.GAMEOVER and current.phase == GamePhase.GAMEOVER:
        candidates.append(Trigger(
          TriggerType.GAME_OVER, tick,
          TRIGGER_PRIORITY[TriggerType.GAME_OVER],
        ))

      # body_discovered: 0 bodies → 1+ bodies
      if len(prev.visible_bodies) == 0 and len(current.visible_bodies) > 0:
        candidates.append(Trigger(
          TriggerType.BODY_DISCOVERED, tick,
          TRIGGER_PRIORITY[TriggerType.BODY_DISCOVERED],
          data={'bodies': current.visible_bodies},
        ))

      # kill_cooldown_ready
      if not prev.kill_ready and current.kill_ready:
        candidates.append(Trigger(
          TriggerType.KILL_COOLDOWN_READY, tick,
          TRIGGER_PRIORITY[TriggerType.KILL_COOLDOWN_READY],
        ))

      # kill_opportunity: alone with exactly 1 non-imposter and kill ready
      if current.is_imposter and current.kill_ready and not current.is_ghost:
        if len(current.visible_players) == 1:
          target = current.visible_players[0]
          candidates.append(Trigger(
            TriggerType.KILL_OPPORTUNITY, tick,
            TRIGGER_PRIORITY[TriggerType.KILL_OPPORTUNITY],
            data={'target_color': target.color, 'target_room': target.room},
          ))

      # player_missing: someone vanished
      prev_colors = self._prev_visible_colors
      curr_colors = current.visible_player_colors
      missing = prev_colors - curr_colors - {current.self_color}
      if missing and current.phase == GamePhase.PLAYING:
        candidates.append(Trigger(
          TriggerType.PLAYER_MISSING, tick,
          TRIGGER_PRIORITY[TriggerType.PLAYER_MISSING],
          data={'missing_colors': list(missing)},
        ))

      # accused_in_chat
      if current.voting and current.vote_chat_text:
        self_name = self._color_name(current.self_color).lower()
        if self_name != 'unknown' and self_name in current.vote_chat_text.lower():
          candidates.append(Trigger(
            TriggerType.ACCUSED_IN_CHAT, tick,
            TRIGGER_PRIORITY[TriggerType.ACCUSED_IN_CHAT],
            data={'chat': current.vote_chat_text},
          ))

      # room_transition
      if prev.room != current.room and current.room != 'unknown':
        self._room_entry_tick = tick
        candidates.append(Trigger(
          TriggerType.ROOM_TRANSITION, tick,
          TRIGGER_PRIORITY[TriggerType.ROOM_TRANSITION],
          data={'from_room': prev.room, 'to_room': current.room},
        ))

    # stuck_detected
    if current.stuck_frames >= STUCK_FRAME_THRESHOLD:
      candidates.append(Trigger(
        TriggerType.STUCK_DETECTED, tick,
        TRIGGER_PRIORITY[TriggerType.STUCK_DETECTED],
      ))

    # idle_in_room
    if tick - self._room_entry_tick >= IDLE_ROOM_THRESHOLD and \
       current.phase == GamePhase.PLAYING:
      candidates.append(Trigger(
        TriggerType.IDLE_IN_ROOM, tick,
        TRIGGER_PRIORITY[TriggerType.IDLE_IN_ROOM],
        data={'room': current.room, 'duration': tick - self._room_entry_tick},
      ))

    # periodic fallback
    if tick - self._last_periodic_tick >= PERIODIC_INTERVAL:
      candidates.append(Trigger(
        TriggerType.PERIODIC, tick,
        TRIGGER_PRIORITY[TriggerType.PERIODIC],
      ))

    # update tracking state
    self._prev_visible_colors = current.visible_player_colors
    self._prev = current

    # filter debounced, pick highest priority
    valid = [t for t in candidates if self._can_fire(t, tick)]
    if not valid:
      return None

    valid.sort(key=lambda t: t.priority, reverse=True)
    winner = valid[0]
    self._last_fired[winner.type] = tick
    if winner.type == TriggerType.PERIODIC:
      self._last_periodic_tick = tick
    return winner

  def _can_fire(self, trigger: Trigger, tick: int) -> bool:
    last = self._last_fired.get(trigger.type)
    if last is None:
      return True
    debounce = DEBOUNCE_TICKS.get(trigger.type, 60)
    return tick - last >= debounce

  @staticmethod
  def _color_name(index: int) -> str:
    from .memory import PLAYER_COLOR_NAMES
    if 0 <= index < len(PLAYER_COLOR_NAMES):
      return PLAYER_COLOR_NAMES[index]
    return 'unknown'

  def reset(self) -> None:
    self._prev = None
    self._last_fired.clear()
    self._room_entry_tick = 0
    self._last_periodic_tick = 0
    self._prev_visible_colors = set()
