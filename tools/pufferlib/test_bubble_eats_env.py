from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bitworld_pufferlib import (
    ACTION_MASKS,
    BitWorldVecEnv,
    ENV_SPECS,
    FRAME_PIXELS,
    PACKED_FRAME_BYTES,
    parse_reward_payload,
    unpack_frame,
)


class ProtocolTest(unittest.TestCase):
    def test_unpack_frame(self) -> None:
        packed = np.arange(PACKED_FRAME_BYTES, dtype=np.uint8)
        frame = unpack_frame(packed.tobytes())

        self.assertEqual(frame.shape, (FRAME_PIXELS,))
        np.testing.assert_array_equal(frame[0::2], packed & 0x0F)
        np.testing.assert_array_equal(frame[1::2], packed >> 4)

    def test_parse_reward_stream_payload(self) -> None:
        parsed = parse_reward_payload("reward player1 42\n")

        self.assertEqual(parsed, 42)

    def test_parse_reward_stream_payload_by_player_name(self) -> None:
        payload = "reward player2 7\nreward player1 42\n"

        self.assertEqual(parse_reward_payload(payload, "player1"), 42)

    def test_parse_reward_stream_payload_requires_named_player(self) -> None:
        with self.assertRaises(ValueError):
            parse_reward_payload("reward player2 7\n", "player1")

    def test_action_space_matches_among_them_controls(self) -> None:
        allowed_buttons = 1 | 2 | 4 | 8 | 32 | 64

        self.assertEqual(len(ACTION_MASKS), 27)
        self.assertTrue(np.all((ACTION_MASKS.astype(np.int64) & ~allowed_buttons) == 0))


class BitWorldSmokeTest(unittest.TestCase):
    def test_env_reset_and_autoreset_across_envs(self) -> None:
        for env_name in sorted(ENV_SPECS):
            with self.subTest(env=env_name):
                env = BitWorldVecEnv(
                    env_name,
                    num_envs=1,
                    max_episode_steps=4,
                    frame_stack=4,
                    action_repeat=1,
                    base_seed=1234,
                )
                self.addCleanup(env.close)
                obs = env.reset()
                self.assertEqual(obs.shape, (1, FRAME_PIXELS * 4))
                terminals_seen = 0
                for _ in range(8):
                    _, rewards, terminals, _ = env.step_discrete(np.array([0], dtype=np.int64))
                    self.assertEqual(rewards.shape, (1,))
                    self.assertEqual(terminals.shape, (1,))
                    terminals_seen += int(terminals[0])
                self.assertGreaterEqual(terminals_seen, 2)

    def test_episode_return_matches_score_across_resets(self) -> None:
        for env_name in sorted(ENV_SPECS):
            with self.subTest(env=env_name):
                env = BitWorldVecEnv(
                    env_name,
                    num_envs=1,
                    max_episode_steps=16,
                    frame_stack=4,
                    action_repeat=1,
                    base_seed=123,
                )
                rng = np.random.default_rng(123)
                completed = []
                self.addCleanup(env.close)
                env.reset()
                while len(completed) < 3:
                    _, _, _, batch_completed = env.step_discrete(
                        rng.integers(0, env.action_count, size=(1,), dtype=np.int64)
                    )
                    completed.extend(batch_completed)

                self.assertEqual(len(completed), 3)
                for item in completed:
                    self.assertGreaterEqual(item.episode_return, 0.0)
                    self.assertAlmostEqual(item.score, item.episode_return)

    def test_default_action_repeat_multi_env_autoreset(self) -> None:
        env = BitWorldVecEnv("bubble_eats", num_envs=2, max_episode_steps=2, frame_stack=2, base_seed=777)
        self.addCleanup(env.close)
        obs = env.reset()
        self.assertEqual(obs.shape, (2, FRAME_PIXELS * 2))
        episodes = [worker.episode for worker in env.workers]

        env.step_discrete(np.zeros(2, dtype=np.int64))
        _, rewards, terminals, completed = env.step_discrete(np.zeros(2, dtype=np.int64))

        self.assertEqual(rewards.shape, (2,))
        np.testing.assert_array_equal(terminals, np.ones(2, dtype=np.float32))
        self.assertEqual(len(completed), 2)
        self.assertNotEqual(episodes, [worker.episode for worker in env.workers])


if __name__ == "__main__":
    unittest.main()
