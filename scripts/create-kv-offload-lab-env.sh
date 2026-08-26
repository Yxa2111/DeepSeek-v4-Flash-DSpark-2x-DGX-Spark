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

target_dir="$(dirname "$target_env")"
mkdir -p -- "$target_dir"
tmp_env="$(mktemp "$target_dir/.kv-offload-env.tmp.XXXXXX")"
cleanup() { rm -f -- "$tmp_env"; }
trap cleanup EXIT HUP INT TERM
umask 077

awk '
  BEGIN {
    split("DSPARK_VLLM_IMAGE WORKER_DIR WORKER_SCRIPT_DIR KV_OFFLOAD_ROOT WORKER_KV_OFFLOAD_ROOT KV_OFFLOAD_MODE KV_OFFLOAD_CPU_BYTES KV_OFFLOAD_READ_THREADS KV_OFFLOAD_WRITE_THREADS KV_OFFLOAD_PYTHONHASHSEED DSPARK_KV_OFFLOAD_DIAG DSPARK_SPECULATION DSPARK_RESTART_POLICY", keys, " ")
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
  printf 'KV_OFFLOAD_MODE=%q\n' "${LAB_KV_OFFLOAD_MODE:-fs-poc}"
  printf 'KV_OFFLOAD_CPU_BYTES=%q\n' "${LAB_KV_OFFLOAD_CPU_BYTES:-536870912}"
  printf 'KV_OFFLOAD_READ_THREADS=%q\n' "${LAB_KV_OFFLOAD_READ_THREADS:-8}"
  printf 'KV_OFFLOAD_WRITE_THREADS=%q\n' "${LAB_KV_OFFLOAD_WRITE_THREADS:-4}"
  printf 'KV_OFFLOAD_PYTHONHASHSEED=%q\n' "${LAB_KV_OFFLOAD_PYTHONHASHSEED:-0}"
  printf 'DSPARK_KV_OFFLOAD_DIAG=%q\n' "${LAB_DSPARK_KV_OFFLOAD_DIAG:-1}"
  printf 'DSPARK_SPECULATION=%q\n' "${LAB_DSPARK_SPECULATION:-dspark}"
  printf 'DSPARK_RESTART_POLICY=%q\n' "${LAB_DSPARK_RESTART_POLICY:-no}"
} >> "$tmp_env"

chmod 600 "$tmp_env"
mv -f -- "$tmp_env" "$target_env"
trap - EXIT HUP INT TERM

echo "Created private lab env: $target_env (mode 600)"
