#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 SOURCE_ENV TARGET_ENV" >&2
  echo "Required env: LAB_DSPARK_VLLM_IMAGE LAB_WORKER_DIR LAB_KV_OFFLOAD_ROOT LAB_WORKER_KV_OFFLOAD_ROOT" >&2
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

source_env="$1"
target_env="$2"
: "${LAB_DSPARK_VLLM_IMAGE:?LAB_DSPARK_VLLM_IMAGE must be set}"
: "${LAB_WORKER_DIR:?LAB_WORKER_DIR must be set}"
: "${LAB_KV_OFFLOAD_ROOT:?LAB_KV_OFFLOAD_ROOT must be set}"
: "${LAB_WORKER_KV_OFFLOAD_ROOT:?LAB_WORKER_KV_OFFLOAD_ROOT must be set}"

if [ ! -f "$source_env" ]; then
  echo "Source env does not exist: $source_env" >&2
  exit 2
fi
if [ "$source_env" -ef "$target_env" ] 2>/dev/null; then
  echo "Source and target env must be different files" >&2
  exit 2
fi
for path in "$LAB_WORKER_DIR" "$LAB_KV_OFFLOAD_ROOT" "$LAB_WORKER_KV_OFFLOAD_ROOT"; do
  case "$path" in
    /*) ;;
    *) echo "Lab paths must be absolute: $path" >&2; exit 2 ;;
  esac
  case "$path" in
    *:*|*[$'\r\n']*) echo "Lab paths must not contain colon or newlines: $path" >&2; exit 2 ;;
  esac
done

lab_gpu_memory_utilization_text="${LAB_GPU_MEMORY_UTILIZATION_TEXT:-0.72}"
if ! [[ "$lab_gpu_memory_utilization_text" =~ ^(0|1)(\.[0-9]+)?$ ]] \
  || ! awk -v value="$lab_gpu_memory_utilization_text" \
    'BEGIN { exit !(value > 0 && value < 1) }'; then
  echo "LAB_GPU_MEMORY_UTILIZATION_TEXT must be a decimal between 0 and 1" >&2
  exit 2
fi
lab_oom_score_adj="${LAB_DSPARK_OOM_SCORE_ADJ:-800}"
if ! [[ "$lab_oom_score_adj" =~ ^[0-9]+$ ]] \
  || [ "$lab_oom_score_adj" -gt 1000 ]; then
  echo "LAB_DSPARK_OOM_SCORE_ADJ must be an integer from 0 through 1000" >&2
  exit 2
fi

target_dir="$(dirname "$target_env")"
mkdir -p -- "$target_dir"
tmp_env="$(mktemp "$target_dir/.kv-offload-env.tmp.XXXXXX")"
cleanup() { rm -f -- "$tmp_env"; }
trap cleanup EXIT HUP INT TERM
umask 077

awk '
  BEGIN {
    split("DSPARK_VLLM_IMAGE WORKER_DIR WORKER_SCRIPT_DIR KV_OFFLOAD_ROOT WORKER_KV_OFFLOAD_ROOT KV_OFFLOAD_MODE KV_OFFLOAD_CPU_BYTES KV_OFFLOAD_READ_THREADS KV_OFFLOAD_WRITE_THREADS KV_OFFLOAD_PYTHONHASHSEED KV_OFFLOAD_CACHE_IDENTITY KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES KV_OFFLOAD_DISK_BYTES KV_OFFLOAD_DISK_BUFFER_SLOTS KV_OFFLOAD_DISK_QUEUE_DEPTH KV_OFFLOAD_DISK_ENQUEUE_TIMEOUT_SECONDS KV_OFFLOAD_DISK_MAX_STORE_BLOCKS KV_OFFLOAD_USE_PAGE_CACHE KV_OFFLOAD_PREALLOCATE_DISK DSPARK_KV_OFFLOAD_DIAG DSPARK_SPECULATION DSPARK_RESTART_POLICY DSPARK_OOM_SCORE_ADJ MAX_MODEL_LEN MAX_NUM_SEQS MAX_NUM_BATCHED_TOKENS DSPARK_BOOT_SHAPE_WARMUP ENABLE_VL_SIDECAR GPU_MEMORY_UTILIZATION_TEXT", keys, " ")
    for (i in keys) drop[keys[i]] = 1
  }
  {
    key = $0
    sub(/=.*/, "", key)
    sub(/^[[:space:]]*export[[:space:]]+/, "", key)
    sub(/^[[:space:]]+/, "", key)
    sub(/[[:space:]]+$/, "", key)
    if (!(key in drop)) print $0
  }
' "$source_env" > "$tmp_env"

{
  printf '\n# Generated KV offload lab overrides. Do not edit production env.\n'
  printf 'DSPARK_VLLM_IMAGE=%q\n' "$LAB_DSPARK_VLLM_IMAGE"
  printf 'WORKER_SCRIPT_DIR=%q\n' "$LAB_WORKER_DIR"
  printf 'KV_OFFLOAD_ROOT=%q\n' "$LAB_KV_OFFLOAD_ROOT"
  printf 'WORKER_KV_OFFLOAD_ROOT=%q\n' "$LAB_WORKER_KV_OFFLOAD_ROOT"
  printf 'KV_OFFLOAD_MODE=%q\n' "${LAB_KV_OFFLOAD_MODE:-fs-rank0}"
  printf 'KV_OFFLOAD_CPU_BYTES=%q\n' "${LAB_KV_OFFLOAD_CPU_BYTES:-536870912}"
  printf 'KV_OFFLOAD_READ_THREADS=%q\n' "${LAB_KV_OFFLOAD_READ_THREADS:-8}"
  printf 'KV_OFFLOAD_WRITE_THREADS=%q\n' "${LAB_KV_OFFLOAD_WRITE_THREADS:-4}"
  printf 'KV_OFFLOAD_PYTHONHASHSEED=%q\n' "${LAB_KV_OFFLOAD_PYTHONHASHSEED:-0}"
  printf 'KV_OFFLOAD_CACHE_IDENTITY=%q\n' "${LAB_KV_OFFLOAD_CACHE_IDENTITY:-}"
  printf 'KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES=%q\n' "${LAB_KV_OFFLOAD_MAX_TRANSFER_CHUNK_BYTES:-67108864}"
  printf 'KV_OFFLOAD_DISK_BYTES=%q\n' "${LAB_KV_OFFLOAD_DISK_BYTES:-68719476736}"
  printf 'KV_OFFLOAD_DISK_BUFFER_SLOTS=%q\n' "${LAB_KV_OFFLOAD_DISK_BUFFER_SLOTS:-2}"
  printf 'KV_OFFLOAD_DISK_QUEUE_DEPTH=%q\n' \
    "${LAB_KV_OFFLOAD_DISK_QUEUE_DEPTH:-2}"
  printf 'KV_OFFLOAD_DISK_ENQUEUE_TIMEOUT_SECONDS=%q\n' \
    "${LAB_KV_OFFLOAD_DISK_ENQUEUE_TIMEOUT_SECONDS:-30}"
  printf 'KV_OFFLOAD_DISK_MAX_STORE_BLOCKS=%q\n' \
    "${LAB_KV_OFFLOAD_DISK_MAX_STORE_BLOCKS:-64}"
  printf 'KV_OFFLOAD_USE_PAGE_CACHE=%q\n' "${LAB_KV_OFFLOAD_USE_PAGE_CACHE:-0}"
  printf 'KV_OFFLOAD_PREALLOCATE_DISK=%q\n' "${LAB_KV_OFFLOAD_PREALLOCATE_DISK:-1}"
  printf 'DSPARK_KV_OFFLOAD_DIAG=%q\n' "${LAB_DSPARK_KV_OFFLOAD_DIAG:-1}"
  printf 'DSPARK_SPECULATION=%q\n' "${LAB_DSPARK_SPECULATION:-dspark}"
  printf 'DSPARK_RESTART_POLICY=%q\n' "${LAB_DSPARK_RESTART_POLICY:-no}"
  printf 'DSPARK_OOM_SCORE_ADJ=%q\n' "$lab_oom_score_adj"
  printf 'MAX_MODEL_LEN=%q\n' "${LAB_MAX_MODEL_LEN:-262144}"
  printf 'MAX_NUM_SEQS=%q\n' "${LAB_MAX_NUM_SEQS:-2}"
  printf 'MAX_NUM_BATCHED_TOKENS=%q\n' "${LAB_MAX_NUM_BATCHED_TOKENS:-8192}"
  printf 'DSPARK_BOOT_SHAPE_WARMUP=%q\n' "${LAB_DSPARK_BOOT_SHAPE_WARMUP:-0}"
  printf 'ENABLE_VL_SIDECAR=%q\n' "${LAB_ENABLE_VL_SIDECAR:-0}"
  # Step 07 observed only ~5.5 GiB MemAvailable at 0.81 before the head became
  # unresponsive. Start the disposable lab at 0.72 and promote only from
  # measured settled headroom. The production env is not changed.
  printf 'GPU_MEMORY_UTILIZATION_TEXT=%q\n' "$lab_gpu_memory_utilization_text"
} >> "$tmp_env"

chmod 600 "$tmp_env"
mv -f -- "$tmp_env" "$target_env"
trap - EXIT HUP INT TERM

echo "Created private lab env: $target_env (mode 600)"
