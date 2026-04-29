"""LLM Strategic Advisor — conversation management, directive parsing.

Uses the providers module for all LLM calls.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path

from .providers import create_provider

logger = logging.getLogger(__name__)

SYSTEM_PROMPT_DIR = Path(__file__).parent / 'prompts'
MAX_CONVERSATION_HISTORY = 30
LLM_CALL_BUDGET = 50


@dataclass
class Directive:
  strategy: str = 'blend_in'
  target_player: str | None = None
  target_player_color: int = -1
  target_room: str | None = None
  vote_target: str | None = None
  vote_target_color: int = -1
  chat_message: str | None = None
  navigate_to: tuple[int, int] | None = None
  reasoning: str = ''
  hold: bool = False
  until: str | None = None
  expires_tick: int = 0
  created_tick: int = 0

  def is_expired(self, tick: int) -> bool:
    return self.expires_tick > 0 and tick >= self.expires_tick

  def to_nim_json(self) -> dict:
    d: dict = {
      'type': 'directive',
      'strategy': self.strategy,
      'hold': self.hold,
      'reasoning': self.reasoning,
    }
    if self.target_player_color >= 0:
      d['target_player_color'] = self.target_player_color
    if self.target_room:
      d['target_room'] = self.target_room
    if self.vote_target_color >= 0:
      d['vote_target_color'] = self.vote_target_color
    if self.chat_message:
      d['chat_message'] = self.chat_message
    if self.navigate_to:
      d['navigate_to'] = list(self.navigate_to)
    if self.until:
      d['until'] = self.until
    return d


def _color_name_to_index(name: str | None) -> int:
  if not name:
    return -1
  from .memory import PLAYER_COLOR_NAMES
  lower = name.lower().strip()
  for i, cn in enumerate(PLAYER_COLOR_NAMES):
    if cn == lower:
      return i
  return -1


def _parse_directive(raw: dict, tick: int) -> Directive:
  strategy = raw.get('strategy', 'blend_in')
  target_player = raw.get('target_player')
  target_room = raw.get('target_room')
  vote_target = raw.get('vote_target')
  chat_message = raw.get('chat_message')
  reasoning = raw.get('reasoning', '')
  hold = raw.get('hold', False)
  until = raw.get('until')
  nav = raw.get('navigate_to')
  navigate_to = tuple(nav) if nav and len(nav) == 2 else None

  return Directive(
    strategy=strategy,
    target_player=target_player,
    target_player_color=_color_name_to_index(target_player),
    target_room=target_room,
    vote_target=vote_target,
    vote_target_color=_color_name_to_index(vote_target),
    chat_message=chat_message,
    navigate_to=navigate_to,
    reasoning=reasoning,
    hold=hold,
    until=until,
    expires_tick=tick + 300,
    created_tick=tick,
  )


def _load_prompt(filename: str) -> str:
  path = SYSTEM_PROMPT_DIR / filename
  if path.exists():
    return path.read_text()
  return ''


class Advisor:
  """Manages conversation history and produces strategic directives from LLM."""

  def __init__(self, provider_spec: str = 'bedrock', model: str = ''):
    spec = f'{provider_spec}:{model}' if model else provider_spec
    self.provider = create_provider(spec)
    self.conversation: list[dict] = []
    self.system_prompt: str = ''
    self.call_count: int = 0
    self.call_budget: int = LLM_CALL_BUDGET
    self.call_log: list[dict] = []

  def init_game(self, role: str, color: str, learnings: str = '',
                min_players: int = 8, imposter_count: int = 2,
                tasks_per_player: int = 6) -> None:
    base = _load_prompt('system.md')
    role_prompt = _load_prompt(f'{role}.md')

    self.system_prompt = base.format(
      ROLE=role.upper(),
      color=color,
      minPlayers=min_players,
      imposterCount=imposter_count,
      tasksPerPlayer=tasks_per_player,
      prior_learnings=learnings or 'No prior game data yet.',
      role_guidance=role_prompt,
    )
    self.conversation = []
    self.call_count = 0
    self.call_log = []

  def consult(self, context: str, trigger_type: str, tick: int) -> Directive | None:
    if self.call_count >= self.call_budget:
      logger.warning('LLM call budget exhausted (%d/%d)', self.call_count, self.call_budget)
      return None

    user_msg = f'[TRIGGER: {trigger_type}]\n\n{context}'
    self.conversation.append({'role': 'user', 'content': user_msg})

    # trim conversation to sliding window
    if len(self.conversation) > MAX_CONVERSATION_HISTORY:
      self.conversation = self.conversation[-MAX_CONVERSATION_HISTORY:]

    start = time.time()
    try:
      llm_response = self.provider.complete(self.system_prompt, self.conversation)
      response = llm_response.text
    except Exception as e:
      logger.error('LLM call failed: %s', e)
      response = None
    elapsed = time.time() - start

    self.call_count += 1

    if response is None:
      logger.warning('LLM returned None for trigger %s', trigger_type)
      self.conversation.pop()
      return None

    self.conversation.append({'role': 'assistant', 'content': response})

    self.call_log.append({
      'tick': tick,
      'trigger': trigger_type,
      'response': response,
      'elapsed_ms': int(elapsed * 1000),
      'input_tokens': getattr(llm_response, 'input_tokens', 0) if llm_response else 0,
      'output_tokens': getattr(llm_response, 'output_tokens', 0) if llm_response else 0,
    })

    return self._parse_response(response, tick)

  def _parse_response(self, text: str, tick: int) -> Directive | None:
    # extract JSON from response (may have markdown fencing)
    clean = text.strip()
    if clean.startswith('```'):
      lines = clean.split('\n')
      lines = [l for l in lines if not l.strip().startswith('```')]
      clean = '\n'.join(lines)

    try:
      data = json.loads(clean)
      return _parse_directive(data, tick)
    except json.JSONDecodeError:
      # try to find JSON object in text
      start = clean.find('{')
      end = clean.rfind('}')
      if start >= 0 and end > start:
        try:
          data = json.loads(clean[start:end + 1])
          return _parse_directive(data, tick)
        except json.JSONDecodeError:
          pass
      logger.warning('Failed to parse LLM response as JSON: %s', text[:200])
      return None
