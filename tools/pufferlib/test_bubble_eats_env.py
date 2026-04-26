from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bitworld_pufferlib import (
    ACTION_MASKS,
    BitWorldPolicy,
    BitWorldVecEnv,
    ENV_SPECS,
    FRAME_PIXELS,
    PACKED_FRAME_BYTES,
    load_policy_checkpoint,
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

    def test_policy_checkpoint_loads_state_dict(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "policy.pt"
            policy = BitWorldPolicy(frame_stack=3, action_count=len(ACTION_MASKS), hidden_size=48)
            torch.save(policy.state_dict(), path)

            loaded = load_policy_checkpoint(path)

            self.assertEqual(loaded.frame_stack, 3)
            self.assertEqual(loaded.hidden_size, 48)
            self.assertEqual(loaded.action_count, len(ACTION_MASKS))


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
                expected_agents = ENV_SPECS[env_name].server_players if env_name == "among_them" else 1
                self.addCleanup(env.close)
                obs = env.reset()
                self.assertEqual(obs.shape, (expected_agents, FRAME_PIXELS * 4))
                terminals_seen = 0
                for _ in range(8):
                    _, rewards, terminals, _ = env.step_discrete(np.zeros(env.total_agents, dtype=np.int64))
                    self.assertEqual(rewards.shape, (expected_agents,))
                    self.assertEqual(terminals.shape, (expected_agents,))
                    terminals_seen += int(terminals.sum())
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
                        rng.integers(0, env.action_count, size=(env.total_agents,), dtype=np.int64)
                    )
                    completed.extend(batch_completed)

                self.assertGreaterEqual(len(completed), 3)
                for item in completed:
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

    def test_among_them_direct_env_controls_all_players(self) -> None:
        env = BitWorldVecEnv("among_them", num_envs=1, max_episode_steps=2, frame_stack=2, action_repeat=1, base_seed=99)
        self.addCleanup(env.close)

        obs = env.reset()
        self.assertEqual(env.total_agents, ENV_SPECS["among_them"].server_players)
        self.assertEqual(obs.shape, (env.total_agents, FRAME_PIXELS * 2))

        _, rewards, terminals, _ = env.step_discrete(np.zeros(env.total_agents, dtype=np.int64))
        self.assertEqual(rewards.shape, (env.total_agents,))
        self.assertEqual(terminals.shape, (env.total_agents,))


if __name__ == "__main__":
    unittest.main()
