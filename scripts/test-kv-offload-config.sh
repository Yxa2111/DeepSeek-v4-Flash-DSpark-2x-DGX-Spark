#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/patches/kv-offload-config.sh"

pass=0
fail=0
ok() { printf '  ok  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*" >&2; fail=$((fail + 1)); }

reset_inputs() {
  unset KV_OFFLOAD_MODE KV_OFFLOAD_CPU_BYTES KV_OFFLOAD_READ_THREADS
  unset KV_OFFLOAD_WRITE_THREADS KV_OFFLOAD_PYTHONHASHSEED
  unset KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES
  unset KV_OFFLOAD_DISK_BYTES KV_OFFLOAD_DISK_BUFFER_SLOTS
  unset KV_OFFLOAD_USE_PAGE_CACHE KV_OFFLOAD_PREALLOCATE_DISK
  unset DSPARK_KV_OFFLOAD_DIAG DSPARK_SPECULATION DRAFT_SAMPLE_METHOD
  unset MTP_NUM_TOKENS MAX_NUM_SEQS PYTHONHASHSEED PYTORCH_CUDA_ALLOC_CONF
}

reset_inputs
if dspark_build_experimental_args \
  && [ "${#KV_TRANSFER_ARGS[@]}" -eq 0 ] \
  && [ "${#SPECULATIVE_ARGS[@]}" -eq 2 ] \
  && [ "$MAX_CUDAGRAPH_CAPTURE_SIZE" -eq 36 ] \
  && [ "$SPECULATIVE_CONFIG" = '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"probabilistic"}' ]; then
  ok "defaults preserve DSpark and leave KV offload disabled"
else
  bad "default argument contract"
fi

reset_inputs
KV_OFFLOAD_MODE=nvme-local
DSPARK_SPECULATION=dspark
PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
if dspark_build_experimental_args \
  && [ "${#KV_TRANSFER_ARGS[@]}" -eq 2 ] \
  && [ -z "${PYTORCH_CUDA_ALLOC_CONF+x}" ] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"kv_connector":"SimpleCPUOffloadConnector"'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"kv_offload_backend":"disk"'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"disk_path":"/kv-offload/vllm-kv.slots"'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"disk_capacity_bytes":68719476736'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"disk_buffer_slots":2'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"use_page_cache":false'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"preallocate_disk":true'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"lazy_offload":false'* ]]; then
  ok "nvme-local builds bounded per-rank direct-I/O tier"
else
  bad "nvme-local argument contract"
fi

reset_inputs
KV_OFFLOAD_MODE=fs-rank0
DSPARK_SPECULATION=off
MAX_NUM_SEQS=6
PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
if dspark_build_experimental_args \
  && [ "${#KV_TRANSFER_ARGS[@]}" -eq 2 ] \
  && [ "${KV_TRANSFER_ARGS[0]}" = "--kv-transfer-config" ] \
  && [ "${#SPECULATIVE_ARGS[@]}" -eq 0 ] \
  && [ "$MAX_CUDAGRAPH_CAPTURE_SIZE" -eq 6 ] \
  && [ "$PYTHONHASHSEED" = 0 ] \
  && [ -z "${PYTORCH_CUDA_ALLOC_CONF+x}" ] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"spec_name":"TieringOffloadingSpec"'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"distributed_staging":"rank0"'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"max_transfer_chunk_bytes":67108864'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"root_dir":"/kv-offload"'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"offload_prompt_only":true'* ]] \
  && [[ "$KV_OFFLOAD_CONFIG" == *'"kv_load_failure_policy":"recompute"'* ]]; then
  ok "fs-rank0 builds bounded rank-zero filesystem tier and target-only A/B"
else
  bad "fs-rank0 argument contract"
fi

expect_reject() {
  local label="$1"
  shift
  reset_inputs
  if env "$@" bash -c \
    'source "$1"; dspark_build_experimental_args' _ \
    "$ROOT/patches/kv-offload-config.sh" >/dev/null 2>&1; then
    bad "$label"
  else
    ok "$label"
  fi
}

expect_reject "unknown KV mode rejected" KV_OFFLOAD_MODE=ssd
expect_reject "unknown speculation mode rejected" DSPARK_SPECULATION=random
expect_reject "zero read threads rejected" KV_OFFLOAD_MODE=fs-poc KV_OFFLOAD_READ_THREADS=0
expect_reject "oversized CPU staging rejected" KV_OFFLOAD_MODE=fs-poc KV_OFFLOAD_CPU_BYTES=68719476737
expect_reject "non-numeric hash seed rejected" KV_OFFLOAD_MODE=fs-poc KV_OFFLOAD_PYTHONHASHSEED=random
expect_reject "undersized relay chunk rejected" KV_OFFLOAD_MODE=fs-rank0 KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES=1048575
expect_reject "oversized relay chunk rejected" KV_OFFLOAD_MODE=fs-rank0 KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES=268435457
expect_reject "undersized NVMe capacity rejected" KV_OFFLOAD_MODE=nvme-local KV_OFFLOAD_DISK_BYTES=1073741823
expect_reject "oversized NVMe capacity rejected" KV_OFFLOAD_MODE=nvme-local KV_OFFLOAD_DISK_BYTES=171798691841
expect_reject "invalid disk buffer count rejected" KV_OFFLOAD_MODE=nvme-local KV_OFFLOAD_DISK_BUFFER_SLOTS=9
expect_reject "page-cache flag injection rejected" 'KV_OFFLOAD_MODE=nvme-local' 'KV_OFFLOAD_USE_PAGE_CACHE=$(id)'
expect_reject "preallocation flag rejected" KV_OFFLOAD_MODE=nvme-local KV_OFFLOAD_PREALLOCATE_DISK=2
expect_reject "diagnostic flag injection rejected" 'DSPARK_KV_OFFLOAD_DIAG=$(id)'

if grep -Fq '${KV_OFFLOAD_ROOT:-${HOME}/.cache/dspark-kv-offload}:/kv-offload' \
  "$ROOT/docker-compose.dspark.yml" \
  && grep -Fq 'kv-offload-config.sh hotfix-dsv4-mtp-buffer' \
    "$ROOT/start-deepseek-v4-flash-dspark.sh"; then
  ok "KV root is mounted and helper is worker-synced"
else
  bad "compose mount or worker sync missing"
fi

printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
