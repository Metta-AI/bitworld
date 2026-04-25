from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bitworld_pufferlib import (
    BitWorldVecEnv,
    ENV_SPECS,
    FRAME_PIXELS,
    PACKED_FRAME_BYTES,
    REPO_ROOT,
    SHARED_NIM_SOURCES,
    parse_reward_payload,
    unpack_frame,
)

INTEGER_ONLY_NIM_PATTERNS = (
    ("floating type/coercion", re.compile(r"\bfloat(?:32|64)?\b|\.float(?:32|64)?\b|parseFloat")),
    ("decimal numeric literal", re.compile(r"(?<![\w.])\d+\.\d+(?![\w.])|\d+'f\b")),
    ("floating math helper", re.compile(r"\b(?:sqrt|round|sin|cos|tan)\s*\(")),
)


def strip_nim_literals(line: str) -> str:
    code: list[str] = []
    index = 0
    while index < len(line):
        char = line[index]
        if char == "#":
            break
        if char == '"':
            code.append(" ")
            index += 1
            while index < len(line):
                if line[index] == "\\":
                    index += 2
                    continue
                if line[index] == '"':
                    index += 1
                    break
                index += 1
            continue
        if char == "'" and index > 0 and line[index - 1].isdigit():
            code.append(char)
            index += 1
            continue
        if char == "'":
            code.append(" ")
            index += 1
            while index < len(line) and line[index] != "'":
                index += 1
            index += 1
            continue
        code.append(char)
        index += 1
    return "".join(code)


class SourcePolicyTest(unittest.TestCase):
    def test_training_nim_sources_stay_integer_only(self) -> None:
        paths = sorted({spec.source for spec in ENV_SPECS.values()} | set(SHARED_NIM_SOURCES))
        violations = []

        for path in paths:
            for line_number, line in enumerate(path.read_text().splitlines(), start=1):
                code = strip_nim_literals(line)
                for label, pattern in INTEGER_ONLY_NIM_PATTERNS:
                    if pattern.search(code):
                        relpath = path.relative_to(REPO_ROOT)
                        violations.append(f"{relpath}:{line_number}: {label}: {line.strip()}")

        self.assertEqual([], violations)


class ProtocolTest(unittest.TestCase):
    def test_unpack_frame(self) -> None:
        packed = np.arange(PACKED_FRAME_BYTES, dtype=np.uint8)
        frame = unpack_frame(packed.tobytes())

        self.assertEqual(frame.shape, (FRAME_PIXELS,))
        np.testing.assert_array_equal(frame[0::2], packed & 0x0F)
        np.testing.assert_array_equal(frame[1::2], packed >> 4)

    def test_parse_reward_payload(self) -> None:
        parsed = parse_reward_payload(b'{"score": 123, "auxValue": 7, "episode": 3, "connected": true}')

        self.assertEqual(parsed.score, 123)
        self.assertEqual(parsed.aux_value, 7)
        self.assertEqual(parsed.episode, 3)
        self.assertTrue(parsed.connected)


class BitWorldSmokeTest(unittest.TestCase):
    def test_env_reset_and_autoreset_across_envs(self) -> None:
        for env_name in sorted(ENV_SPECS):
            with self.subTest(env=env_name):
                env = BitWorldVecEnv(
                    env_name,
                    num_envs=1,
                    max_episode_steps=4,
                    frame_stack=4,
                    fps=0,
                    action_repeat=1,
                    base_seed=1234,
                )
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
        for env_name in sorted(ENV_SPECS):
            with self.subTest(env=env_name):
                env = BitWorldVecEnv(
                    env_name,
                    num_envs=1,
                    max_episode_steps=16,
                    frame_stack=4,
                    fps=0,
                    action_repeat=1,
                    base_seed=123,
                )
                rng = np.random.default_rng(123)
                completed = []
                try:
                    env.reset()
                    while len(completed) < 3:
                        _, _, _, batch_completed = env.step_discrete(
                            rng.integers(0, env.action_count, size=(1,), dtype=np.int64)
                        )
                        completed.extend(batch_completed)
                finally:
                    env.close()

                self.assertEqual(len(completed), 3)
                for item in completed:
                    self.assertGreaterEqual(item.episode_return, 0.0)
                    self.assertAlmostEqual(item.score, item.episode_return)

    def test_default_action_repeat_multi_env_autoreset(self) -> None:
        env = BitWorldVecEnv("bubble_eats", num_envs=2, max_episode_steps=2, frame_stack=2, fps=0, base_seed=777)
        try:
            obs = env.reset()
            self.assertEqual(obs.shape, (2, FRAME_PIXELS * 2))
            episodes = [worker.episode for worker in env.workers]

            env.step_discrete(np.zeros(2, dtype=np.int64))
            _, rewards, terminals, completed = env.step_discrete(np.zeros(2, dtype=np.int64))

            self.assertEqual(rewards.shape, (2,))
            np.testing.assert_array_equal(terminals, np.ones(2, dtype=np.float32))
            self.assertEqual(len(completed), 2)
            self.assertNotEqual(episodes, [worker.episode for worker in env.workers])
        finally:
            env.close()


if __name__ == "__main__":
    unittest.main()
