"""Code evolution — self-editing pipeline driven by post-game learnings.

After post-game analysis produces learnings, this module:
1. Reads all editable policy files + learnings + memory dump
2. Calls Bedrock converse with a str_replace tool to make 1-3 surgical code edits
3. Falls back to OpenCode CLI if direct API fails
4. Commits changes, pushes to evolution branch, creates PR, auto-merges
5. Accumulates cross-game memory
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

from .providers import (
  BedrockProvider,
  ToolCall,
  ToolLoopResponse,
  ToolResult,
  create_evolution_provider,
)

logger = logging.getLogger('smartbot.code_evolution')

PROJECT_ROOT = Path(__file__).resolve().parent.parent

EDITABLE_FILES = [
  'sidecar/brain.py',
  'sidecar/narrator.py',
  'sidecar/triggers.py',
  'sidecar/player_model.py',
  'sidecar/prompts/system.md',
  'sidecar/prompts/imposter.md',
  'sidecar/prompts/crewmate.md',
]

CROSS_GAME_MEMORY_FILE = PROJECT_ROOT / 'runs' / '_cross_game_memory.json'

STR_REPLACE_TOOL = {
  'name': 'str_replace',
  'description': (
    'Replace an exact string in a file with a new string. '
    'The old_str must match EXACTLY (including whitespace and indentation). '
    'Use this to make surgical edits to bot policy files.'
  ),
  'inputSchema': {
    'json': {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Relative path from project root (e.g. sidecar/brain.py)',
        },
        'old_str': {
          'type': 'string',
          'description': 'Exact string to find in the file (must match perfectly)',
        },
        'new_str': {
          'type': 'string',
          'description': 'Replacement string',
        },
      },
      'required': ['path', 'old_str', 'new_str'],
    },
  },
}

EVOLUTION_SYSTEM_PROMPT = """You are the code evolution engine for an Among Them smart bot (social deduction game, like Among Us).

You have just received post-game analysis (learnings) from an Opus-tier review of the bot's last game.
Your job: make 1-3 SURGICAL code edits to improve the bot's play based on those learnings.

## Architecture you can edit:
- **sidecar/brain.py**: Central coordinator — processes snapshots, fires triggers, consults LLM, manages game flow. Edit decision thresholds, trigger priorities, or strategic logic.
- **sidecar/narrator.py**: Builds the context string sent to the LLM. Edit to change what information the bot considers.
- **sidecar/triggers.py**: Event detection from snapshot diffs. Edit debounce timings, detection thresholds, or add new trigger conditions.
- **sidecar/player_model.py**: Per-player suspicion scoring. Edit suspicion weights, decay rates, or tracking logic.
- **sidecar/prompts/system.md**: Base system prompt template. Edit to change the bot's personality, decision framework, or strategic guidelines.
- **sidecar/prompts/imposter.md**: Imposter-specific prompt guidance. Edit kill timing rules, alibi strategies, deflection tactics.
- **sidecar/prompts/crewmate.md**: Crewmate-specific prompt guidance. Edit task priority, body reporting, voting strategy.

## Rules:
1. Make ONLY changes supported by the learnings. Every edit must trace to a specific learning.
2. Prefer small, targeted edits over rewrites. Change a threshold, add a condition, adjust a weight.
3. Do NOT break the code. Preserve all imports, class signatures, and API contracts.
4. Do NOT edit providers.py, advisor.py, main.py, or learnings.py — those are infrastructure.
5. For prompt files (.md), you can add/modify strategic rules, examples, or decision criteria.
6. For Python files, you can adjust numeric constants, add conditions to if-statements, modify string templates, or add small helper logic.
7. After making edits, output a brief summary of what you changed and why.

Use the str_replace tool to make each edit. The old_str must match the file content EXACTLY."""


def _execute_str_replace(tool_call: ToolCall) -> ToolResult:
  """Execute a str_replace tool call against the project files."""
  path_str = tool_call.input.get('path', '')
  old_str = tool_call.input.get('old_str', '')
  new_str = tool_call.input.get('new_str', '')

  if not path_str or not old_str:
    return ToolResult(tool_use_id=tool_call.tool_use_id,
                      content='Error: path and old_str are required', is_error=True)

  if path_str not in EDITABLE_FILES:
    return ToolResult(tool_use_id=tool_call.tool_use_id,
                      content=f'Error: {path_str} is not in EDITABLE_FILES', is_error=True)

  full_path = PROJECT_ROOT / path_str
  if not full_path.exists():
    return ToolResult(tool_use_id=tool_call.tool_use_id,
                      content=f'Error: file not found: {path_str}', is_error=True)

  content = full_path.read_text()
  if old_str not in content:
    snippet = old_str[:100].replace('\n', '\\n')
    return ToolResult(tool_use_id=tool_call.tool_use_id,
                      content=f'Error: old_str not found in {path_str}. Snippet: "{snippet}"',
                      is_error=True)

  count = content.count(old_str)
  if count > 1:
    return ToolResult(tool_use_id=tool_call.tool_use_id,
                      content=f'Error: old_str found {count} times in {path_str}. Must be unique.',
                      is_error=True)

  new_content = content.replace(old_str, new_str, 1)
  full_path.write_text(new_content)

  logger.info('str_replace: %s (%d chars -> %d chars)', path_str, len(old_str), len(new_str))
  return ToolResult(tool_use_id=tool_call.tool_use_id,
                    content=f'OK: replaced {len(old_str)} chars with {len(new_str)} chars in {path_str}')


def _build_evolution_prompt(learnings: dict, memory_dump: dict, cross_game_memory: dict) -> str:
  """Build the user-turn prompt with all context for the evolution model."""
  sections = []

  sections.append('## Post-Game Learnings')
  sections.append(json.dumps(learnings, indent=2, default=str))

  sections.append('\n## Game Summary')
  sections.append(f"Role: {memory_dump.get('role', '?')}")
  sections.append(f"Result: {memory_dump.get('result', '?')}")
  sections.append(f"LLM calls: {memory_dump.get('llm_calls', '?')}")
  sections.append(f"Snapshots: {memory_dump.get('snapshots_processed', '?')}")

  if cross_game_memory.get('games_played', 0) > 0:
    sections.append('\n## Cross-Game Memory')
    sections.append(f"Games played: {cross_game_memory.get('games_played', 0)}")
    sections.append(f"Win rate: {cross_game_memory.get('win_rate', 0):.0%}")
    prev_edits = cross_game_memory.get('previous_edits', [])
    if prev_edits:
      sections.append('Previous edits:')
      for edit in prev_edits[-5:]:
        sections.append(f"  - Game {edit.get('game_id', '?')}: {edit.get('summary', '?')}")
    recurring = cross_game_memory.get('recurring_issues', [])
    if recurring:
      sections.append(f"Recurring issues: {', '.join(recurring[-5:])}")

  sections.append('\n## Current File Contents')
  for rel_path in EDITABLE_FILES:
    full_path = PROJECT_ROOT / rel_path
    if full_path.exists():
      content = full_path.read_text()
      sections.append(f'\n### {rel_path}')
      sections.append(f'```\n{content}\n```')
    else:
      sections.append(f'\n### {rel_path} (NOT FOUND)')

  sections.append('\n## Instructions')
  sections.append('Make 1-3 surgical edits using str_replace. Each edit must trace to a specific learning.')
  sections.append('After all edits, explain what you changed and why in a brief summary.')

  return '\n'.join(sections)


def _load_cross_game_memory() -> dict:
  """Load accumulated cross-game memory."""
  if CROSS_GAME_MEMORY_FILE.exists():
    try:
      with open(CROSS_GAME_MEMORY_FILE) as f:
        return json.load(f)
    except (json.JSONDecodeError, OSError):
      pass
  return {
    'games_played': 0,
    'wins': 0,
    'losses': 0,
    'win_rate': 0.0,
    'previous_edits': [],
    'recurring_issues': [],
  }


def _run_tool_use_mode(learnings: dict, memory_dump: dict, provider_spec: str) -> dict:
  """Primary evolution path: Bedrock converse with str_replace tool loop."""
  provider = create_evolution_provider(provider_spec)
  cross_game = _load_cross_game_memory()
  prompt = _build_evolution_prompt(learnings, memory_dump, cross_game)

  logger.info('Running tool-use evolution (%d chars prompt)', len(prompt))
  t0 = time.monotonic()

  edits_made = []

  def tool_executor(tc: ToolCall) -> ToolResult:
    if tc.name == 'str_replace':
      result = _execute_str_replace(tc)
      if not result.is_error:
        edits_made.append({
          'path': tc.input.get('path', ''),
          'old_str_preview': tc.input.get('old_str', '')[:80],
          'new_str_preview': tc.input.get('new_str', '')[:80],
        })
      return result
    return ToolResult(tool_use_id=tc.tool_use_id,
                      content=f'Unknown tool: {tc.name}', is_error=True)

  try:
    response: ToolLoopResponse = provider.complete_with_tools(
      system=EVOLUTION_SYSTEM_PROMPT,
      messages=[{'role': 'user', 'content': prompt}],
      tools=[STR_REPLACE_TOOL],
      tool_executor=tool_executor,
      max_tokens=8192,
      max_rounds=10,
    )
  except Exception as e:
    logger.error('Tool-use evolution failed: %s', e)
    return {'method': 'tool_use', 'success': False, 'error': str(e), 'edits': []}

  elapsed = time.monotonic() - t0
  logger.info('Tool-use evolution: %d edits in %.1fs (%d rounds)',
              len(edits_made), elapsed, response.rounds)

  return {
    'method': 'tool_use',
    'success': len(edits_made) > 0,
    'edits': edits_made,
    'summary': response.text,
    'rounds': response.rounds,
    'input_tokens': response.input_tokens,
    'output_tokens': response.output_tokens,
    'latency_ms': response.latency_ms,
  }


def _run_json_mode(learnings: dict, memory_dump: dict, provider_spec: str) -> dict:
  """Fallback #1: Ask for JSON edit instructions, apply them manually."""
  provider = create_evolution_provider(provider_spec)
  cross_game = _load_cross_game_memory()
  prompt = _build_evolution_prompt(learnings, memory_dump, cross_game)

  json_system = EVOLUTION_SYSTEM_PROMPT + """

Since tool use is not available, output your edits as a JSON array:
[
  {"path": "sidecar/brain.py", "old_str": "exact old text", "new_str": "exact new text"},
  ...
]
Output ONLY the JSON array, no other text."""

  logger.info('Running JSON-mode evolution fallback')
  try:
    response = provider.complete(
      system=json_system,
      messages=[{'role': 'user', 'content': prompt}],
      max_tokens=8192,
    )
  except Exception as e:
    logger.error('JSON-mode evolution failed: %s', e)
    return {'method': 'json_mode', 'success': False, 'error': str(e), 'edits': []}

  try:
    edits_raw = json.loads(response.text)
  except json.JSONDecodeError:
    start = response.text.find('[')
    end = response.text.rfind(']')
    if start >= 0 and end > start:
      try:
        edits_raw = json.loads(response.text[start:end + 1])
      except json.JSONDecodeError:
        return {'method': 'json_mode', 'success': False, 'error': 'JSON parse failed', 'edits': []}
    else:
      return {'method': 'json_mode', 'success': False, 'error': 'No JSON array found', 'edits': []}

  edits_made = []
  for edit in edits_raw:
    tc = ToolCall(
      tool_use_id=f'json_{len(edits_made)}',
      name='str_replace',
      input=edit,
    )
    result = _execute_str_replace(tc)
    if not result.is_error:
      edits_made.append({
        'path': edit.get('path', ''),
        'old_str_preview': edit.get('old_str', '')[:80],
        'new_str_preview': edit.get('new_str', '')[:80],
      })
    else:
      logger.warning('JSON-mode edit failed: %s', result.content)

  return {
    'method': 'json_mode',
    'success': len(edits_made) > 0,
    'edits': edits_made,
    'input_tokens': response.input_tokens,
    'output_tokens': response.output_tokens,
  }


def _run_opencode_fallback(learnings: dict, memory_dump: dict) -> dict:
  """Fallback #2: Shell out to OpenCode CLI for edits."""
  opencode_prompt_parts = [
    'You are editing an Among Them social deduction bot. Based on these post-game learnings, make 1-3 surgical edits.',
    '',
    '## Learnings',
    json.dumps(learnings, indent=2, default=str),
    '',
    f'## Game: role={memory_dump.get("role", "?")}, result={memory_dump.get("result", "?")}',
    '',
    '## Editable files (relative to project root):',
  ]
  for f in EDITABLE_FILES:
    full = PROJECT_ROOT / f
    if full.exists():
      opencode_prompt_parts.append(f'- {f}')

  cross_game = _load_cross_game_memory()
  if cross_game.get('games_played', 0) > 0:
    opencode_prompt_parts.append(f'\n## Cross-game context: {cross_game.get("games_played")} games, {cross_game.get("win_rate", 0):.0%} win rate')
    prev = cross_game.get('previous_edits', [])[-3:]
    if prev:
      opencode_prompt_parts.append('Recent edits: ' + '; '.join(e.get('summary', '?') for e in prev))

  opencode_prompt_parts.append('\nMake small, targeted improvements. Focus on the biggest_mistake and actionable_rules.')

  prompt = '\n'.join(opencode_prompt_parts)
  logger.info('Running OpenCode fallback')

  try:
    result = subprocess.run(
      ['opencode', '-m', 'amazon-bedrock/anthropic.claude-sonnet-4-6', '-p', prompt],
      capture_output=True, text=True, timeout=120, cwd=str(PROJECT_ROOT),
    )
    success = result.returncode == 0
    return {
      'method': 'opencode',
      'success': success,
      'stdout': result.stdout[-2000:] if result.stdout else '',
      'stderr': result.stderr[-500:] if result.stderr else '',
      'edits': [],
    }
  except FileNotFoundError:
    return {'method': 'opencode', 'success': False, 'error': 'opencode not found in PATH', 'edits': []}
  except subprocess.TimeoutExpired:
    return {'method': 'opencode', 'success': False, 'error': 'opencode timed out (120s)', 'edits': []}
  except Exception as e:
    return {'method': 'opencode', 'success': False, 'error': str(e), 'edits': []}


def _commit_and_track(game_id: str, summary: str, edits: list[dict]) -> dict:
  """Commit changes, push to evolution branch, create PR, auto-merge."""
  branch_name = f'evolution/{game_id}'
  commit_msg = f'bot-evolution: {game_id}\n\n{summary}'
  git_log = {}

  try:
    current_branch = subprocess.run(
      ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
      capture_output=True, text=True, cwd=str(PROJECT_ROOT),
    ).stdout.strip()
    git_log['original_branch'] = current_branch

    subprocess.run(
      ['git', 'checkout', '-b', branch_name],
      capture_output=True, text=True, cwd=str(PROJECT_ROOT),
    )

    for rel_path in EDITABLE_FILES:
      subprocess.run(
        ['git', 'add', rel_path],
        capture_output=True, text=True, cwd=str(PROJECT_ROOT),
      )

    result = subprocess.run(
      ['git', 'commit', '-m', commit_msg],
      capture_output=True, text=True, cwd=str(PROJECT_ROOT),
    )
    git_log['commit'] = result.returncode == 0
    git_log['commit_output'] = result.stdout[:500]

    result = subprocess.run(
      ['git', 'push', '-u', 'origin', branch_name],
      capture_output=True, text=True, cwd=str(PROJECT_ROOT),
    )
    git_log['push'] = result.returncode == 0

    if git_log.get('push'):
      result = subprocess.run(
        ['gh', 'pr', 'create', '--title', f'Bot Evolution: {game_id}',
         '--body', _build_pr_body(game_id, summary, edits),
         '--base', current_branch],
        capture_output=True, text=True, cwd=str(PROJECT_ROOT),
      )
      git_log['pr_created'] = result.returncode == 0
      git_log['pr_url'] = result.stdout.strip() if result.returncode == 0 else ''

      if git_log.get('pr_created') and git_log.get('pr_url'):
        result = subprocess.run(
          ['gh', 'pr', 'merge', git_log['pr_url'], '--auto', '--squash'],
          capture_output=True, text=True, cwd=str(PROJECT_ROOT),
        )
        git_log['auto_merge'] = result.returncode == 0

    subprocess.run(
      ['git', 'checkout', current_branch],
      capture_output=True, text=True, cwd=str(PROJECT_ROOT),
    )

  except Exception as e:
    git_log['error'] = str(e)
    logger.error('Git operations failed: %s', e)

  return git_log


def _build_pr_body(game_id: str, summary: str, edits: list[dict]) -> str:
  """Build a PR description from the evolution results."""
  lines = [
    '## Bot Evolution',
    '',
    f'**Game:** `{game_id}`',
    f'**Timestamp:** {datetime.utcnow().isoformat()}Z',
    '',
    '### Summary',
    summary or '(no summary)',
    '',
    '### Edits Made',
  ]
  for i, edit in enumerate(edits, 1):
    lines.append(f'{i}. `{edit.get("path", "?")}`: `{edit.get("old_str_preview", "?")}` -> `{edit.get("new_str_preview", "?")}`')

  lines.extend([
    '',
    '---',
    '*Auto-generated by the Among Them bot evolution pipeline.*',
  ])
  return '\n'.join(lines)


def _accumulate_cross_game_memory(game_id: str, result: str, role: str,
                                  learnings: dict, evolution_log: dict) -> None:
  """Update persistent cross-game memory with this game's results."""
  memory = _load_cross_game_memory()

  memory['games_played'] = memory.get('games_played', 0) + 1

  is_imposter = role == 'imposter'
  won = False
  if 'imposter_win' in result or 'IMPS WIN' in result:
    won = is_imposter
  elif 'crew_win' in result or 'CREW WINS' in result:
    won = not is_imposter

  if won:
    memory['wins'] = memory.get('wins', 0) + 1
  else:
    memory['losses'] = memory.get('losses', 0) + 1

  total = memory.get('wins', 0) + memory.get('losses', 0)
  memory['win_rate'] = memory.get('wins', 0) / total if total > 0 else 0.0

  edit_record = {
    'game_id': game_id,
    'timestamp': datetime.utcnow().isoformat(),
    'role': role,
    'result': result,
    'won': won,
    'method': evolution_log.get('method', '?'),
    'edits_count': len(evolution_log.get('edits', [])),
    'summary': evolution_log.get('summary', '')[:200],
  }
  memory.setdefault('previous_edits', []).append(edit_record)
  if len(memory['previous_edits']) > 50:
    memory['previous_edits'] = memory['previous_edits'][-50:]

  biggest_mistake = learnings.get('biggest_mistake', '')
  if biggest_mistake:
    memory.setdefault('recurring_issues', []).append(biggest_mistake[:100])
    if len(memory['recurring_issues']) > 20:
      memory['recurring_issues'] = memory['recurring_issues'][-20:]

  try:
    CROSS_GAME_MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(CROSS_GAME_MEMORY_FILE, 'w') as f:
      json.dump(memory, f, indent=2, default=str)
  except OSError as e:
    logger.error('Failed to save cross-game memory: %s', e)


def run_code_evolution(memory_dump_path: str | Path, learnings_path: str | Path,
                       provider_spec: str = 'bedrock') -> dict:
  """Main entry point: run the full evolution pipeline.

  1. Load memory dump and learnings
  2. Try tool-use mode (primary)
  3. Fall back to JSON mode, then OpenCode CLI
  4. Commit, push, PR, auto-merge
  5. Accumulate cross-game memory

  Returns evolution log dict.
  """
  memory_dump_path = Path(memory_dump_path)
  learnings_path = Path(learnings_path)

  try:
    with open(memory_dump_path) as f:
      memory_dump = json.load(f)
  except (OSError, json.JSONDecodeError) as e:
    logger.error('Failed to load memory dump: %s', e)
    return {'success': False, 'error': f'memory dump load failed: {e}'}

  try:
    with open(learnings_path) as f:
      learnings = json.load(f)
  except (OSError, json.JSONDecodeError) as e:
    logger.error('Failed to load learnings: %s', e)
    return {'success': False, 'error': f'learnings load failed: {e}'}

  game_id = memory_dump.get('game_id', 'unknown')
  role = memory_dump.get('role', 'unknown')
  result = memory_dump.get('result', 'unknown')

  logger.info('Starting code evolution for game %s (role=%s, result=%s)', game_id, role, result)

  evolution_log = _run_tool_use_mode(learnings, memory_dump, provider_spec)

  if not evolution_log.get('success'):
    logger.warning('Tool-use mode failed, trying JSON mode')
    evolution_log = _run_json_mode(learnings, memory_dump, provider_spec)

  if not evolution_log.get('success'):
    logger.warning('JSON mode failed, trying OpenCode fallback')
    evolution_log = _run_opencode_fallback(learnings, memory_dump)

  if evolution_log.get('success') and evolution_log.get('edits'):
    git_log = _commit_and_track(game_id,
                                evolution_log.get('summary', ''),
                                evolution_log.get('edits', []))
    evolution_log['git'] = git_log

  _accumulate_cross_game_memory(game_id, result, role, learnings, evolution_log)

  evolution_log['game_id'] = game_id
  evolution_log['role'] = role
  evolution_log['result'] = result

  try:
    log_path = memory_dump_path.parent / memory_dump_path.name.replace('_memory.json', '_evolution.json')
    with open(log_path, 'w') as f:
      json.dump(evolution_log, f, indent=2, default=str)
    logger.info('Evolution log saved to %s', log_path)
  except OSError as e:
    logger.warning('Failed to save evolution log: %s', e)

  return evolution_log


def run_evolution_manual(memory_dump_path: str, learnings_path: str,
                         provider_spec: str = 'bedrock') -> None:
  """CLI entry point for manual evolution runs."""
  import sys
  logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(name)s] %(levelname)s: %(message)s')

  result = run_code_evolution(memory_dump_path, learnings_path, provider_spec)
  print(json.dumps(result, indent=2, default=str))
  sys.exit(0 if result.get('success') else 1)


if __name__ == '__main__':
  import sys
  if len(sys.argv) < 3:
    print('Usage: python -m sidecar.code_evolution <memory_dump.json> <learnings.json> [provider_spec]')
    sys.exit(1)
  spec = sys.argv[3] if len(sys.argv) > 3 else 'bedrock'
  run_evolution_manual(sys.argv[1], sys.argv[2], spec)
