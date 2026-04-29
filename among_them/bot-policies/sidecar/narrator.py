"""Narrator — compresses all three memory tiers into a compact LLM prompt (~800 tokens).

Produces structured sections: working memory, recent events, player model, strategic summary.
"""

from __future__ import annotations

from .memory import (
  PLAYER_COLOR_NAMES,
  EventHall,
  GameMemory,
  GamePhase,
  WorkingMemory,
)
from .player_model import PlayerModel


def _color_name(index: int) -> str:
  if 0 <= index < len(PLAYER_COLOR_NAMES):
    return PLAYER_COLOR_NAMES[index]
  return f'color{index}'


def build_working_section(wm: WorkingMemory) -> str:
  role = 'IMPOSTER' if wm.is_imposter else 'CREWMATE'
  ghost = 'yes' if wm.is_ghost else 'no'
  kill = 'yes' if wm.kill_ready else 'no'
  visible = ', '.join(_color_name(p.color) for p in wm.visible_players) or 'none'
  phase = wm.phase.value
  task_pct = f'{wm.task_progress * 100:.0f}%'

  return (
    f'Tick: {wm.tick} | Phase: {phase} | Room: {wm.room}\n'
    f'Role: {role} | Ghost: {ghost} | Kill ready: {kill}\n'
    f'Players alive: {wm.alive_count} | Visible: {visible}\n'
    f'Task bar: ~{task_pct} complete ({wm.task_completed}/{wm.task_total})\n'
    f'Current intent: {wm.intent}'
  )


def build_events_section(memory: GameMemory, n: int = 10) -> str:
  events = memory.episodic.recent(n)
  if not events:
    return 'No events recorded yet.'
  lines = []
  for ev in reversed(events):
    marker = ' *' if ev.landmark else ''
    lines.append(f't={ev.tick}: {ev.text}{marker}')
  return '\n'.join(lines)


def build_player_section(model: PlayerModel, self_color: int) -> str:
  lines = []
  for color_idx, info in sorted(model.players.items()):
    if color_idx == self_color:
      continue
    name = _color_name(color_idx)
    status = info.status
    location = ''
    if info.last_room and info.last_room != 'unknown':
      location = f', last seen {info.last_room} t={info.last_seen_tick}'
    sus = f', sus={info.suspicion:.1f}'
    alibi = ''
    if info.alibi:
      alibi = f', alibi="{info.alibi}"'
    lines.append(f'{name}: {status}{location}{sus}{alibi}')
  return '\n'.join(lines) if lines else 'No player data yet.'


def build_strategic_section(memory: GameMemory) -> str:
  sm = memory.strategic
  lines = []

  kill_ready = sm.get('self:kill_ready', False)
  if kill_ready:
    lines.append('Kill cooldown: ready')

  unreported = sm.get('bodies:unreported_count', 0)
  if unreported:
    lines.append(f'Bodies unreported: {unreported}')

  alibi = sm.get('self:alibi', '')
  if alibi:
    lines.append(f'Our alibi: "{alibi}"')

  strategy = sm.get('strategy:current', '')
  if strategy:
    lines.append(f'Current strategy: {strategy}')

  risk = sm.get('self:risk_level', 'LOW')
  lines.append(f'Risk level: {risk}')

  failure = sm.get('failure:last_ejection_cause', '')
  if failure:
    lines.append(f'Last failure cause: {failure}')

  return '\n'.join(lines) if lines else 'No strategic context yet.'


def build_context(memory: GameMemory, model: PlayerModel, learnings: str = '') -> str:
  """Build the full narrator context for one LLM call."""
  sections = []

  sections.append('[WORKING MEMORY]')
  sections.append(build_working_section(memory.working))

  sections.append('\n[RECENT EVENTS]')
  sections.append(build_events_section(memory))

  sections.append('\n[PLAYER MODEL]')
  sections.append(build_player_section(model, memory.working.self_color))

  sections.append('\n[STRATEGIC SUMMARY]')
  sections.append(build_strategic_section(memory))

  if learnings:
    sections.append('\n[PRIOR GAME LEARNINGS]')
    sections.append(learnings)

  return '\n'.join(sections)
