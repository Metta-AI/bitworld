"""Strategic Brain — orchestrates triggers → memory → narrator → advisor → directive.

The brain sits between perception (Nim snapshots) and output (directives).
It is the central coordinator that decides when to consult the LLM and
how to update memory from incoming events.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

from .advisor import Advisor, Directive
from .memory import (
  PLAYER_COLOR_NAMES,
  EventHall,
  GameEvent,
  GameMemory,
  GamePhase,
  WorkingMemory,
)
from .narrator import build_context
from .player_model import (
  SUSPICION_NEAR_BODY,
  PlayerModel,
)
from .providers import create_analysis_provider
from .triggers import EventDetector, Trigger, TriggerType

logger = logging.getLogger(__name__)


def _color_name(index: int) -> str:
  if 0 <= index < len(PLAYER_COLOR_NAMES):
    return PLAYER_COLOR_NAMES[index]
  return f'color{index}'


def _room_at(x: int, y: int) -> str:
  """Approximate room lookup matching the Nim Rooms table."""
  ROOMS = [
    ('Upper Engine', 159, 62, 100, 112),
    ('Reactor', 73, 184, 100, 112),
    ('Security', 255, 174, 73, 116),
    ('Lower Engine', 159, 310, 100, 112),
    ('Electrical', 347, 273, 105, 136),
    ('Coms', 577, 411, 115, 82),
    ('Storage', 452, 318, 125, 175),
    ('Shields', 695, 344, 97, 96),
    ('Admin', 593, 254, 102, 95),
    ('Nav', 807, 180, 134, 103),
    ('O2', 634, 199, 83, 45),
    ('Weapons', 673, 47, 119, 152),
    ('Cafeteria', 460, 58, 152, 141),
    ('MedBay', 328, 140, 100, 117),
  ]
  for name, rx, ry, rw, rh in ROOMS:
    if rx <= x < rx + rw and ry <= y < ry + rh:
      return name
  return 'unknown'


class Brain:
  """Central brain that processes snapshots, fires triggers, and produces directives."""

  def __init__(self, provider_spec: str = 'bedrock', model: str = ''):
    self.provider_spec = provider_spec
    self.memory = GameMemory()
    self.model = PlayerModel()
    self.detector = EventDetector()
    self.advisor = Advisor(provider_spec=provider_spec, model=model)
    self.current_directive: Directive | None = None
    self.learnings_text: str = ''
    self._snapshot_count: int = 0
    self._event_count: int = 0
    self._debug_server = None

  def init_game(self, game_id: str, role: str, self_color: int,
                min_players: int = 8, imposter_count: int = 2,
                tasks_per_player: int = 6) -> None:
    self.memory.reset_for_new_game(game_id)
    self.memory.role = role
    self.memory.working.self_color = self_color
    self.memory.working.is_imposter = (role == 'imposter')
    self.model.clear()
    self.detector.reset()
    self.current_directive = None
    self._snapshot_count = 0
    self._event_count = 0

    self.advisor.init_game(
      role=role,
      color=_color_name(self_color),
      learnings=self.learnings_text,
      min_players=min_players,
      imposter_count=imposter_count,
      tasks_per_player=tasks_per_player,
    )

  def process_snapshot(self, snap: dict) -> Directive | None:
    """Process one snapshot from Nim, update memory, check triggers, possibly consult LLM."""
    self._snapshot_count += 1
    wm = self.memory.working
    wm.update_from_snapshot(snap)

    self.model.update_from_working_memory(wm)
    self._record_memory_events(wm)

    # update strategic facts
    self._update_strategic_facts(wm)

    # check for triggers
    trigger = self.detector.detect(wm)
    if trigger is not None:
      self._record_trigger_event(trigger, wm)
      if self._debug_server:
        self._debug_server.emit_trigger(trigger, wm.tick)
      directive = self._consult_llm(trigger, wm)
      if directive is not None:
        self.current_directive = directive
        if self._debug_server:
          self._debug_server.emit_directive(directive, wm.tick)
        return directive

    # return held directive if still valid
    if self.current_directive and not self.current_directive.is_expired(wm.tick):
      return self.current_directive

    return None

  def process_event(self, event_data: dict) -> None:
    """Process an explicit event message from Nim."""
    self._event_count += 1
    event_type = event_data.get('event', '')
    tick = event_data.get('tick', self.memory.working.tick)
    data = event_data.get('data', {})

    if event_type == 'body_discovered':
      room = data.get('room', 'unknown')
      nearby = data.get('nearby_colors', [])
      self.memory.episodic.record(GameEvent(
        tick=tick,
        hall=EventHall.SIGHTINGS,
        text=f'body discovered in {room}',
        landmark=True,
        data=data,
      ))
      for color in nearby:
        self.model.record_near_body(color)

    elif event_type == 'player_ejected':
      color = data.get('color', -1)
      was_imposter = data.get('was_imposter', False)
      name = _color_name(color)
      role_text = 'was imposter' if was_imposter else 'was crewmate'
      self.memory.episodic.record(GameEvent(
        tick=tick,
        hall=EventHall.MEETINGS,
        text=f'{name} ejected ({role_text})',
        landmark=True,
        data=data,
      ))
      self.model.mark_ejected(color)

    elif event_type == 'kill_executed':
      victim = data.get('victim_color', -1)
      room = data.get('room', 'unknown')
      name = _color_name(victim)
      self.memory.episodic.record(GameEvent(
        tick=tick,
        hall=EventHall.KILLS,
        text=f'killed {name} in {room}',
        landmark=True,
        data=data,
      ))
      self.model.mark_dead(victim)

    elif event_type == 'game_result':
      result = data.get('result', 'unknown')
      self.memory.episodic.record(GameEvent(
        tick=tick,
        hall=EventHall.MEETINGS,
        text=f'game over: {result}',
        landmark=True,
        data=data,
      ))

  def _record_memory_events(self, wm: WorkingMemory) -> None:
    """Record sightings and movement into episodic memory."""
    tick = wm.tick

    for vp in wm.visible_players:
      name = _color_name(vp.color)
      room = vp.room if vp.room != 'unknown' else _room_at(vp.x, vp.y)
      self.memory.episodic.record(GameEvent(
        tick=tick,
        hall=EventHall.SIGHTINGS,
        text=f'saw {name} in {room}',
      ))

    for body in wm.visible_bodies:
      bx, by = body.get('x', 0), body.get('y', 0)
      room = _room_at(bx, by)
      self.memory.episodic.record(GameEvent(
        tick=tick,
        hall=EventHall.SIGHTINGS,
        text=f'body visible in {room}',
        landmark=True,
        data=body,
      ))

    # social: who is together
    if len(wm.visible_players) >= 2:
      names = [_color_name(p.color) for p in wm.visible_players]
      self.memory.episodic.record(GameEvent(
        tick=tick,
        hall=EventHall.SOCIAL,
        text=f'{", ".join(names)} together in {wm.room}',
      ))

  def _update_strategic_facts(self, wm: WorkingMemory) -> None:
    sm = self.memory.strategic
    tick = wm.tick

    for vp in wm.visible_players:
      name = _color_name(vp.color)
      room = vp.room if vp.room != 'unknown' else _room_at(vp.x, vp.y)
      sm.set(f'player:{name}:last_seen', {'room': room, 'tick': tick}, tick, 'map')
      sm.set(f'player:{name}:status', 'alive', tick, 'map')

    sm.set('self:kill_ready', wm.kill_ready, tick, 'strategy')
    sm.set('self:room', wm.room, tick, 'map')
    sm.set('self:alibi', f'in {wm.room} at t={tick}', tick, 'strategy')

    unreported = len(wm.visible_bodies)
    sm.set('bodies:unreported_count', unreported, tick, 'map')

    risk = 'LOW'
    if wm.is_imposter:
      if unreported > 0 and len(wm.visible_players) > 0:
        risk = 'HIGH'
      elif unreported > 0:
        risk = 'MEDIUM'
      elif len(wm.visible_players) > 0:
        risk = 'MEDIUM'
    sm.set('self:risk_level', risk, tick, 'strategy')

  def _record_trigger_event(self, trigger: Trigger, wm: WorkingMemory) -> None:
    hall_map = {
      TriggerType.BODY_DISCOVERED: EventHall.SIGHTINGS,
      TriggerType.MEETING_CALLED: EventHall.MEETINGS,
      TriggerType.KILL_OPPORTUNITY: EventHall.KILLS,
      TriggerType.ACCUSED_IN_CHAT: EventHall.SUSPICION,
      TriggerType.EJECTION_RESULT: EventHall.MEETINGS,
      TriggerType.ROOM_TRANSITION: EventHall.MOVEMENT,
    }
    hall = hall_map.get(trigger.type, EventHall.MOVEMENT)
    is_landmark = trigger.type in (
      TriggerType.BODY_DISCOVERED,
      TriggerType.MEETING_CALLED,
      TriggerType.EJECTION_RESULT,
      TriggerType.GAME_OVER,
    )

    self.memory.episodic.record(GameEvent(
      tick=trigger.tick,
      hall=hall,
      text=f'[trigger] {trigger.type.value}',
      landmark=is_landmark,
      data=trigger.data,
    ))

  def _consult_llm(self, trigger: Trigger, wm: WorkingMemory) -> Directive | None:
    # skip low-priority triggers if budget is getting tight
    remaining = self.advisor.call_budget - self.advisor.call_count
    if remaining <= 5 and trigger.priority < 50:
      return None

    context = build_context(self.memory, self.model, self.learnings_text)

    if self._debug_server:
      self._debug_server.emit_llm_request(
        trigger.type.value, context,
        len(self.advisor.conversation), wm.tick,
      )

    directive = self.advisor.consult(
      context=context,
      trigger_type=trigger.type.value,
      tick=wm.tick,
    )

    # emit LLM response from the call log
    if self._debug_server and self.advisor.call_log:
      last = self.advisor.call_log[-1]
      self._debug_server.emit_llm_response(
        trigger.type.value, last.get('response', ''),
        last.get('elapsed_ms', 0),
        last.get('input_tokens', 0),
        last.get('output_tokens', 0), wm.tick,
      )

    if directive is not None:
      logger.info(
        'LLM directive [%s]: strategy=%s target=%s reasoning=%s',
        trigger.type.value,
        directive.strategy,
        directive.target_player,
        directive.reasoning[:80],
      )
      self.memory.strategic.set(
        'strategy:current', directive.strategy, wm.tick, 'strategy'
      )

    return directive

  def get_game_dump(self) -> dict:
    """Produce a full memory dump for cross-game learning."""
    return {
      'game_id': self.memory.game_id,
      'role': self.memory.role,
      'snapshots_processed': self._snapshot_count,
      'events_processed': self._event_count,
      'llm_calls': self.advisor.call_count,
      'episodic_events': [
        {'tick': e.tick, 'hall': e.hall.value, 'text': e.text,
         'landmark': e.landmark, 'data': e.data}
        for e in self.memory.episodic.events
      ],
      'strategic_facts': self.memory.strategic.snapshot(),
      'llm_call_log': self.advisor.call_log,
      'player_model': {
        _color_name(k): {
          'status': v.status,
          'suspicion': v.suspicion,
          'last_room': v.last_room,
          'times_accused': v.times_accused,
        }
        for k, v in self.model.players.items()
      },
    }

  def run_post_game(self, result: str, project_root: str | None = None) -> dict | None:
    """Run post-game analysis and code evolution after a game ends.

    Args:
      result: Game result string (e.g. 'imposter_win', 'crew_win')
      project_root: Override for project root path (defaults to bot-policies/)

    Returns:
      Evolution log dict, or None on failure.
    """
    from .code_evolution import run_code_evolution
    from .learnings import dump_game
    from .post_game_analysis import run_post_game_analysis

    game_dump = self.get_game_dump()
    game_dump['result'] = result

    memory_dump_path = dump_game(game_dump)
    logger.info('Game dump saved to %s', memory_dump_path)

    try:
      analysis_provider = create_analysis_provider(self.provider_spec)
      analysis = run_post_game_analysis(game_dump, analysis_provider, memory_dump_path)
    except Exception as e:
      logger.error('Post-game analysis failed: %s', e)
      analysis = None

    if analysis is None:
      logger.warning('Skipping code evolution — analysis failed')
      return None

    learnings_path = memory_dump_path.parent / memory_dump_path.name.replace(
      '_memory.json', '_learnings.json')
    if not learnings_path.exists():
      logger.warning('Learnings file not found at %s, skipping evolution', learnings_path)
      return None

    try:
      evolution_log = run_code_evolution(
        memory_dump_path=str(memory_dump_path),
        learnings_path=str(learnings_path),
        provider_spec=self.provider_spec,
      )
    except Exception as e:
      logger.error('Code evolution failed: %s', e)
      return None

    logger.info('Post-game pipeline complete: analysis_score=%s, evolution_success=%s',
                analysis.get('score', '?'), evolution_log.get('success', False))
    return evolution_log
