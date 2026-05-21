#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_METTA_REPO="${REPO_ROOT}/../metta"
if [[ ! -d "${DEFAULT_METTA_REPO}/packages/coworld" && -d "/Users/relh/Code/metta/packages/coworld" ]]; then
  DEFAULT_METTA_REPO="/Users/relh/Code/metta"
fi

METTA_REPO="${METTA_REPO:-${DEFAULT_METTA_REPO}}"
COWORLD_SERVER="${COWORLD_SERVER:-https://softmax.com/api}"
REGISTRY="${REGISTRY:-ghcr.io/metta-ai}"
CERTIFY_TIMEOUT="${CERTIFY_TIMEOUT:-180}"
S3_VIEWER_URI="${S3_VIEWER_URI:-s3://softmax-public/bitworld/among_them/1}"
COWORLD_COMPOSE="${COWORLD_COMPOSE:-${METTA_REPO}/worlds/among_them/compose.yaml}"
COWORLD_TEMPLATE="${COWORLD_TEMPLATE:-${METTA_REPO}/worlds/among_them/coworld_manifest_template.json}"

VERSION=""
RUN_GIT_PULL=1
ALLOW_DIRTY=0
SKIP_GHCR=0
SKIP_COWORLD=0
SKIP_REPLAY_VIEWER=0

usage() {
  cat <<'EOF'
Usage:
  among_them/upload.sh VERSION [options]

Build and upload the Among Them Coworld release from BitWorld master.

Steps:
  1. git pull --ff-only and require a clean master checkout.
  2. Build and push GHCR images for the game runner and ivotewell baseline.
  3. Build and upload the Coworld through Metta's canonical coworld build.
  4. Rebuild and upload the hosted replay viewer bundle to S3.

Options:
  --allow-dirty          Build from a dirty checkout.
  --no-pull              Do not git pull before building.
  --skip-ghcr            Do not push GHCR images.
  --skip-coworld         Skip Coworld certify/upload.
  --skip-replay-viewer   Skip replay viewer build/upload.
  -h, --help             Show this help.

Environment:
  METTA_REPO             Metta checkout used for uv run coworld.
  COWORLD_SERVER         Observatory API URL.
  REGISTRY               GHCR registry prefix, default ghcr.io/metta-ai.
  CERTIFY_TIMEOUT        Coworld certifier timeout seconds.
  S3_VIEWER_URI          S3 prefix for replay_viewer.{html,js,wasm,data}.
  COWORLD_COMPOSE        Metta Coworld compose.yaml path.
  COWORLD_TEMPLATE       Metta Coworld manifest template path.
  GHCR_USERNAME          Optional GHCR username.
  GHCR_TOKEN             Optional GHCR token. If omitted, gh auth token is used.

Notes:
  This script intentionally uses the public Coworld upload API. If
  upload-coworld fails with PackedPolicyTooLarge, fix the Observatory image
  upload IAM path or use a private ops-only workaround; do not vendor direct
  production DB writes into this public repo.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --no-pull)
      RUN_GIT_PULL=0
      shift
      ;;
    --skip-ghcr)
      SKIP_GHCR=1
      shift
      ;;
    --skip-coworld)
      SKIP_COWORLD=1
      shift
      ;;
    --skip-replay-viewer)
      SKIP_REPLAY_VIEWER=1
      shift
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -n "${VERSION}" ]]; then
        die "Only one version argument is supported"
      fi
      VERSION="${1#v}"
      shift
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  usage
  exit 1
fi
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.][0-9]+)?$ ]]; then
  die "Version must look like 0.1.23 or v0.1.23, got: ${VERSION}"
fi
if [[ ! -d "${METTA_REPO}/packages/coworld" ]]; then
  die "METTA_REPO does not look like a Metta checkout: ${METTA_REPO}"
fi

for cmd in git docker nim uv python3 aws; do
  command -v "${cmd}" >/dev/null || die "Missing required command: ${cmd}"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bitworld-among-them-upload.${VERSION}.XXXXXX")"
UPLOAD_MANIFEST="${WORK_DIR}/coworld_manifest.json"
DOCKER_CONFIG_DIR=""

cleanup() {
  if [[ -n "${DOCKER_CONFIG_DIR}" ]]; then
    rm -rf "${DOCKER_CONFIG_DIR}"
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

metta_uv() {
  (cd "${METTA_REPO}" && uv run "$@")
}

coworld() {
  metta_uv coworld "$@"
}

setup_ghcr_docker_config() {
  if [[ "${SKIP_GHCR}" -eq 1 ]]; then
    return
  fi

  local ghcr_user="${GHCR_USERNAME:-}"
  local ghcr_token="${GHCR_TOKEN:-}"
  if [[ -z "${ghcr_user}" || -z "${ghcr_token}" ]]; then
    command -v gh >/dev/null || die "Install gh, or set GHCR_USERNAME and GHCR_TOKEN"
    ghcr_user="$(gh api user -q .login)"
    ghcr_token="$(gh auth token)"
  fi

  DOCKER_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bitworld-docker-config.XXXXXX")"
  mkdir -p "${DOCKER_CONFIG_DIR}/cli-plugins"
  for plugin in docker-buildx docker-compose; do
    if [[ -x "${HOME}/.docker/cli-plugins/${plugin}" ]]; then
      ln -s "${HOME}/.docker/cli-plugins/${plugin}" "${DOCKER_CONFIG_DIR}/cli-plugins/${plugin}"
    fi
  done

  GHCR_USERNAME="${ghcr_user}" GHCR_TOKEN="${ghcr_token}" python3 - >"${DOCKER_CONFIG_DIR}/config.json" <<'PY'
import base64
import json
import os

auth = base64.b64encode(f"{os.environ['GHCR_USERNAME']}:{os.environ['GHCR_TOKEN']}".encode()).decode()
print(json.dumps({"auths": {"ghcr.io": {"auth": auth}}}))
PY

  export DOCKER_CONFIG="${DOCKER_CONFIG_DIR}"
}

require_master_checkout() {
  log "Refreshing BitWorld master"
  local branch
  branch="$(git -C "${REPO_ROOT}" branch --show-current)"
  [[ "${branch}" == "master" ]] || die "Expected BitWorld master, got ${branch:-detached HEAD}"

  if [[ "${RUN_GIT_PULL}" -eq 1 ]]; then
    run git -C "${REPO_ROOT}" pull --ff-only
  fi

  if [[ "${ALLOW_DIRTY}" -eq 0 ]]; then
    local status
    status="$(git -C "${REPO_ROOT}" status --porcelain)"
    [[ -z "${status}" ]] || die "Working tree is dirty. Commit/stash first or pass --allow-dirty."
  fi
}

build_and_push_ghcr_images() {
  if [[ "${SKIP_GHCR}" -eq 1 ]]; then
    log "Skipping GHCR push"
    return
  fi

  setup_ghcr_docker_config
  log "Building and pushing multi-arch GHCR images"
  run nim r "${REPO_ROOT}/tools/docker_build.nim" \
    --push \
    --registry:"${REGISTRY}" \
    --tag:"${VERSION}" \
    among_them \
    ivotewell
}

upload_coworld() {
  if [[ "${SKIP_COWORLD}" -eq 1 ]]; then
    log "Skipping Coworld certify/upload"
    return
  fi

  [[ -f "${COWORLD_COMPOSE}" ]] || die "Coworld compose file not found: ${COWORLD_COMPOSE}"
  [[ -f "${COWORLD_TEMPLATE}" ]] || die "Coworld manifest template not found: ${COWORLD_TEMPLATE}"

  local build_log="${WORK_DIR}/coworld-build.log"
  log "Building Coworld manifest and images with Metta coworld build"
  set +e
  coworld build \
    "${COWORLD_COMPOSE}" \
    "${COWORLD_TEMPLATE}" \
    "${VERSION}" \
    "${UPLOAD_MANIFEST}" 2>&1 | tee "${build_log}"
  local build_status="${PIPESTATUS[0]}"
  set -e
  [[ "${build_status}" -eq 0 ]] || die "coworld build failed. See ${build_log}"

  local upload_log="${WORK_DIR}/upload-coworld.log"
  log "Certifying and uploading Coworld"
  set +e
  coworld upload-coworld \
    "${UPLOAD_MANIFEST}" \
    --server "${COWORLD_SERVER}" \
    --timeout-seconds "${CERTIFY_TIMEOUT}" 2>&1 | tee "${upload_log}"
  local upload_status="${PIPESTATUS[0]}"
  set -e

  if [[ "${upload_status}" -ne 0 ]]; then
    if grep -q "PackedPolicyTooLarge" "${upload_log}"; then
      die "Observatory /v2/container_images/upload hit PackedPolicyTooLarge. This is an infra IAM issue, not a BitWorld build failure. The public upload script stops here instead of writing prod DB rows directly."
    fi
    die "coworld upload-coworld failed. See ${upload_log}"
  fi

  local coworld_id
  coworld_id="$(awk '/^Coworld:/ {print $2}' "${upload_log}" | tail -1)"
  if [[ -n "${coworld_id}" ]]; then
    log "Verifying uploaded Coworld ${coworld_id}"
    coworld show "${coworld_id}" --server "${COWORLD_SERVER}" --json
  fi
}

upload_replay_viewer() {
  if [[ "${SKIP_REPLAY_VIEWER}" -eq 1 ]]; then
    log "Skipping replay viewer upload"
    return
  fi

  log "Building replay viewer wasm bundle"
  (cd "${REPO_ROOT}" && run nim c -d:emscripten -d:release among_them/replay_viewer.nim)

  local bundle_dir="${REPO_ROOT}/among_them/emscripten"
  local backup_uri="${S3_VIEWER_URI%/}/backups/$(date -u +%Y%m%dT%H%M%SZ)"

  log "Backing up current hosted replay viewer bundle"
  for file in replay_viewer.html replay_viewer.js replay_viewer.wasm replay_viewer.data; do
    if aws s3 ls "${S3_VIEWER_URI%/}/${file}" >/dev/null 2>&1; then
      run aws s3 cp "${S3_VIEWER_URI%/}/${file}" "${backup_uri}/${file}"
    fi
  done

  log "Uploading replay viewer bundle"
  run aws s3 cp "${bundle_dir}/replay_viewer.html" "${S3_VIEWER_URI%/}/replay_viewer.html" \
    --content-type text/html \
    --cache-control no-cache
  run aws s3 cp "${bundle_dir}/replay_viewer.js" "${S3_VIEWER_URI%/}/replay_viewer.js" \
    --content-type application/javascript \
    --cache-control no-cache
  run aws s3 cp "${bundle_dir}/replay_viewer.wasm" "${S3_VIEWER_URI%/}/replay_viewer.wasm" \
    --content-type application/wasm \
    --cache-control no-cache
  run aws s3 cp "${bundle_dir}/replay_viewer.data" "${S3_VIEWER_URI%/}/replay_viewer.data" \
    --content-type application/octet-stream \
    --cache-control no-cache

  log "Verifying replay viewer objects"
  for file in replay_viewer.html replay_viewer.js replay_viewer.wasm replay_viewer.data; do
    run aws s3api head-object \
      --bucket softmax-public \
      --key "bitworld/among_them/1/${file}" \
      --query '{ContentType:ContentType,CacheControl:CacheControl,ContentLength:ContentLength}' \
      --output json
  done
}

require_master_checkout
build_and_push_ghcr_images
upload_coworld
upload_replay_viewer

log "Among Them ${VERSION} upload flow complete"
