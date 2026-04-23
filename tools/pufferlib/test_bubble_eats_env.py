from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bitworld_pufferlib import (
    BubbleEatsVecEnv,
    FRAME_PIXELS,
    RL_FRAME_BYTES,
    RL_HEADER_BYTES,
    RL_MAGIC,
    RL_VERSION,
    parse_rl_frame,
)


class ParsePacketTest(unittest.TestCase):
    def test_parse_rl_frame(self) -> None:
        frame = np.arange(FRAME_PIXELS, dtype=np.uint8)
        packet = bytearray(RL_FRAME_BYTES)
        packet[:2] = RL_MAGIC
        packet[2] = RL_VERSION
        packet[3] = 7
        struct.pack_into("<i", packet, 4, 123)
        packet[RL_HEADER_BYTES:] = frame.tobytes()

        parsed_frame, score, component = parse_rl_frame(bytes(packet))
        self.assertEqual(score, 123)
        self.assertEqual(component, 7)
        np.testing.assert_array_equal(parsed_frame, frame)


class BubbleEatsSmokeTest(unittest.TestCase):
    def test_env_reset_and_autoreset(self) -> None:
        env = BubbleEatsVecEnv(num_envs=1, max_episode_steps=4, frame_stack=4, fps=0.0, base_seed=1234)
        try:
            obs = env.reset()
            self.assertEqual(obs.shape, (1, FRAME_PIXELS * 4))
            terminals_seen = 0
            for _ in range(8):
                _, rewards, terminals, _ = env.step_discrete(np.array([0], dtype=np.int64))
                self.assertEqual(rewards.shape, (1,))
                self.assertEqual(terminals.shape, (1,))
                terminals_seen += int(terminals[0])
            self.assertGreaterEqual(terminals_seen, 2)
        finally:
            env.close()

    def test_episode_return_matches_score_across_resets(self) -> None:
        env = BubbleEatsVecEnv(num_envs=1, max_episode_steps=64, frame_stack=4, fps=0.0, base_seed=123)
        rng = np.random.default_rng(123)
        completed = []
        try:
            env.reset()
            while len(completed) < 6:
                _, _, _, batch_completed = env.step_discrete(
                    rng.integers(0, env.action_count, size=(1,), dtype=np.int64)
                )
                completed.extend(batch_completed)
        finally:
            env.close()

        self.assertEqual(len(completed), 6)
        for item in completed:
            self.assertGreaterEqual(item.episode_return, 0.0)
            self.assertAlmostEqual(item.score, item.episode_return)


if __name__ == "__main__":
    unittest.main()
