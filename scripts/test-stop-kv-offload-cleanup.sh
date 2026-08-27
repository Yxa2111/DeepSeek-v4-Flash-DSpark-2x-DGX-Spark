#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

export WORKER_HOST=test-worker
export ENV_FILE="$TMP_DIR/missing.env"
# shellcheck source=../stop-deepseek-v4-flash-dspark.sh
source "$ROOT/stop-deepseek-v4-flash-dspark.sh"

pass=0
fail=0
ok() { printf '  ok  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*" >&2; fail=$((fail + 1)); }

expect_true() {
  local label="$1"
  shift
  if "$@"; then ok "$label"; else bad "$label"; fi
}

expect_false() {
  local label="$1"
  shift
  if "$@"; then bad "$label"; else ok "$label"; fi
}

expect_true "canonical mmap accepted" \
  valid_offload_mmap_path /dev/shm/vllm_offload_1787798233982470445.mmap
expect_false "mmap traversal rejected" \
  valid_offload_mmap_path /dev/shm/vllm_offload_123.mmap/escape
expect_false "mmap deleted suffix rejected" \
  valid_offload_mmap_path '/dev/shm/vllm_offload_123.mmap (deleted)'
expect_true "absolute root with spaces accepted" valid_kv_offload_root '/tmp/kv root'
expect_false "relative root rejected" valid_kv_offload_root 'tmp/kv'
expect_false "bind option comma rejected" valid_kv_offload_root '/tmp/kv,ro'
expect_false "bind option colon rejected" valid_kv_offload_root '/tmp/kv:ro'

HEAD_MMAP_PATHS=()
WORKER_MMAP_PATHS=()
remember_offload_mmap_path head /dev/shm/vllm_offload_head.mmap
remember_offload_mmap_path head /dev/shm/vllm_offload_head.mmap
remember_offload_mmap_path worker /dev/shm/vllm_offload_worker.mmap
if [ "${#HEAD_MMAP_PATHS[@]}" -eq 1 ] \
  && [ "${HEAD_MMAP_PATHS[0]}" = /dev/shm/vllm_offload_head.mmap ] \
  && [ "${#WORKER_MMAP_PATHS[@]}" -eq 1 ]; then
  ok "captured paths are exact and de-duplicated per node"
else
  bad "captured paths are exact and de-duplicated per node"
fi

DOCKER_LOG="$TMP_DIR/docker.log"
SSH_LOG="$TMP_DIR/ssh.log"
docker() { printf '%q ' "$@" >> "$DOCKER_LOG"; printf '\n' >> "$DOCKER_LOG"; }
ssh() { printf '%q ' "$@" >> "$SSH_LOG"; printf '\n' >> "$SSH_LOG"; }

DSPARK_VLLM_IMAGE=test/runtime:exact
mkdir -p "$TMP_DIR/head root"
remove_captured_mmaps local /dev/shm/vllm_offload_head.mmap
remove_nvme_slot local "$TMP_DIR/head root" 0
WORKER_REACHABLE=1
remove_captured_mmaps remote /dev/shm/vllm_offload_worker.mmap
remove_nvme_slot remote '/srv/worker kv' 1

if grep -Fq -- '--ipc=host --entrypoint /bin/rm test/runtime:exact -f -- /dev/shm/vllm_offload_head.mmap' "$DOCKER_LOG"; then
  ok "head cleanup removes only captured mmap"
else
  bad "head cleanup removes only captured mmap"
fi
if grep -Fq -- '--mount' "$DOCKER_LOG" \
  && grep -Fq -- 'type=bind' "$DOCKER_LOG" \
  && grep -Fq -- '/kv-offload-root/vllm-kv.slots.rank_0' "$DOCKER_LOG"; then
  ok "head cleanup targets the rank-zero slot"
else
  bad "head cleanup targets the rank-zero slot"
fi
if grep -Fq -- '/dev/shm/vllm_offload_worker.mmap' "$SSH_LOG" \
  && grep -Fq -- '/kv-offload-root/vllm-kv.slots.rank_1' "$SSH_LOG"; then
  ok "worker cleanup targets captured mmap and rank-one slot"
else
  bad "worker cleanup targets captured mmap and rank-one slot"
fi
if grep -Eq 'vllm_offload_.*\\\*|vllm-kv\.slots\.rank_.*\\\*' "$DOCKER_LOG" "$SSH_LOG"; then
  bad "cleanup emitted a destructive wildcard"
else
  ok "cleanup emits no destructive wildcard"
fi

before_lines="$(wc -l < "$DOCKER_LOG")"
STOP_FAILURES=0
remove_nvme_slot local '/tmp/unsafe,root' 0 2>/dev/null
after_lines="$(wc -l < "$DOCKER_LOG")"
if [ "$STOP_FAILURES" -eq 1 ] && [ "$before_lines" = "$after_lines" ]; then
  ok "unsafe root fails closed before docker"
else
  bad "unsafe root fails closed before docker"
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
