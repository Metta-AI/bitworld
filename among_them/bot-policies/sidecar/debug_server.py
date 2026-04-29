"""Debug WebSocket server for the smart bot debugger GUI.

Runs alongside the bot on a separate port (default 9090).
Broadcasts JSON events to all connected browser clients.
Port 9090 = WebSocket, port 9091 = HTTP serving debugger.html.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import time
from pathlib import Path

try:
  import websockets
  from websockets.asyncio.server import serve as ws_serve
except ImportError:
  websockets = None
  ws_serve = None

logger = logging.getLogger(__name__)

DEBUGGER_HTML_PATH = Path(__file__).parent / 'debugger.html'


class DebugServer:
  """Async WebSocket debug event broadcaster with embedded HTTP file server."""

  def __init__(self, port: int = 9090):
    self.ws_port = port
    self.http_port = port + 1
    self.clients: set = set()
    self._server = None
    self._http_server = None
    self._started = False

  async def start(self):
    if ws_serve is None:
      logger.warning('websockets not available — debug server disabled')
      return

    self._server = await ws_serve(self._handler, '0.0.0.0', self.ws_port)
    self._http_server = await asyncio.start_server(
      self._http_handler, '0.0.0.0', self.http_port,
    )
    self._started = True
    logger.info('Debug GUI:  http://localhost:%d', self.http_port)
    logger.info('Debug WS:   ws://localhost:%d', self.ws_port)

  async def _http_handler(self, reader: asyncio.StreamReader,
                          writer: asyncio.StreamWriter):
    """Minimal HTTP/1.1 handler — serves debugger.html for any GET request."""
    try:
      await reader.readline()
      while True:
        line = await reader.readline()
        if line in (b'\r\n', b'\n', b''):
          break

      if DEBUGGER_HTML_PATH.exists():
        body = DEBUGGER_HTML_PATH.read_bytes()
      else:
        body = b'<h1>debugger.html not found</h1>'

      header = (
        f'HTTP/1.1 200 OK\r\n'
        f'Content-Type: text/html; charset=utf-8\r\n'
        f'Content-Length: {len(body)}\r\n'
        f'Connection: close\r\n'
        f'\r\n'
      ).encode()
      writer.write(header + body)
      await writer.drain()
    except Exception:
      pass
    finally:
      writer.close()

  async def _handler(self, ws):
    self.clients.add(ws)
    logger.info('Debug client connected (%d total)', len(self.clients))
    try:
      async for _ in ws:
        pass
    finally:
      self.clients.discard(ws)
      logger.info('Debug client disconnected (%d total)', len(self.clients))

  def emit(self, event_type: str, data: dict):
    if not self.clients:
      return
    msg = json.dumps({
      'type': event_type,
      'ts': time.time(),
      **data,
    }, default=str)
    for ws in list(self.clients):
      try:
        asyncio.ensure_future(self._safe_send(ws, msg))
      except RuntimeError:
        pass

  async def _safe_send(self, ws, msg):
    try:
      await ws.send(msg)
    except Exception:
      self.clients.discard(ws)

  def emit_snapshot(self, bot):
    """Emit a per-frame snapshot event with full bot state."""
    frame_b64 = ''
    if bot.unpacked is not None:
      frame_b64 = base64.b64encode(bot.unpacked.tobytes()).decode('ascii')

    self.emit('snapshot', {
      'tick': bot.frame_tick,
      'frame': frame_b64,
      'camera_x': bot.camera_x,
      'camera_y': bot.camera_y,
      'player_x': bot.player_world_x(),
      'player_y': bot.player_world_y(),
      'room': bot.room_name(),
      'role': ['unknown', 'crewmate', 'imposter'][bot.role],
      'is_ghost': bot.is_ghost,
      'localized': bot.localized,
      'interstitial': bot.interstitial,
      'voting': bot.voting,
      'intent': bot.intent,
      'mask': bot.last_mask,
      'goal_name': bot.goal_name,
      'goal_x': bot.goal_x,
      'goal_y': bot.goal_y,
      'has_goal': bot.has_goal,
      'velocity_x': bot.velocity_x,
      'velocity_y': bot.velocity_y,
      'stuck_frames': bot.stuck_frames,
      'self_color': bot.self_color_index,
      'kill_ready': bot.imposter_kill_ready,
      'task_hold_ticks': bot.task_hold_ticks,
      'visible_players': [
        {'x': cm.x, 'y': cm.y, 'color': cm.color_index}
        for cm in bot.visible_crewmates
      ],
      'visible_bodies': [
        {'x': b.x, 'y': b.y}
        for b in bot.visible_bodies
      ],
    })

  def emit_trigger(self, trigger, tick: int):
    self.emit('trigger', {
      'tick': tick,
      'trigger_type': trigger.type.value,
      'priority': trigger.priority,
      'data': trigger.data,
    })

  def emit_llm_request(self, trigger_type: str, context: str,
                       conversation_len: int, tick: int):
    self.emit('llm_request', {
      'tick': tick,
      'trigger_type': trigger_type,
      'context': context,
      'conversation_len': conversation_len,
    })

  def emit_llm_response(self, trigger_type: str, response_text: str,
                        elapsed_ms: int, input_tokens: int,
                        output_tokens: int, tick: int):
    self.emit('llm_response', {
      'tick': tick,
      'trigger_type': trigger_type,
      'response': response_text,
      'elapsed_ms': elapsed_ms,
      'input_tokens': input_tokens,
      'output_tokens': output_tokens,
    })

  def emit_directive(self, directive, tick: int):
    self.emit('directive', {
      'tick': tick,
      'strategy': directive.strategy,
      'target_player': directive.target_player,
      'target_room': directive.target_room,
      'vote_target': directive.vote_target,
      'chat_message': directive.chat_message,
      'navigate_to': list(directive.navigate_to) if directive.navigate_to else None,
      'reasoning': directive.reasoning,
      'hold': directive.hold,
      'until': directive.until,
      'expires_tick': directive.expires_tick,
      'created_tick': directive.created_tick,
    })

  def emit_player_model(self, model, tick: int):
    from .memory import PLAYER_COLOR_NAMES

    players = {}
    for color, info in model.players.items():
      name = PLAYER_COLOR_NAMES[color] if color < len(PLAYER_COLOR_NAMES) else f'c{color}'
      players[name] = {
        'color': color,
        'status': info.status,
        'suspicion': round(info.suspicion, 4),
        'last_room': info.last_room,
        'last_seen_tick': info.last_seen_tick,
        'times_accused': info.times_accused,
        'alibi': info.alibi,
      }
    self.emit('player_model', {'tick': tick, 'players': players})

  def emit_memory(self, memory, tick: int):
    episodic = [
      {'tick': e.tick, 'hall': e.hall.value, 'text': e.text,
       'landmark': e.landmark}
      for e in list(memory.episodic.events)[-30:]
    ]
    strategic = memory.strategic.snapshot()
    self.emit('memory', {
      'tick': tick,
      'game_id': memory.game_id,
      'role': memory.role,
      'episodic': episodic,
      'strategic': strategic,
    })

  def emit_status(self, bot, brain=None):
    data = {
      'tick': bot.frame_tick,
      'phase': 'voting' if bot.voting else ('interstitial' if bot.interstitial else 'playing'),
      'role': ['unknown', 'crewmate', 'imposter'][bot.role],
      'is_ghost': bot.is_ghost,
      'localized': bot.localized,
    }
    if brain is not None:
      data['llm_calls'] = brain.advisor.call_count
      data['llm_budget'] = brain.advisor.call_budget
      data['snapshots_processed'] = brain._snapshot_count
      data['game_id'] = brain.memory.game_id
    self.emit('status', data)
