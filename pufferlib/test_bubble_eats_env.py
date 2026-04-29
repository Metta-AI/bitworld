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
    AMONG_THEM_MAX_PLAYERS,
    BitWorldPolicy,
    BitWorldVecEnv,
    ENV_SPECS,
    EpisodeStats,
    FRAME_PIXELS,
    PACKED_FRAME_BYTES,
    SCREEN_WIDTH,
    STATE_BODY_FEATURE_OFFSET,
    STATE_FLAG_PLAYER_ROLE_IMPOSTER,
    STATE_FLAG_TASK_COMPLETED,
    STATE_FEATURES,
    STATE_GRID_SIZE,
    STATE_HEADER_FEATURES,
    STATE_PLAYER_FEATURE_OFFSET,
    STATE_PLAYER_FEATURES,
    STATE_TASK_COUNT,
    STATE_TASK_FEATURE_OFFSET,
    STATE_TASK_FEATURES,
    env_log_key,
    load_policy_checkpoint,
    parse_reward_payload,
    unpack_frame,
    with_server_players,
)

# Default role reveal lasts 120 native ticks; this reaches one playing tick.
AMONG_THEM_PLAY_ACTION_REPEAT = 121


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

    def test_episode_stats_emit_namespaced_info(self) -> None:
        stats = EpisodeStats(score=3.0, length=4, episode_return=5.0, tasks_completed=2.0)

        self.assertEqual(
            stats.info("task_progress"),
            {
                "game": {"score": 3.0, "tasks_completed": 2.0, "task_progress": 3.0},
                "episode": {"length": 4.0, "return": 5.0},
            },
        )
        self.assertEqual(env_log_key("game/task_progress"), "env_game/task_progress")

    def test_policy_checkpoint_loads_state_dict(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "policy.pt"
            policy = BitWorldPolicy(frame_stack=3, action_count=len(ACTION_MASKS), hidden_size=48)
            torch.save(policy.state_dict(), path)

            loaded = load_policy_checkpoint(path)

            self.assertEqual(loaded.frame_stack, 3)
            self.assertEqual(loaded.hidden_size, 48)
            self.assertEqual(loaded.action_count, len(ACTION_MASKS))

    def test_pixel_policy_accepts_flat_observations(self) -> None:
        policy = BitWorldPolicy(frame_stack=2, action_count=len(ACTION_MASKS), hidden_size=32)
        observations = torch.zeros(4, FRAME_PIXELS * 2)

        logits, values = policy.forward_eval(observations)

        self.assertEqual(logits.shape, (4, len(ACTION_MASKS)))
        self.assertEqual(values.shape, (4, 1))


class BitWorldSmokeTest(unittest.TestCase):
    def test_env_reset_and_autoreset_across_envs(self) -> None:
        for env_name in sorted(ENV_SPECS):
            with self.subTest(env=env_name):
                is_among_them = env_name == "among_them"
                env = BitWorldVecEnv(
                    env_name,
                    num_envs=1,
                    max_episode_steps=1 if is_among_them else 4,
                    frame_stack=4,
                    action_repeat=AMONG_THEM_PLAY_ACTION_REPEAT if is_among_them else 1,
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
        env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=1,
            frame_stack=2,
            action_repeat=AMONG_THEM_PLAY_ACTION_REPEAT,
            base_seed=99,
        )
        self.addCleanup(env.close)

        obs = env.reset()
        self.assertEqual(env.total_agents, ENV_SPECS["among_them"].server_players)
        self.assertEqual(obs.shape, (env.total_agents, FRAME_PIXELS * 2))

        _, rewards, terminals, _ = env.step_discrete(np.zeros(env.total_agents, dtype=np.int64))
        self.assertEqual(rewards.shape, (env.total_agents,))
        self.assertEqual(terminals.shape, (env.total_agents,))
        np.testing.assert_array_equal(terminals, np.zeros(env.total_agents, dtype=np.float32))
        np.testing.assert_array_equal(env._truncations, np.zeros(env.total_agents, dtype=np.float32))

        _, rewards, terminals, completed = env.step_discrete(np.zeros(env.total_agents, dtype=np.int64))
        self.assertEqual(rewards.shape, (env.total_agents,))
        np.testing.assert_array_equal(terminals, np.ones(env.total_agents, dtype=np.float32))
        np.testing.assert_array_equal(env._truncations, np.ones(env.total_agents, dtype=np.float32))
        self.assertEqual(len(completed), env.total_agents)
        self.assertEqual(max(item.score for item in completed), 100.0)

    def test_among_them_state_observations_do_not_leak_hidden_roles(self) -> None:
        env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=2,
            frame_stack=1,
            action_repeat=1,
            base_seed=99,
            observation_mode="state",
        )
        self.addCleanup(env.close)

        obs = env.reset()
        self.assertEqual(obs.shape, (env.total_agents, STATE_FEATURES))
        self.assertEqual(obs.dtype, np.uint8)

        for viewer_index in range(env.total_agents):
            for other_index in range(env.total_agents):
                if other_index == viewer_index:
                    continue
                flags_feature = STATE_PLAYER_FEATURE_OFFSET + other_index * STATE_PLAYER_FEATURES + 4
                cooldown_feature = STATE_PLAYER_FEATURE_OFFSET + other_index * STATE_PLAYER_FEATURES + 7
                self.assertEqual(int(obs[viewer_index, flags_feature]) & STATE_FLAG_PLAYER_ROLE_IMPOSTER, 0)
                self.assertEqual(obs[viewer_index, cooldown_feature], 0)

    def test_among_them_state_grid_matches_rendered_pixels(self) -> None:
        state_env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=8,
            frame_stack=1,
            action_repeat=AMONG_THEM_PLAY_ACTION_REPEAT,
            base_seed=101,
            observation_mode="state",
        )
        pixel_env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=8,
            frame_stack=1,
            action_repeat=AMONG_THEM_PLAY_ACTION_REPEAT,
            base_seed=101,
            observation_mode="pixels",
        )
        self.addCleanup(state_env.close)
        self.addCleanup(pixel_env.close)

        state_env.reset()
        pixel_env.reset()
        actions = np.zeros((state_env.total_agents,), dtype=np.int64)
        state_obs, _, _, _ = state_env.step_discrete(actions)
        pixel_obs, _, _, _ = pixel_env.step_discrete(actions)

        step = SCREEN_WIDTH // STATE_GRID_SIZE
        sample_indices = np.asarray(
            [
                (gy * step + step // 2) * SCREEN_WIDTH + (gx * step + step // 2)
                for gy in range(STATE_GRID_SIZE)
                for gx in range(STATE_GRID_SIZE)
            ],
            dtype=np.int64,
        )
        grid_end = STATE_HEADER_FEATURES + STATE_GRID_SIZE * STATE_GRID_SIZE
        state_grid = state_obs[:, STATE_HEADER_FEATURES:grid_end]
        rendered_grid = pixel_obs[:, sample_indices]
        np.testing.assert_array_equal(state_grid, rendered_grid)
        self.assertLessEqual(int(state_grid.max()), 15)

    def test_among_them_state_observations_hide_non_rendered_fields(self) -> None:
        env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=8,
            frame_stack=1,
            action_repeat=AMONG_THEM_PLAY_ACTION_REPEAT,
            base_seed=102,
            observation_mode="state",
        )
        self.addCleanup(env.close)

        env.reset()
        obs, _, _, _ = env.step_discrete(np.zeros((env.total_agents,), dtype=np.int64))

        hidden_header_indices = np.asarray([1, 2, 7, 8, 11, 12, 15, 19, 21], dtype=np.int64)
        np.testing.assert_array_equal(obs[:, hidden_header_indices], 0)

        player_features = obs[:, STATE_PLAYER_FEATURE_OFFSET:STATE_BODY_FEATURE_OFFSET].reshape(
            env.total_agents,
            AMONG_THEM_MAX_PLAYERS,
            STATE_PLAYER_FEATURES,
        )
        np.testing.assert_array_equal(player_features[:, :, 5:7], 0)
        self.assertTrue(np.all(np.isin(player_features[:, :, 7], [0, 1, 255])))

        task_features = obs[:, STATE_TASK_FEATURE_OFFSET:STATE_FEATURES].reshape(
            env.total_agents,
            STATE_TASK_COUNT,
            STATE_TASK_FEATURES,
        )
        np.testing.assert_array_equal(task_features[:, :, 7], 0)
        self.assertTrue(np.all((task_features[:, :, 3] & STATE_FLAG_TASK_COMPLETED) == 0))

    def test_among_them_state_observations_cover_max_players(self) -> None:
        spec = with_server_players("among_them", AMONG_THEM_MAX_PLAYERS)
        env = BitWorldVecEnv(
            spec,
            num_envs=1,
            max_episode_steps=2,
            frame_stack=1,
            action_repeat=1,
            base_seed=100,
            observation_mode="state",
        )
        self.addCleanup(env.close)

        obs = env.reset()
        self.assertEqual(env.total_agents, AMONG_THEM_MAX_PLAYERS)
        self.assertEqual(obs.shape, (AMONG_THEM_MAX_PLAYERS, STATE_FEATURES))

    def test_among_them_rejects_more_than_max_players(self) -> None:
        with self.assertRaises(ValueError):
            with_server_players("among_them", AMONG_THEM_MAX_PLAYERS + 1)


if __name__ == "__main__":
    unittest.main()
