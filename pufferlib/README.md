# BitWorld PufferLib

## Setup

```bash
./install.sh
source .venv/bin/activate
```

## Test

```bash
python pufferlib/test_bubble_eats_env.py
```

## Train

```bash
python pufferlib/train_bitworld_env.py \
  --env among_them \
  --total-timesteps 50000 \
  --num-envs 8 \
  --device auto
```

Training writes one playable policy checkpoint:

```text
tools/runlogs/among_them_pufferlib_training/among_them_policy.pt
```

For `among_them`, the same policy controls all five players during training through
the native Nim bridge by default. Pass `--players 16` to train the maximum game
size.

`among_them` also supports `--observation-mode state` for compact render-source
training. State observations are byte buffers produced from the same per-player
camera, sampled map/mask layer, visible task icon, body, player, and voting UI
inputs that feed the pixel renderer, before those inputs are expanded into a
full frame.

## Play Among Them

Train or reuse a checkpoint, then run one PufferLib policy player with four Nim
bot players:

```bash
python pufferlib/run_among_them_policy_match.py \
  --train-steps 50000 \
  --duration 60 \
  --device auto
```

The launcher prints a `/global` browser URL, starts a five-player server, connects
four Nim bots, and connects the policy as `/player?name=puffer`.

To connect a trained policy to an existing server:

```bash
python pufferlib/play_among_them_policy.py \
  tools/runlogs/among_them_policy_match/among_them_policy.pt \
  --address 127.0.0.1 \
  --port 2000 \
  --name puffer
```
