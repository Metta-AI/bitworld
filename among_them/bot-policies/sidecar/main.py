"""Sidecar entry point — Unix socket server bridging Nim bot ↔ Python brain.

Protocol:
  - Nim sends newline-delimited JSON messages (snapshots, events, game_init, game_end)
  - Python replies with newline-delimited JSON directives

Run:
  python -m sidecar.main [--socket /tmp/smartbot.sock] [--provider anthropic] [--model claude-sonnet-4-20250514]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
from pathlib import Path

from .brain import Brain
from .learnings import dump_game, generate_game_id, synthesize_learnings

logging.basicConfig(
  level=logging.INFO,
  format='%(asctime)s [%(name)s] %(levelname)s: %(message)s',
)
logger = logging.getLogger('sidecar')

DEFAULT_SOCKET = '/tmp/smartbot.sock'


class SidecarServer:
  """Async Unix socket server that talks to one Nim bot."""

  def __init__(self, brain: Brain, socket_path: str):
    self.brain = brain
    self.socket_path = socket_path
    self._server: asyncio.AbstractServer | None = None

  async def handle_client(
    self,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
  ) -> None:
    logger.info('Nim client connected')
    try:
      while True:
        line = await reader.readline()
        if not line:
          break
        try:
          msg = json.loads(line.decode().strip())
        except json.JSONDecodeError:
          continue

        response = self._process_message(msg)
        if response is not None:
          writer.write((json.dumps(response) + '\n').encode())
          await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
      logger.info('Nim client disconnected')
    finally:
      writer.close()
      await writer.wait_closed()

  def _process_message(self, msg: dict) -> dict | None:
    msg_type = msg.get('type', '')

    if msg_type == 'game_init':
      game_id = msg.get('game_id', generate_game_id())
      role = msg.get('role', 'crewmate')
      self_color = msg.get('self_color', 0)
      min_players = msg.get('min_players', 8)
      imposter_count = msg.get('imposter_count', 2)
      tasks_per_player = msg.get('tasks_per_player', 6)

      self.brain.learnings_text = synthesize_learnings()
      self.brain.init_game(
        game_id=game_id,
        role=role,
        self_color=self_color,
        min_players=min_players,
        imposter_count=imposter_count,
        tasks_per_player=tasks_per_player,
      )
      logger.info('Game initialized: id=%s role=%s color=%d', game_id, role, self_color)
      return {'type': 'ack', 'status': 'game_initialized', 'game_id': game_id}

    elif msg_type == 'snapshot':
      directive = self.brain.process_snapshot(msg)
      if directive is not None:
        return directive.to_nim_json()
      return None

    elif msg_type == 'event':
      self.brain.process_event(msg)
      # re-check if event warrants a directive
      return None

    elif msg_type == 'game_end':
      game_dump = self.brain.get_game_dump()
      result = msg.get('result', 'unknown')
      game_dump['result'] = result
      path = dump_game(game_dump)
      logger.info('Game ended: result=%s dump=%s', result, path)
      return {'type': 'ack', 'status': 'game_ended', 'dump_path': str(path)}

    elif msg_type == 'ping':
      return {'type': 'pong'}

    else:
      logger.warning('Unknown message type: %s', msg_type)
      return None

  async def start(self) -> None:
    if os.path.exists(self.socket_path):
      os.unlink(self.socket_path)

    self._server = await asyncio.start_unix_server(
      self.handle_client,
      path=self.socket_path,
    )
    logger.info('Sidecar listening on %s', self.socket_path)

    async with self._server:
      await self._server.serve_forever()

  async def stop(self) -> None:
    if self._server:
      self._server.close()
      await self._server.wait_closed()
    if os.path.exists(self.socket_path):
      os.unlink(self.socket_path)


class SidecarTCPServer:
  """Async TCP server for cross-machine or simpler Nim integration."""

  def __init__(self, brain: Brain, host: str = '127.0.0.1', port: int = 9900):
    self.brain = brain
    self.host = host
    self.port = port
    self._unix = SidecarServer(brain, '')

  async def handle_client(
    self,
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
  ) -> None:
    await self._unix.handle_client(reader, writer)

  async def start(self) -> None:
    server = await asyncio.start_server(
      self.handle_client,
      self.host,
      self.port,
    )
    logger.info('Sidecar TCP listening on %s:%d', self.host, self.port)
    async with server:
      await server.serve_forever()


def main() -> None:
  parser = argparse.ArgumentParser(description='Among Them Smart Bot Sidecar')
  parser.add_argument('--socket', default=DEFAULT_SOCKET, help='Unix socket path')
  parser.add_argument('--tcp', action='store_true', help='Use TCP instead of Unix socket')
  parser.add_argument('--host', default='127.0.0.1', help='TCP host')
  parser.add_argument('--port', type=int, default=9900, help='TCP port')
  parser.add_argument('--provider', default='bedrock',
                      choices=['bedrock', 'anthropic', 'openrouter'],
                      help='LLM provider')
  parser.add_argument('--model', default='', help='LLM model name')
  args = parser.parse_args()

  brain = Brain(provider_spec=args.provider, model=args.model)

  if args.tcp:
    server = SidecarTCPServer(brain, args.host, args.port)
  else:
    server = SidecarServer(brain, args.socket)

  loop = asyncio.new_event_loop()

  def shutdown(sig, frame):
    logger.info('Shutting down...')
    loop.stop()

  signal.signal(signal.SIGINT, shutdown)
  signal.signal(signal.SIGTERM, shutdown)

  try:
    loop.run_until_complete(server.start())
  except KeyboardInterrupt:
    pass
  finally:
    loop.close()
    if not args.tcp and os.path.exists(args.socket):
      os.unlink(args.socket)


if __name__ == '__main__':
  main()
