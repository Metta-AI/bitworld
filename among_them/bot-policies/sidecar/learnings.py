"""Cross-game learning — dump game memory, load priors, synthesize learnings."""

from __future__ import annotations

import json
import logging
import os
import uuid
from pathlib import Path

logger = logging.getLogger(__name__)

RUNS_DIR = Path(__file__).parent.parent / 'runs'
MAX_PRIOR_GAMES = 20


def generate_game_id() -> str:
  return uuid.uuid4().hex[:8]


def dump_game(game_dump: dict) -> Path:
  """Save one game's full memory dump to the runs directory."""
  RUNS_DIR.mkdir(parents=True, exist_ok=True)
  game_id = game_dump.get('game_id', generate_game_id())
  path = RUNS_DIR / f'{game_id}_memory.json'
  with open(path, 'w') as f:
    json.dump(game_dump, f, indent=2, default=str)
  logger.info('Game dump saved to %s', path)
  return path


def load_prior_games(n: int = MAX_PRIOR_GAMES) -> list[dict]:
  """Load the most recent N game dumps."""
  if not RUNS_DIR.exists():
    return []
  files = sorted(RUNS_DIR.glob('*_memory.json'), key=os.path.getmtime, reverse=True)
  games = []
  for f in files[:n]:
    try:
      with open(f) as fh:
        games.append(json.load(fh))
    except (json.JSONDecodeError, OSError) as e:
      logger.warning('Failed to load game dump %s: %s', f, e)
  return games


def _count_outcomes(games: list[dict]) -> dict:
  stats: dict = {
    'total': len(games),
    'wins': 0,
    'losses': 0,
    'imposter_games': 0,
    'imposter_wins': 0,
    'crewmate_games': 0,
    'crewmate_wins': 0,
  }
  for g in games:
    role = g.get('role', 'unknown')
    # determine win by checking if game result matches role's win condition
    events = g.get('episodic_events', [])
    result_text = ''
    for ev in reversed(events):
      if ev.get('landmark') and 'game over' in ev.get('text', ''):
        result_text = ev.get('text', '')
        break

    is_imposter = role == 'imposter'
    won = False
    if 'imposter_win' in result_text or 'IMPS WIN' in result_text:
      won = is_imposter
    elif 'crew_win' in result_text or 'CREW WINS' in result_text:
      won = not is_imposter

    if is_imposter:
      stats['imposter_games'] += 1
      if won:
        stats['imposter_wins'] += 1
        stats['wins'] += 1
      else:
        stats['losses'] += 1
    else:
      stats['crewmate_games'] += 1
      if won:
        stats['crewmate_wins'] += 1
        stats['wins'] += 1
      else:
        stats['losses'] += 1

  return stats


def _extract_strategies(games: list[dict]) -> dict[str, list[str]]:
  """Extract strategy patterns from game dumps."""
  imposter_success: list[str] = []
  imposter_failure: list[str] = []
  crewmate_success: list[str] = []
  crewmate_failure: list[str] = []

  for g in games:
    role = g.get('role', 'unknown')
    call_log = g.get('llm_call_log', [])
    strategies = set()
    for call in call_log:
      resp = call.get('response', '')
      if '"strategy"' in resp:
        try:
          start = resp.find('{')
          end = resp.rfind('}')
          if start >= 0 and end > start:
            d = json.loads(resp[start:end + 1])
            s = d.get('strategy', '')
            if s:
              strategies.add(s)
        except (json.JSONDecodeError, KeyError):
          pass

    events = g.get('episodic_events', [])
    result_text = ''
    for ev in reversed(events):
      if ev.get('landmark') and 'game over' in ev.get('text', ''):
        result_text = ev.get('text', '')
        break

    is_imposter = role == 'imposter'
    won = ('imposter_win' in result_text or 'IMPS WIN' in result_text) == is_imposter

    strat_list = list(strategies) if strategies else ['unknown']
    if is_imposter:
      (imposter_success if won else imposter_failure).extend(strat_list)
    else:
      (crewmate_success if won else crewmate_failure).extend(strat_list)

  return {
    'imposter_success': imposter_success,
    'imposter_failure': imposter_failure,
    'crewmate_success': crewmate_success,
    'crewmate_failure': crewmate_failure,
  }


def _extract_failures(games: list[dict]) -> list[str]:
  """Extract notable failure causes from games."""
  failures = []
  for g in games:
    facts = g.get('strategic_facts', {})
    cause = facts.get('failure:last_ejection_cause', {})
    if isinstance(cause, dict):
      val = cause.get('value', '')
    else:
      val = str(cause)
    if val:
      failures.append(val)
  return failures[-5:]


def synthesize_learnings(games: list[dict] | None = None) -> str:
  """Build a compact prior-learnings block for the system prompt."""
  if games is None:
    games = load_prior_games()
  if not games:
    return ''

  stats = _count_outcomes(games)
  strategies = _extract_strategies(games)
  failures = _extract_failures(games)

  total = stats['total']
  win_rate = (stats['wins'] / total * 100) if total > 0 else 0

  lines = [
    f"Games played: {total} | Win rate: {win_rate:.0f}%",
  ]

  ig = stats['imposter_games']
  if ig:
    iw = stats['imposter_wins']
    lines.append(f"As imposter ({ig} games): {iw} wins, {ig - iw} losses")
    if strategies['imposter_success']:
      from collections import Counter
      top = Counter(strategies['imposter_success']).most_common(3)
      lines.append(f"  - Winning strategies: {', '.join(s for s, _ in top)}")
    if strategies['imposter_failure']:
      from collections import Counter
      top = Counter(strategies['imposter_failure']).most_common(2)
      lines.append(f"  - Losing strategies: {', '.join(s for s, _ in top)}")

  cg = stats['crewmate_games']
  if cg:
    cw = stats['crewmate_wins']
    lines.append(f"As crewmate ({cg} games): {cw} wins, {cg - cw} losses")
    if strategies['crewmate_success']:
      from collections import Counter
      top = Counter(strategies['crewmate_success']).most_common(3)
      lines.append(f"  - Winning strategies: {', '.join(s for s, _ in top)}")

  if failures:
    lines.append(f"Recent failures: {'; '.join(failures)}")

  return '\n'.join(lines)
