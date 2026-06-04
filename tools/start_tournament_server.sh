#!/bin/bash
set -euo pipefail

export PATH="/home/ubuntu/.nimby/nim/bin:$PATH"

export ECS_CLUSTER=bitworld-cluster
export ECS_PUBLIC_SUBNET=subnet-0bfdcc939a2a25148
export ECS_PRIVATE_SUBNET=subnet-065e93457a83febbb
export ECS_GAME_SG=sg-02c003356746211fa
export ECS_BOT_SG=sg-084e721230bec8d99
export ECS_EXECUTION_ROLE_ARN=arn:aws:iam::352017690007:role/bitworld-ecs-execution
export ECS_TASK_ROLE_ARN=arn:aws:iam::352017690007:role/bitworld-ecs-task
export ECS_LOG_GROUP=/ecs/bitworld
export ECS_REGION=us-east-1

# Always use the only profile that has the required ECS + S3 perms for --ecs.
export AWS_PROFILE=sandbox-andre

export TOURNAMENT_REPLAY_DIR=/home/ubuntu/tournament_replays
mkdir -p "$TOURNAMENT_REPLAY_DIR"

TOKEN=$(curl -s --connect-timeout 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
PRIVATE_IP=$(curl -s --connect-timeout 2 -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4 || echo "")
if [ -n "$PRIVATE_IP" ]; then
  export TOURNAMENT_URL="http://${PRIVATE_IP}:2081"
  echo "Computed TOURNAMENT_URL=${TOURNAMENT_URL}"
fi

# S3 bucket for read-only game configs (presigned GETs for COGAME_CONFIG_URI).
# The binary now defaults to "bitworld-game-configs" when --ecs is used, so this is optional
# (for override or explicitness). The bucket is created by terraform as ${project_name}-game-configs.
export BITWORLD_GAME_CONFIGS_BUCKET=bitworld-game-configs
export BITWORLD_REPLAY_S3_BUCKET=bitworld-replays
# boto3 required for generatePresignedPutUrl (S3 PUT presigns) in --ecs upload path
python3 -c "import boto3" >/dev/null 2>&1 || pip3 install --user boto3 2>/dev/null || true

cd /home/ubuntu/bitworld

# Default to a small among_them tournament for testing if no overrides provided via env
DEFAULT_MANIFEST="games_server/games/among_them/coworld_manifest.json"

echo "Starting tournament_server on 2081 with --ecs ..."
exec ./out/tournament_server --ecs --port=2081 --games=1 \
  --manifest="${TOURNAMENT_MANIFEST:-$DEFAULT_MANIFEST}" \
  ${TOURNAMENT_PLAYERS:+--players="$TOURNAMENT_PLAYERS"} \
  2>&1 | tee -a /home/ubuntu/tournament_server.log
