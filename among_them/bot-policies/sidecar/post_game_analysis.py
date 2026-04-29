"""Post-game analysis — Opus reviews full memory dump and writes structured learnings.

After each game, the analysis provider (Opus) examines the complete memory dump
and produces actionable insights: what worked, what failed, social dynamics,
timing patterns, and concrete rules for future games.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

from .providers import LLMResponse

logger = logging.getLogger('smartbot.post_game_analysis')

ANALYSIS_SYSTEM_PROMPT = """You are an expert analyst for "Among Them", a social deduction game similar to Among Us.

A bot just finished a game. You have its full memory dump: every event it saw, every LLM call it made, every strategic decision, and the player model it built.

Your job: perform a ruthlessly honest post-game review. Identify what the bot did well, what it did poorly, and extract concrete, actionable rules it should follow in future games.

Key game mechanics to evaluate:
- As IMPOSTER: killing timing, alibi construction, deflection during meetings, body discovery risk management, sabotage usage, social manipulation
- As CREWMATE: task efficiency, body reporting speed, accusation accuracy, voting decisions, movement patterns for safety, information gathering
- SOCIAL DYNAMICS: who was suspicious of whom, alliance formation, chat effectiveness, vote coordination
- TIMING: when kills happened relative to witnesses, meeting call timing, how long the bot spent idle vs productive

Output ONLY valid JSON with this exact structure:
{
  "score": <1-10 overall performance>,
  "what_worked": ["<specific thing 1>", "<specific thing 2>", ...],
  "what_failed": ["<specific failure 1>", "<specific failure 2>", ...],
  "actionable_rules": [
    "<concrete rule the bot should follow, e.g. 'Never kill when 3+ players visible within 2 rooms'>",
    "<another rule>",
    ...
  ],
  "social_insights": [
    "<observation about social dynamics, e.g. 'Red consistently accused us after body discoveries — treat as hostile'>",
    ...
  ],
  "timing_insights": [
    "<timing observation, e.g. 'Kills in first 30 ticks after round start were never witnessed'>",
    ...
  ],
  "biggest_mistake": "<the single most impactful error and why it mattered>",
  "recommended_next_game_strategy": "<1-2 sentence strategy recommendation for the next game>"
}

Be specific. Reference actual events, tick numbers, player colors, and rooms from the memory dump.
Do NOT be generic — every insight should be grounded in what actually happened this game."""


def _build_analysis_prompt(memory_dump: dict) -> str:
  """Extract key sections from memory dump into a compact analysis prompt."""
  sections = []

  sections.append(f"Game ID: {memory_dump.get('game_id', 'unknown')}")
  sections.append(f"Role: {memory_dump.get('role', 'unknown')}")
  sections.append(f"Result: {memory_dump.get('result', 'unknown')}")
  sections.append(f"Snapshots processed: {memory_dump.get('snapshots_processed', 0)}")
  sections.append(f"LLM calls made: {memory_dump.get('llm_calls', 0)}")

  events = memory_dump.get('episodic_events', [])
  landmarks = [e for e in events if e.get('landmark')]
  if landmarks:
    sections.append('\n--- LANDMARK EVENTS ---')
    for ev in landmarks:
      sections.append(f"  t={ev.get('tick', '?')}: {ev.get('text', '')} [{ev.get('hall', '')}]")

  recent = events[-30:] if len(events) > 30 else events
  if recent:
    sections.append('\n--- RECENT EVENTS (last 30) ---')
    for ev in recent:
      marker = ' *' if ev.get('landmark') else ''
      sections.append(f"  t={ev.get('tick', '?')}: {ev.get('text', '')}{marker}")

  facts = memory_dump.get('strategic_facts', {})
  if facts:
    sections.append('\n--- STRATEGIC FACTS ---')
    for key, val in facts.items():
      if isinstance(val, dict):
        sections.append(f"  {key}: {val.get('value', val)} (t={val.get('tick', '?')})")
      else:
        sections.append(f"  {key}: {val}")

  player_model = memory_dump.get('player_model', {})
  if player_model:
    sections.append('\n--- PLAYER MODEL ---')
    for name, info in player_model.items():
      parts = [f"status={info.get('status', '?')}"]
      sus = info.get('suspicion', 0)
      if sus > 0:
        parts.append(f"sus={sus:.2f}")
      room = info.get('last_room', '')
      if room and room != 'unknown':
        parts.append(f"last_room={room}")
      acc = info.get('times_accused', 0)
      if acc > 0:
        parts.append(f"accused={acc}x")
      sections.append(f"  {name}: {', '.join(parts)}")

  call_log = memory_dump.get('llm_call_log', [])
  if call_log:
    sections.append(f'\n--- LLM CALL LOG ({len(call_log)} calls) ---')
    for i, call in enumerate(call_log):
      trigger = call.get('trigger', '?')
      tick = call.get('tick', '?')
      elapsed = call.get('elapsed_ms', '?')
      resp_preview = call.get('response', '')[:150]
      sections.append(f"  [{i+1}] t={tick} trigger={trigger} ({elapsed}ms): {resp_preview}...")

  return '\n'.join(sections)


def run_post_game_analysis(memory_dump: dict, provider, memory_dump_path: Path | None = None) -> dict | None:
  """Run Opus post-game analysis on a completed game's memory dump.

  Args:
    memory_dump: Full game memory dump dict from Brain.get_game_dump()
    provider: An analysis-tier LLM provider (typically Opus via create_analysis_provider)
    memory_dump_path: Optional path where the memory dump was saved (for co-locating learnings)

  Returns:
    Parsed analysis dict, or None on failure. Also saves to _learnings.json alongside dump.
  """
  prompt = _build_analysis_prompt(memory_dump)
  logger.info('Running post-game analysis (%d chars prompt)', len(prompt))

  t0 = time.monotonic()
  try:
    response: LLMResponse = provider.complete(
      system=ANALYSIS_SYSTEM_PROMPT,
      messages=[{'role': 'user', 'content': prompt}],
      max_tokens=4096,
    )
  except Exception as e:
    logger.error('Post-game analysis LLM call failed: %s', e)
    return None

  elapsed = time.monotonic() - t0
  logger.info('Analysis complete in %.1fs (%d input, %d output tokens)',
              elapsed, response.input_tokens, response.output_tokens)

  try:
    analysis = json.loads(response.text)
  except json.JSONDecodeError:
    start = response.text.find('{')
    end = response.text.rfind('}')
    if start >= 0 and end > start:
      try:
        analysis = json.loads(response.text[start:end + 1])
      except json.JSONDecodeError:
        logger.error('Failed to parse analysis JSON: %s', response.text[:300])
        return None
    else:
      logger.error('No JSON found in analysis response: %s', response.text[:300])
      return None

  analysis['_meta'] = {
    'model': response.model,
    'latency_ms': response.latency_ms,
    'input_tokens': response.input_tokens,
    'output_tokens': response.output_tokens,
    'game_id': memory_dump.get('game_id', 'unknown'),
    'role': memory_dump.get('role', 'unknown'),
    'result': memory_dump.get('result', 'unknown'),
  }

  learnings_path = _save_learnings(analysis, memory_dump_path)
  if learnings_path:
    logger.info('Learnings saved to %s', learnings_path)

  return analysis


def _save_learnings(analysis: dict, memory_dump_path: Path | None) -> Path | None:
  """Save learnings JSON alongside the memory dump file."""
  if memory_dump_path is None:
    from .learnings import RUNS_DIR
    memory_dump_path = RUNS_DIR / 'latest_memory.json'

  dump_path = Path(memory_dump_path)
  learnings_path = dump_path.parent / dump_path.name.replace('_memory.json', '_learnings.json')

  try:
    learnings_path.parent.mkdir(parents=True, exist_ok=True)
    with open(learnings_path, 'w') as f:
      json.dump(analysis, f, indent=2, default=str)
    return learnings_path
  except OSError as e:
    logger.error('Failed to save learnings: %s', e)
    return None
