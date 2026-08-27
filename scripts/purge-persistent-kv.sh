#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: purge-persistent-kv.sh --confirm-identity ID [options]

Fail-closed, coordinated removal of the five fixed persistent packed-KV files
for one stopped TP=2 Compose project.  The default is a preflight-only dry run.

Options:
  --env-file FILE           private deployment env (default: ../.env.dspark)
  --project NAME            exact Compose project (default: env or deepseek-v4-flash)
  --confirm-identity ID     must equal KV_OFFLOAD_CACHE_IDENTITY (required)
  --execute                 perform the deletion after both-node preflight
  --allow-unverified-metadata
                            permit corrupt/missing metadata during recovery;
                            a valid different identity is never permitted
  -h, --help                show this help

The service must have zero running or stopped vllm-dspark containers under the
exact project on both nodes.  Purge invalidates the head scheduler index first,
then removes worker rank 1 and head rank 0 data/manifests, and verifies absence.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARG_ENV_FILE=
ARG_PROJECT=
CONFIRM_IDENTITY=
EXECUTE=0
ALLOW_UNVERIFIED_METADATA=0

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env-file)
        [ "$#" -ge 2 ] || { echo "--env-file requires a value" >&2; return 2; }
        ARG_ENV_FILE="$2"
        shift 2
        ;;
      --project)
        [ "$#" -ge 2 ] || { echo "--project requires a value" >&2; return 2; }
        ARG_PROJECT="$2"
        shift 2
        ;;
      --confirm-identity)
        [ "$#" -ge 2 ] || { echo "--confirm-identity requires a value" >&2; return 2; }
        CONFIRM_IDENTITY="$2"
        shift 2
        ;;
      --execute)
        EXECUTE=1
        shift
        ;;
      --allow-unverified-metadata)
        ALLOW_UNVERIFIED_METADATA=1
        shift
        ;;
      -h|--help)
        usage
        return 64
        ;;
      *)
        echo "unknown argument: $1" >&2
        usage >&2
        return 2
        ;;
    esac
  done
}

valid_root_syntax() {
  local root="$1"
  [[ "$root" = /* && "$root" != "/" && "$root" != *:* && "$root" != *,* \
    && "$root" != *$'\n'* && "$root" != *$'\r'* ]]
}

configure() {
  ENV_FILE="${ARG_ENV_FILE:-${ENV_FILE:-$SCRIPT_DIR/../.env.dspark}}"
  [ -f "$ENV_FILE" ] || { echo "env file does not exist: $ENV_FILE" >&2; return 2; }
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  PROJECT_NAME="${ARG_PROJECT:-${PROJECT_NAME:-deepseek-v4-flash}}"
  : "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE}"
  : "${DSPARK_VLLM_IMAGE:?DSPARK_VLLM_IMAGE must be set in $ENV_FILE}"
  : "${KV_OFFLOAD_ROOT:?KV_OFFLOAD_ROOT must be set in $ENV_FILE}"
  : "${KV_OFFLOAD_CACHE_IDENTITY:?KV_OFFLOAD_CACHE_IDENTITY must be set in $ENV_FILE}"
  WORKER_KV_OFFLOAD_ROOT="${WORKER_KV_OFFLOAD_ROOT:-$KV_OFFLOAD_ROOT}"

  DOCKER_BIN="${KV_PURGE_DOCKER_BIN:-docker}"
  SSH_BIN="${KV_PURGE_SSH_BIN:-ssh}"
  SYNC_BIN="${KV_PURGE_SYNC_BIN:-sync}"

  [[ "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || { echo "project contains unsupported characters" >&2; return 2; }
  [[ "$CONFIRM_IDENTITY" =~ ^[A-Za-z0-9._:@+-]{1,256}$ ]] \
    || { echo "--confirm-identity must be a valid persistent cache identity" >&2; return 2; }
  [ "$CONFIRM_IDENTITY" = "$KV_OFFLOAD_CACHE_IDENTITY" ] \
    || { echo "confirmed identity does not match KV_OFFLOAD_CACHE_IDENTITY" >&2; return 2; }
  case "${KV_OFFLOAD_MODE:-off}" in
    nvme-persistent|off) ;;
    *)
      echo "purge requires KV_OFFLOAD_MODE=nvme-persistent or an off-mode rollback env" >&2
      return 2
      ;;
  esac
  command -v "$DOCKER_BIN" >/dev/null 2>&1 \
    || { echo "docker command is unavailable: $DOCKER_BIN" >&2; return 2; }
  command -v "$SSH_BIN" >/dev/null 2>&1 \
    || { echo "ssh command is unavailable: $SSH_BIN" >&2; return 2; }
  command -v "$SYNC_BIN" >/dev/null 2>&1 \
    || { echo "sync command is unavailable: $SYNC_BIN" >&2; return 2; }

  local root
  for root in "$KV_OFFLOAD_ROOT" "$WORKER_KV_OFFLOAD_ROOT"; do
    valid_root_syntax "$root" \
      || { echo "refusing unsafe persistent KV root" >&2; return 2; }
  done
  KV_OFFLOAD_ROOT="${KV_OFFLOAD_ROOT%/}"
  WORKER_KV_OFFLOAD_ROOT="${WORKER_KV_OFFLOAD_ROOT%/}"
}

remote_run() {
  local command="$1"
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_HOST" "$command"
}

project_container_query() {
  local project="$1"
  cat <<EOF
{
  docker ps -aq --filter 'label=com.docker.compose.project=$project' \
    --filter 'label=com.docker.compose.service=vllm-dspark' 2>/dev/null || true
  docker ps -aq --filter 'name=^/${project}-vllm-dspark-1\$' 2>/dev/null || true
} | awk 'NF' | sort -u
EOF
}

ensure_no_project_container() {
  local where="$1"
  local query
  local ids
  query="$(project_container_query "$PROJECT_NAME")"
  if [ "$where" = head ]; then
    ids="$(bash -c "$query")"
  else
    ids="$(remote_run "$query")"
  fi
  if [ -n "$ids" ]; then
    echo "refusing purge: ${where} still has a container for project ${PROJECT_NAME}" >&2
    return 1
  fi
  echo "preflight ${where}: exact project has zero running/stopped KV containers"
}

root_preflight_command() {
  local root="$1"
  local quoted_root
  printf -v quoted_root '%q' "$root"
  cat <<EOF
root=${quoted_root}
if [ ! -e "\$root" ]; then
  echo absent
  exit 0
fi
[ -d "\$root" ] && [ ! -L "\$root" ] || {
  echo 'persistent KV root is not a non-symlink directory' >&2
  exit 1
}
lexical=\$(realpath -ms -- "\$root") || exit 1
physical=\$(realpath -m -- "\$root") || exit 1
[ "\$lexical" = "\$root" ] && [ "\$physical" = "\$lexical" ] || {
  echo 'persistent KV root is non-canonical or traverses a symlink' >&2
  exit 1
}
echo present
EOF
}

node_root_state() {
  local where="$1"
  local root="$2"
  local command
  command="$(root_preflight_command "$root")"
  if [ "$where" = head ]; then
    bash -c "$command"
  else
    remote_run "$command"
  fi
}

read -r -d '' METADATA_CHECK_PY <<'PY' || true
import hashlib
import json
import os
import stat
import struct
import sys

root = sys.argv[1]
rank = int(sys.argv[2])
expected_identity = sys.argv[3]
allow_unverified = sys.argv[4] == "1"
prefix = "vllm-kv.slots"
data_name = f"{prefix}.rank_{rank}"
metadata_names = [f"{data_name}.meta"]
if rank == 0:
    metadata_names.append(f"{prefix}.index")
all_names = [data_name, *metadata_names]

existing = []
for name in all_names:
    path = os.path.join(root, name)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        continue
    if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o600:
        raise SystemExit(f"unsafe persistent artifact type/mode: {name}")
    if st.st_nlink != 1:
        raise SystemExit(f"unsafe persistent artifact link count: {name}")
    existing.append(name)

manifest_name = metadata_names[0]
if data_name in existing and manifest_name not in existing:
    if allow_unverified:
        print(f"WARN: {data_name} has no manifest; explicit unverified recovery enabled")
    else:
        raise SystemExit(f"persistent data has no identity-bearing manifest: {data_name}")

for name in metadata_names:
    if name not in existing:
        continue
    path = os.path.join(root, name)
    try:
        with open(path, "rb", buffering=0) as handle:
            header = handle.read(4096)
        if len(header) != 4096:
            raise ValueError("short header")
        magic, version, length, digest = struct.unpack(">8sII32s", header[:48])
        if magic != b"VKVPM001" or version != 1 or not 0 < length <= 4048:
            raise ValueError("invalid header prefix")
        payload = header[48 : 48 + length]
        if hashlib.sha256(payload).digest() != digest:
            raise ValueError("header digest mismatch")
        document = json.loads(payload.decode("ascii"))
        actual_identity = document["identity"]["cache_identity"]
    except Exception as error:
        if allow_unverified:
            print(f"WARN: cannot verify {name}: {error}; explicit recovery enabled")
            continue
        raise SystemExit(f"cannot verify persistent metadata {name}: {error}")
    if actual_identity != expected_identity:
        raise SystemExit(f"persistent metadata identity mismatch: {name}")

print("artifacts=" + (",".join(existing) if existing else "none"))
PY

metadata_preflight_command() {
  local root="$1"
  local rank="$2"
  local mount_spec="type=bind,src=${root},dst=/kv-offload-root,readonly"
  local q_docker q_mount q_image q_py q_rank q_identity q_allow
  printf -v q_docker '%q' "$DOCKER_BIN"
  printf -v q_mount '%q' "$mount_spec"
  printf -v q_image '%q' "$DSPARK_VLLM_IMAGE"
  printf -v q_py '%q' "$METADATA_CHECK_PY"
  printf -v q_rank '%q' "$rank"
  printf -v q_identity '%q' "$CONFIRM_IDENTITY"
  printf -v q_allow '%q' "$ALLOW_UNVERIFIED_METADATA"
  printf '%s run --rm --network none --read-only --entrypoint python3 --mount %s %s -c %s /kv-offload-root %s %s %s\n' \
    "$q_docker" "$q_mount" "$q_image" "$q_py" "$q_rank" "$q_identity" "$q_allow"
}

preflight_node() {
  local where="$1"
  local root="$2"
  local rank="$3"
  local state
  local command
  state="$(node_root_state "$where" "$root")"
  if [ "$state" = absent ]; then
    echo "preflight ${where}: root absent; no persistent artifacts"
    return 0
  fi
  [ "$state" = present ] || { echo "unexpected root state on ${where}" >&2; return 1; }
  command="$(metadata_preflight_command "$root" "$rank")"
  if [ "$where" = head ]; then
    bash -c "$command"
  else
    remote_run "$command"
  fi
  echo "preflight ${where}: artifact type, mode, link count and identity accepted"
}

delete_command() {
  local root="$1"
  shift
  local mount_spec="type=bind,src=${root},dst=/kv-offload-root"
  local q_docker q_mount q_image q_sync
  local name q_name
  local command
  printf -v q_docker '%q' "$DOCKER_BIN"
  printf -v q_mount '%q' "$mount_spec"
  printf -v q_image '%q' "$DSPARK_VLLM_IMAGE"
  printf -v q_sync '%q' "$root"
  command="${q_docker} run --rm --network none --entrypoint /bin/rm --mount ${q_mount} ${q_image} -f --"
  for name in "$@"; do
    [[ "$name" =~ ^vllm-kv\.slots(\.index|\.rank_[01](\.meta)?)$ ]] \
      || { echo "internal error: unsafe purge basename" >&2; return 1; }
    printf -v q_name '%q' "/kv-offload-root/${name}"
    command+=" ${q_name}"
  done
  command+=" && "
  printf -v q_docker '%q' "$SYNC_BIN"
  command+="${q_docker} -f -- ${q_sync}"
  printf '%s\n' "$command"
}

delete_node_files() {
  local where="$1"
  local root="$2"
  shift 2
  local state
  local command
  state="$(node_root_state "$where" "$root")"
  [ "$state" = present ] || return 0
  command="$(delete_command "$root" "$@")"
  if [ "$where" = head ]; then
    bash -c "$command"
  else
    remote_run "$command"
  fi
  echo "purge ${where}: removed $*"
}

verify_node_absent() {
  local where="$1"
  local root="$2"
  local rank="$3"
  local q_root
  local command
  printf -v q_root '%q' "$root"
  command=$(cat <<EOF
root=${q_root}
for name in vllm-kv.slots.rank_${rank} vllm-kv.slots.rank_${rank}.meta $([ "$rank" = 0 ] && printf %s vllm-kv.slots.index); do
  if [ -e "\$root/\$name" ] || [ -L "\$root/\$name" ]; then
    echo "persistent artifact remains: \$name" >&2
    exit 1
  fi
done
EOF
)
  if [ "$where" = head ]; then
    bash -c "$command"
  else
    remote_run "$command"
  fi
  echo "verify ${where}: persistent artifacts absent"
}

main() {
  local parse_status
  parse_args "$@" || {
    parse_status=$?
    [ "$parse_status" = 64 ] && return 0
    return "$parse_status"
  }
  configure || return
  remote_run true >/dev/null || return

  # Phase 1: nothing is deleted until both nodes and both metadata sets pass.
  ensure_no_project_container head || return
  ensure_no_project_container worker || return
  preflight_node head "$KV_OFFLOAD_ROOT" 0 || return
  preflight_node worker "$WORKER_KV_OFFLOAD_ROOT" 1 || return

  if [ "$EXECUTE" != 1 ]; then
    echo "DRY RUN: both-node preflight passed; rerun with --execute to purge identity ${CONFIRM_IDENTITY}"
    return 0
  fi

  # Phase 2: remove the scheduler authority first.  A later partial failure can
  # leave orphan rank rows but can no longer publish a restart-visible hit.
  delete_node_files head "$KV_OFFLOAD_ROOT" vllm-kv.slots.index || return
  delete_node_files worker "$WORKER_KV_OFFLOAD_ROOT" \
    vllm-kv.slots.rank_1.meta vllm-kv.slots.rank_1 || return
  delete_node_files head "$KV_OFFLOAD_ROOT" \
    vllm-kv.slots.rank_0.meta vllm-kv.slots.rank_0 || return

  verify_node_absent worker "$WORKER_KV_OFFLOAD_ROOT" 1 || return
  verify_node_absent head "$KV_OFFLOAD_ROOT" 0 || return
  echo "Persistent KV purge complete for project ${PROJECT_NAME} and identity ${CONFIRM_IDENTITY}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
