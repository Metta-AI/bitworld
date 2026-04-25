# Bit World PufferLib 4.0

This directory wires BitWorld's Nim websocket games into the PufferLib 4.0 torch backend without depending on PufferLib's compiled C env stack.

Why this shape:

- Bit World already runs as a fast Nim websocket game server.
- The public `4.0` branch still exposes `torch_pufferl.PuffeRL`, `muon`, and the PPO/V-trace trainer code we want.
- The generic Python `vector` / `emulation` helpers referenced in examples aren't shipped in the installed package, and `_C` is only required for the compiled env path.
- For Bit World, the cleanest integration is a custom Python vecenv plus a tiny runtime `_C` shim, while keeping the actual trainer on upstream PufferLib 4.0.

## What This Supports

- all current BitWorld environments through one shared Python vecenv / policy / trainer path
- one-player-per-server training workers
- true server-side reward metrics from the game, not HUD OCR
- fast reset via a single-byte reset command
- async server-side ticking with policy-side action chunking
- stacked 128x128 palette-index observations
- direct training with `pufferlib.torch_pufferl.PuffeRL`

Current environments and reward metrics:

- `asteroid_arena`: `score`
- `big_adventure`: `coins_collected`
- `boundless_factory`: `factory_progress`
- `bubble_eats`: `score`
- `fancy_cookout`: `kitchen_progress`
- `free_chat`: `messages_published`
- `infinite_blocks`: `score`
- `overworld`: `villages_entered`
- `planet_wars`: `score`
- `tag`: `score`

## Setup

Use Python 3.12 or newer. On this machine, Python 3.12 is the safest choice.

```bash
python3.12 -m venv .venv-puffer
source .venv-puffer/bin/activate
pip install -e '.[train]'
```

## Smoke Test

```bash
source .venv-puffer/bin/activate
python -m unittest tools/pufferlib/test_bubble_eats_env.py
```

This smoke test now exercises the full environment registry, not just `bubble_eats`.

## Train

```bash
source .venv-puffer/bin/activate
python tools/pufferlib/train_bitworld_env.py \
  --env bubble_eats \
  --total-timesteps 50000 \
  --num-envs 8 \
  --action-repeat 4 \
  --fps 0
```

Outputs land under `tools/runlogs/<env>_pufferlib_training/` unless you override `--output-dir`.

The training script saves:

- `<env>_policy.pt`
- `train_metrics.json`
- `eval_summary.json`

The evaluation summary compares the trained policy against a random baseline using sampled policy actions. This matches the way PPO policies are actually rolled out during training and avoids the false regressions caused by forcing greedy `argmax` on stochastic policies.

Representative validated result on April 23, 2026 for `bubble_eats` with a 50k-step run:

- trained policy: `mean_score = 1.18` over 100 held-out episodes
- random baseline: `mean_score = 0.38` over 100 held-out episodes

## Notes

- The Nim server uses its normal `/ws` websocket for input and packed pixel frames, plus `/reward` for the current cumulative episode reward.
- The Python vecenv samples `--action-repeat` streamed frames per policy action and polls `/reward` for score deltas.
- Some environments use shaped progress metrics instead of raw HUD score because their native score is too sparse for single-agent PPO to learn reliably within practical episode lengths.
