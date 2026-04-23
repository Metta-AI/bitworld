# Bit World PufferLib 4.0

This directory wires `Bubble Eats` into the PufferLib 4.0 torch backend without depending on PufferLib's compiled C env stack.

Why this shape:

- Bit World already runs as a fast Nim websocket game server.
- The public `4.0` branch still exposes `torch_pufferl.PuffeRL`, `muon`, and the PPO/V-trace trainer code we want.
- The generic Python `vector` / `emulation` helpers referenced in examples aren't shipped in the installed package, and `_C` is only required for the compiled env path.
- For Bit World, the cleanest integration is a custom Python vecenv plus a tiny runtime `_C` shim, while keeping the actual trainer on upstream PufferLib 4.0.

## What This Supports

- `Bubble Eats` RL websocket mode at `ws://127.0.0.1:<port>/rl`
- one-player-per-server training workers
- true score-based reward from the server, not HUD OCR
- fast reset via a single-byte reset command
- uncapped training mode with `--fps:0`
- stacked 64x64 palette-index observations
- direct training with `pufferlib.torch_pufferl.PuffeRL`

## Setup

Use Python 3.12 or newer. On this machine, Python 3.12 is the safest choice.

```bash
python3.12 -m venv .venv-puffer
source .venv-puffer/bin/activate
pip install -r tools/pufferlib/requirements.txt
```

## Smoke Test

```bash
source .venv-puffer/bin/activate
python -m unittest tools/pufferlib/test_bubble_eats_env.py
```

## Train

```bash
source .venv-puffer/bin/activate
python tools/pufferlib/train_bubble_eats.py \
  --total-timesteps 50000 \
  --num-envs 8 \
  --episode-steps 64 \
  --horizon 64 \
  --minibatch-size 512 \
  --fps 0
```

Outputs land under `tools/runlogs/pufferlib_training/`.

The training script saves:

- `bubble_eats_policy.pt`
- `train_metrics.json`
- `eval_summary.json`

Validated result on April 23, 2026 with the command above:

- trained policy: `mean_score = 1.18` over 100 held-out episodes
- random baseline: `mean_score = 0.38` over 100 held-out episodes

## Notes

- The Nim server now supports `--rl`, `--fps:<float>`, and `--seed:<int>`.
- RL mode sends unpacked `64 x 64` palette-index frames plus score metadata.
- RL mode steps synchronously per action/reset message so reward accounting stays aligned across episode resets.
- The current integration is intentionally scoped to `Bubble Eats` because it has dense reward and is the easiest Bit World slice to validate with end-to-end learning.
