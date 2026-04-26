#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

command -v uv >/dev/null || {
  echo "error: uv is required. Install it, then rerun ./install.sh" >&2
  exit 1
}
command -v nim >/dev/null || {
  echo "error: Nim >=2.2.4 is required. Install it, then rerun ./install.sh" >&2
  exit 1
}
command -v nimby >/dev/null || {
  echo "error: nimby is required. Install it, then rerun ./install.sh" >&2
  exit 1
}

echo "==> Creating .venv with uv"
uv venv --python 3.12 --allow-existing .venv

echo "==> Activating .venv"
source .venv/bin/activate

echo "==> Installing Python training dependencies"
uv pip install -e '.[train]'

echo "==> Installing Nim dependencies"
nim --version | sed -n '1,4p'
nimby -g sync nimby.lock

echo "==> Checking native Among Them bridge"
nim check tools/pufferlib/among_them_native.nim

cat <<'EOF'

Setup complete.

Activate this environment with:
  source .venv/bin/activate

Run a CUDA training smoke test with:
  python tools/pufferlib/train_bitworld_env.py --env among_them --total-timesteps 40 --num-envs 1 --episode-steps 8 --frame-stack 2 --horizon 4 --minibatch-size 4 --hidden-size 32 --action-repeat 1 --device cuda --eval-episodes 0

Run a longer training job with:
  python tools/pufferlib/train_bitworld_env.py --env among_them --total-timesteps 50000 --num-envs 8 --action-repeat 4 --device cuda
EOF
