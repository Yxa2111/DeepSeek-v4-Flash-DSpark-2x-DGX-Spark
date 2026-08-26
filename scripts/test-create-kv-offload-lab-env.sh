#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

source_env="$tmp/source.env"
target_env="$tmp/lab/target.env"
printf '%s\n' \
  'SECRET_TOKEN=keep-me' \
  'DSPARK_VLLM_IMAGE=old:image' \
  'WORKER_DIR=/old/worker' \
  'WORKER_SCRIPT_DIR=/old/script' \
  'KV_OFFLOAD_MODE=off' \
  'DSPARK_SPECULATION=off' > "$source_env"
chmod 640 "$source_env"

LAB_DSPARK_VLLM_IMAGE='diag:image' \
LAB_WORKER_DIR='/lab/worker dir' \
LAB_KV_OFFLOAD_ROOT='/lab/head-kv' \
LAB_WORKER_KV_OFFLOAD_ROOT='/lab/worker-kv' \
  "$ROOT/scripts/create-kv-offload-lab-env.sh" "$source_env" "$target_env" >/dev/null

[ "$(stat -c %a "$target_env")" = 600 ]
[ "$(grep -c '^SECRET_TOKEN=keep-me$' "$target_env")" -eq 1 ]
[ "$(grep -c '^DSPARK_VLLM_IMAGE=diag:image$' "$target_env")" -eq 1 ]
[ "$(grep -c '^WORKER_SCRIPT_DIR=/lab/worker\\ dir$' "$target_env")" -eq 1 ]
[ "$(grep -c '^KV_OFFLOAD_MODE=fs-poc$' "$target_env")" -eq 1 ]
[ "$(grep -c '^DSPARK_SPECULATION=dspark$' "$target_env")" -eq 1 ]
[ "$(grep -c '^DSPARK_RESTART_POLICY=no$' "$target_env")" -eq 1 ]
[ "$(grep -c '^WORKER_DIR=' "$target_env" || true)" -eq 0 ]
[ "$(grep -c '^WORKER_SCRIPT_DIR=' "$target_env")" -eq 1 ]

before="$(sha256sum "$source_env")"
if LAB_DSPARK_VLLM_IMAGE='diag:image' \
  LAB_WORKER_DIR='relative' \
  LAB_KV_OFFLOAD_ROOT='/lab/head-kv' \
  LAB_WORKER_KV_OFFLOAD_ROOT='/lab/worker-kv' \
  "$ROOT/scripts/create-kv-offload-lab-env.sh" "$source_env" "$tmp/bad.env" >/dev/null 2>&1; then
  echo "FAIL relative path accepted" >&2
  exit 1
fi
[ "$before" = "$(sha256sum "$source_env")" ]
[ ! -e "$tmp/bad.env" ]

echo "KV offload lab env generator tests passed"
