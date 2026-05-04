from __future__ import annotations

import sys
import tempfile
import unittest
import ctypes
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
    PLAYER2_BODY_FEATURE_OFFSET,
    PLAYER2_FLAG_PLAYER_ROLE_IMPOSTER,
    PLAYER2_FLAG_TASK_ARROW_VISIBLE,
    PLAYER2_FLAG_TASK_ICON_VISIBLE,
    PLAYER2_FEATURES,
    PLAYER2_GRID_SIZE,
    PLAYER2_HEADER_FEATURES,
    PLAYER2_PLAYER_FEATURE_OFFSET,
    PLAYER2_PLAYER_FEATURES,
    PLAYER2_TASK_COUNT,
    PLAYER2_TASK_FEATURE_OFFSET,
    PLAYER2_TASK_FEATURES,
    Player2ObservationAdapter,
    among_them_native_library,
    env_log_key,
    load_policy_checkpoint,
    parse_reward_payload,
    unpack_frame,
    with_server_players,
)

# Default role reveal lasts 120 native ticks; this reaches one playing tick.
AMONG_THEM_PLAY_ACTION_REPEAT = 121
PLAYER2_PARITY_PACKET_CAPACITY = 8 * 1024 * 1024


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

        completed = []
        for _ in range(8):
            _, rewards, terminals, completed = env.step_discrete(np.zeros(env.total_agents, dtype=np.int64))
            self.assertEqual(rewards.shape, (env.total_agents,))
            self.assertEqual(terminals.shape, (env.total_agents,))
            if completed:
                break
            np.testing.assert_array_equal(terminals, np.zeros(env.total_agents, dtype=np.float32))
            np.testing.assert_array_equal(env._truncations, np.zeros(env.total_agents, dtype=np.float32))

        self.assertTrue(completed)
        np.testing.assert_array_equal(terminals, np.ones(env.total_agents, dtype=np.float32))
        np.testing.assert_array_equal(env._truncations, np.ones(env.total_agents, dtype=np.float32))
        self.assertEqual(len(completed), env.total_agents)
        self.assertEqual(max(item.score for item in completed), 0.0)

    def test_among_them_player2_observations_do_not_leak_hidden_roles(self) -> None:
        env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=2,
            frame_stack=1,
            action_repeat=1,
            base_seed=99,
            observation_mode="player2",
        )
        self.addCleanup(env.close)

        obs = env.reset()
        self.assertEqual(obs.shape, (env.total_agents, PLAYER2_FEATURES))
        self.assertEqual(obs.dtype, np.uint8)

        for viewer_index in range(env.total_agents):
            for other_index in range(env.total_agents):
                if other_index == viewer_index:
                    continue
                flags_feature = PLAYER2_PLAYER_FEATURE_OFFSET + other_index * PLAYER2_PLAYER_FEATURES + 3
                self.assertEqual(int(obs[viewer_index, flags_feature]) & PLAYER2_FLAG_PLAYER_ROLE_IMPOSTER, 0)

    def test_among_them_player2_grid_uses_pixel_palette(self) -> None:
        env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=8,
            frame_stack=1,
            action_repeat=AMONG_THEM_PLAY_ACTION_REPEAT,
            base_seed=101,
            observation_mode="player2",
        )
        self.addCleanup(env.close)

        env.reset()
        player2_obs, _, _, _ = env.step_discrete(np.zeros((env.total_agents,), dtype=np.int64))

        grid_end = PLAYER2_HEADER_FEATURES + PLAYER2_GRID_SIZE * PLAYER2_GRID_SIZE
        player2_grid = player2_obs[:, PLAYER2_HEADER_FEATURES:grid_end]
        self.assertEqual(player2_grid.shape, (env.total_agents, PLAYER2_GRID_SIZE * PLAYER2_GRID_SIZE))
        self.assertLessEqual(int(player2_grid.max()), 15)

    def test_among_them_player2_observations_hide_non_rendered_fields(self) -> None:
        env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=8,
            frame_stack=1,
            action_repeat=AMONG_THEM_PLAY_ACTION_REPEAT,
            base_seed=102,
            observation_mode="player2",
        )
        self.addCleanup(env.close)

        env.reset()
        obs, _, _, _ = env.step_discrete(np.zeros((env.total_agents,), dtype=np.int64))

        self.assertEqual(PLAYER2_HEADER_FEATURES, 4)
        self.assertEqual(PLAYER2_PLAYER_FEATURES, 4)
        self.assertEqual(PLAYER2_TASK_FEATURES, 5)

        player_features = obs[:, PLAYER2_PLAYER_FEATURE_OFFSET:PLAYER2_BODY_FEATURE_OFFSET].reshape(
            env.total_agents,
            AMONG_THEM_MAX_PLAYERS,
            PLAYER2_PLAYER_FEATURES,
        )
        player_flags = player_features[:, :, 3]
        player_flag_mask = 1 | 4 | 16 | 32
        self.assertTrue(np.all((player_flags.astype(np.int64) & ~player_flag_mask) == 0))

        task_features = obs[:, PLAYER2_TASK_FEATURE_OFFSET:PLAYER2_FEATURES].reshape(
            env.total_agents,
            PLAYER2_TASK_COUNT,
            PLAYER2_TASK_FEATURES,
        )
        task_flags = task_features[:, :, 4]
        visible_task_mask = PLAYER2_FLAG_TASK_ICON_VISIBLE | PLAYER2_FLAG_TASK_ARROW_VISIBLE
        self.assertTrue(np.all((task_flags.astype(np.int64) & ~visible_task_mask) == 0))

    def test_among_them_player2_observations_cover_max_players(self) -> None:
        spec = with_server_players("among_them", AMONG_THEM_MAX_PLAYERS)
        env = BitWorldVecEnv(
            spec,
            num_envs=1,
            max_episode_steps=2,
            frame_stack=1,
            action_repeat=1,
            base_seed=100,
            observation_mode="player2",
        )
        self.addCleanup(env.close)

        obs = env.reset()
        self.assertEqual(env.total_agents, AMONG_THEM_MAX_PLAYERS)
        self.assertEqual(obs.shape, (AMONG_THEM_MAX_PLAYERS, PLAYER2_FEATURES))

    def test_among_them_player2_observations_match_player2_endpoint_packets(self) -> None:
        env = BitWorldVecEnv(
            "among_them",
            num_envs=1,
            max_episode_steps=32,
            frame_stack=1,
            action_repeat=1,
            base_seed=73,
            observation_mode="player2",
        )
        self.addCleanup(env.close)
        native = among_them_native_library()
        handle = int(env._player2_handles[0])
        packet_buffer = np.zeros((PLAYER2_PARITY_PACKET_CAPACITY,), dtype=np.uint8)
        packet_ptr = packet_buffer.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))
        adapters = [Player2ObservationAdapter() for _ in range(env.total_agents)]

        def endpoint_observation(player_index: int) -> np.ndarray:
            packet_len = native.check(
                native.lib.bitworld_at_player2_packet(
                    handle,
                    player_index,
                    packet_ptr,
                    PLAYER2_PARITY_PACKET_CAPACITY,
                )
            )
            self.assertGreater(packet_len, 0)
            adapters[player_index].apply_packet(bytes(packet_buffer[:packet_len]))
            return adapters[player_index].observation()

        def assert_parity(observations: np.ndarray, label: str) -> None:
            for player_index in range(env.total_agents):
                endpoint_obs = endpoint_observation(player_index)
                try:
                    np.testing.assert_array_equal(endpoint_obs, observations[player_index])
                except AssertionError as exc:
                    diff = np.flatnonzero(endpoint_obs != observations[player_index])
                    first = int(diff[0]) if diff.size else -1
                    self.fail(
                        f"{label} player={player_index} first_diff={first} "
                        f"endpoint={int(endpoint_obs[first]) if first >= 0 else 'n/a'} "
                        f"native={int(observations[player_index, first]) if first >= 0 else 'n/a'}: {exc}"
                    )

        rng = np.random.default_rng(123)
        observations = env.reset().copy()
        assert_parity(observations, "reset")
        for step in range(1, 520):
            actions = rng.integers(0, env.action_count, size=env.total_agents, dtype=np.int64)
            observations, _, _, _ = env.step_discrete(actions)
            assert_parity(observations.copy(), f"step {step}")

    def test_among_them_rejects_more_than_max_players(self) -> None:
        with self.assertRaises(ValueError):
            with_server_players("among_them", AMONG_THEM_MAX_PLAYERS + 1)


if __name__ == "__main__":
    unittest.main()
