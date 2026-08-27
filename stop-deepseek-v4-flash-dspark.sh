#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.dspark.yml}"
SIDECAR_COMPOSE_FILE="${SIDECAR_COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.vl-sidecar.yml}"
PROJECT_NAME="${PROJECT_NAME:-deepseek-v4-flash}"
LEGACY_PROJECT_NAME="${LEGACY_PROJECT_NAME:-$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]')}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE or environment}"

cd "$SCRIPT_DIR"

WORKER_DIR="${WORKER_SCRIPT_DIR:-${WORKER_DIR:-$SCRIPT_DIR}}"
WORKER_HF_CACHE="${WORKER_HF_CACHE:-${HF_CACHE:-}}"
WORKER_VLLM_HOST_IP="${WORKER_VLLM_HOST_IP:-}"

# A stop that cannot reach the worker must not report success: a powered-down
# worker resurrects its stale rank (compose restart: unless-stopped) the next
# time it boots, and nothing here will have stopped it. Mirror start's ssh
# hardening (BatchMode/ConnectTimeout) so stop never hangs on a prompt either.
STOP_FAILURES=0
HEAD_MMAP_PATHS=()
WORKER_MMAP_PATHS=()
stop_warn() {
  echo "WARN: $*" >&2
  STOP_FAILURES=$((STOP_FAILURES + 1))
}

# SimpleCPUOffloadConnector allocates a named mmap in host IPC. Graceful
# shutdown unlinks it, but docker rm -f cannot run Python cleanup. Capture only
# the exact files opened by this project's vLLM container before removal, then
# remove only those captured paths after the ranks have stopped.
valid_offload_mmap_path() {
  [[ "$1" =~ ^/dev/shm/vllm_offload_[A-Za-z0-9._-]+\.mmap$ ]]
}

remember_offload_mmap_path() {
  local where="$1"
  local path="$2"
  local existing
  local -n paths_ref

  if ! valid_offload_mmap_path "$path"; then
    stop_warn "refusing unexpected KV mmap path from ${where}: ${path}"
    return 0
  fi
  if [ "$where" = "head" ]; then
    paths_ref=HEAD_MMAP_PATHS
  else
    paths_ref=WORKER_MMAP_PATHS
  fi
  for existing in "${paths_ref[@]}"; do
    [ "$existing" = "$path" ] && return 0
  done
  paths_ref+=("$path")
}

mmap_capture_command() {
  local project="$1"
  cat <<EOF
ids=\$(
  {
    docker ps -q --filter 'label=com.docker.compose.project=$project' 2>/dev/null || true
    docker ps -q --filter 'name=${project}-vllm-dspark' 2>/dev/null || true
  } | awk 'NF' | sort -u
)
for cid in \$ids; do
  docker exec "\$cid" sh -c '
    for fd in /proc/[0-9]*/fd/*; do
      [ -L "\$fd" ] || continue
      target=\$(readlink "\$fd" 2>/dev/null || true)
      case "\$target" in
        /dev/shm/vllm_offload_*.mmap) printf "%s\\n" "\$target" ;;
      esac
    done
  ' 2>/dev/null || true
done
EOF
}

capture_project_mmaps() {
  local project="$1"
  local where="$2" # local | remote
  local path
  local cmd
  local output
  cmd="$(mmap_capture_command "$project")"

  if [ "$where" = "local" ]; then
    output="$(bash -c "$cmd")"
    while IFS= read -r path; do
      [ -n "$path" ] && remember_offload_mmap_path head "$path"
    done < <(printf '%s\n' "$output" | sort -u)
  elif [ "${WORKER_REACHABLE:-1}" = "1" ]; then
    if ! output="$(ssh "$WORKER_HOST" "$cmd")"; then
      stop_warn "failed to capture worker KV mmap paths on ${WORKER_HOST}"
      return 0
    fi
    while IFS= read -r path; do
      [ -n "$path" ] && remember_offload_mmap_path worker "$path"
    done < <(printf '%s\n' "$output" | sort -u)
  fi
}

remove_captured_mmaps() {
  local where="$1" # local | remote
  shift
  local path
  local quoted_path
  local quoted_image

  for path in "$@"; do
    if ! valid_offload_mmap_path "$path"; then
      stop_warn "refusing unexpected captured KV mmap path on ${where}: ${path}"
      continue
    fi
    if [ "$where" = "local" ]; then
      docker run --rm --ipc=host --entrypoint /bin/rm \
        "$DSPARK_VLLM_IMAGE" -f -- "$path" \
        || stop_warn "failed to remove captured head KV mmap ${path}"
    elif [ "${WORKER_REACHABLE:-1}" = "1" ]; then
      printf -v quoted_path '%q' "$path"
      printf -v quoted_image '%q' "$DSPARK_VLLM_IMAGE"
      ssh "$WORKER_HOST" \
        "docker run --rm --ipc=host --entrypoint /bin/rm ${quoted_image} -f -- ${quoted_path}" \
        || stop_warn "failed to remove captured worker KV mmap ${path}"
    fi
  done
}

valid_kv_offload_root() {
  local root="$1"
  [[ "$root" = /* && "$root" != *:* && "$root" != *,* \
    && "$root" != *$'\n'* && "$root" != *$'\r'* ]]
}

remove_nvme_slot() {
  local where="$1" # local | remote
  local root="$2"
  local rank="$3"
  local slot="vllm-kv.slots.rank_${rank}"
  local quoted_root
  local quoted_image

  if ! valid_kv_offload_root "$root"; then
    stop_warn "refusing unsafe ${where} KV_OFFLOAD_ROOT: ${root}"
    return 0
  fi
  if [ "$where" = "local" ]; then
    [ -d "$root" ] || return 0
    docker run --rm --entrypoint /bin/rm \
      --mount "type=bind,src=${root},dst=/kv-offload-root" \
      "$DSPARK_VLLM_IMAGE" -f -- "/kv-offload-root/${slot}" \
      || stop_warn "failed to remove head NVMe slot ${root}/${slot}"
  elif [ "${WORKER_REACHABLE:-1}" = "1" ]; then
    printf -v quoted_root '%q' "$root"
    printf -v quoted_image '%q' "$DSPARK_VLLM_IMAGE"
    ssh "$WORKER_HOST" \
      "if [ -d ${quoted_root} ]; then docker run --rm --entrypoint /bin/rm --mount type=bind,src=${quoted_root},dst=/kv-offload-root ${quoted_image} -f -- /kv-offload-root/${slot}; fi" \
      || stop_warn "failed to remove worker NVMe slot ${root}/${slot}"
  fi
}

cleanup_kv_offload_artifacts() {
  remove_captured_mmaps local "${HEAD_MMAP_PATHS[@]}"
  if [ "${WORKER_REACHABLE:-1}" = "1" ]; then
    remove_captured_mmaps remote "${WORKER_MMAP_PATHS[@]}"
  fi

  if [ "${KV_OFFLOAD_MODE:-off}" = "nvme-local" ]; then
    remove_nvme_slot local "${KV_OFFLOAD_ROOT:-${HOME}/.cache/dspark-kv-offload}" 0
    if [ "${WORKER_REACHABLE:-1}" = "1" ]; then
      remove_nvme_slot remote \
        "${WORKER_KV_OFFLOAD_ROOT:-${KV_OFFLOAD_ROOT:-${HOME}/.cache/dspark-kv-offload}}" 1
    fi
  fi
}

# After docker rm -f, compose down often has nothing left and prints
# "No resource found to remove for project …" — noise, not a failure.
filter_compose_empty_project() {
  grep -v 'No resource found to remove for project' || true
}
detect_worker_reachable() {
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_HOST" "true" >/dev/null 2>&1; then
    WORKER_REACHABLE=1
  else
    WORKER_REACHABLE=0
    echo "WARN: cannot reach worker ${WORKER_HOST}; its ranks will NOT be stopped." >&2
  fi
}

local_project_has_resources() {
  local project="$1"
  {
    docker ps -aq --filter "label=com.docker.compose.project=$project"
    docker network ls -q --filter "label=com.docker.compose.project=$project"
    docker volume ls -q --filter "label=com.docker.compose.project=$project"
  } | grep -q .
}

# Force-remove VL / 0731 containers by compose project label + known names.
# Used when compose down misses a service (e.g. worker missing vl-sidecar.yml).
force_rm_project_containers() {
  local project="$1"
  local where="$2" # local | remote
  local cmd
  cmd=$(cat <<EOF
ids=\$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
names=\$(docker ps -aq --filter "name=${project}-vl-sidecar" --filter "name=${project}-vllm-dspark" 2>/dev/null || true)
all=\$(printf '%s\n%s\n' "\$ids" "\$names" | awk 'NF' | sort -u)
if [ -n "\$all" ]; then
  echo "Force-removing containers for project $project..."
  # shellcheck disable=SC2086
  docker rm -f \$all >/dev/null 2>&1 || true
fi
EOF
)
  if [ "$where" = "local" ]; then
    bash -c "$cmd" || true
  elif [ "${WORKER_REACHABLE:-1}" = "1" ]; then
    ssh "$WORKER_HOST" "$cmd" || stop_warn "force-remove on ${WORKER_HOST} failed"
  fi
}

stop_vl_sidecar_head() {
  local project="$1"
  # Text-only ship: skip noisy VL down when nothing is running.
  if [ "${ENABLE_VL_SIDECAR:-0}" != "1" ] \
    && ! docker ps -aq --filter "name=${project}-vl-sidecar" | grep -q .; then
    return 0
  fi
  if [ ! -f "$SIDECAR_COMPOSE_FILE" ]; then
    echo "No $SIDECAR_COMPOSE_FILE on head; force-removing any VL containers..."
    force_rm_project_containers "$project" local
    return 0
  fi
  echo "Stopping VL vision sidecar on head (project ${project})..."
  # NODE_RANK required for compose file interpolation; value unused for down.
  COMPOSE_DISABLE_ENV_FILE=1 NODE_RANK=0 \
    docker compose -p "$project" --env-file "$ENV_FILE" -f "$SIDECAR_COMPOSE_FILE" down 2>&1 \
    | filter_compose_empty_project || true
  # Belt-and-suspenders: name filter in case compose project label drifted.
  docker ps -aq --filter "name=${project}-vl-sidecar" | xargs -r docker rm -f >/dev/null 2>&1 || true
}

stop_vl_sidecar_worker() {
  local project="$1"
  if [ "${WORKER_REACHABLE:-1}" != "1" ]; then
    stop_warn "worker ${WORKER_HOST} unreachable: VL sidecar worker rank not stopped"
    return 0
  fi
  # Text-only: still sweep if a zombie VL exists; otherwise skip SSH noise.
  local worker_has_vl=0
  if ssh "$WORKER_HOST" "docker ps -aq --filter 'name=${project}-vl-sidecar' 2>/dev/null | grep -q ."; then
    worker_has_vl=1
  fi
  if [ "${ENABLE_VL_SIDECAR:-0}" != "1" ] && [ "$worker_has_vl" != "1" ]; then
    return 0
  fi
  # Ensure worker has the compose file so `down` can target the VL service.
  if [ -f "$SIDECAR_COMPOSE_FILE" ]; then
    ssh "$WORKER_HOST" "mkdir -p '$WORKER_DIR'" || true
    scp -q "$SIDECAR_COMPOSE_FILE" "${WORKER_HOST}:${WORKER_DIR}/docker-compose.vl-sidecar.yml" || true
    scp -q "$ENV_FILE" "${WORKER_HOST}:${WORKER_DIR}/.env.dspark" || true
  fi
  echo "Stopping VL vision sidecar on worker ${WORKER_HOST} (project ${project})..."
  ssh "$WORKER_HOST" "
    cd '$WORKER_DIR' || exit 0
    if [ -f docker-compose.vl-sidecar.yml ]; then
      env -u MASTER_ADDR -u MASTER_PORT -u HEADLESS \
        COMPOSE_DISABLE_ENV_FILE=1 NODE_RANK=1 HEADLESS=1 \
        HF_CACHE='$WORKER_HF_CACHE' VLLM_HOST_IP='$WORKER_VLLM_HOST_IP' \
        docker compose -p '$project' --env-file .env.dspark \
          -f docker-compose.vl-sidecar.yml down 2>&1 \
          | grep -v 'No resource found to remove for project' || true
    fi
    ids=\$(docker ps -aq --filter 'name=${project}-vl-sidecar' 2>/dev/null || true)
    if [ -n \"\$ids\" ]; then docker rm -f \$ids >/dev/null 2>&1 || true; fi
  " || stop_warn "VL sidecar worker stop failed on ${WORKER_HOST}"
}

stop_main_head() {
  local project="$1"
  if local_project_has_resources "$project" || docker ps -aq --filter "name=${project}-vllm-dspark" | grep -q .; then
    echo "Stopping DSpark 0731 on head (project ${project})..."
    # rm -f first: compose down can still wait on stop_grace_period.
    docker ps -aq --filter "name=${project}-vllm-dspark" | xargs -r docker rm -f >/dev/null 2>&1 || true
    COMPOSE_DISABLE_ENV_FILE=1 NODE_RANK=0 \
      docker compose -p "$project" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down --remove-orphans -t 1 2>&1 \
      | filter_compose_empty_project || true
  else
    echo "No DSpark 0731 head resources for project ${project}; skipping."
  fi
}

stop_main_worker() {
  local project="$1"
  if [ "${WORKER_REACHABLE:-1}" != "1" ]; then
    stop_warn "worker ${WORKER_HOST} unreachable: main DSpark worker rank not stopped"
    return 0
  fi
  ssh "$WORKER_HOST" "
    cd '$WORKER_DIR' || exit 1
    if {
      docker ps -aq --filter 'label=com.docker.compose.project=$project'
      docker network ls -q --filter 'label=com.docker.compose.project=$project'
      docker volume ls -q --filter 'label=com.docker.compose.project=$project'
      docker ps -aq --filter 'name=${project}-vllm-dspark'
    } | grep -q .; then
      echo 'Stopping DSpark 0731 on worker $WORKER_HOST (project $project)...'
      docker ps -aq --filter 'name=${project}-vllm-dspark' | xargs -r docker rm -f >/dev/null 2>&1 || true
      env -u MASTER_ADDR -u MASTER_PORT -u NODE_RANK -u HEADLESS \
        COMPOSE_DISABLE_ENV_FILE=1 HF_CACHE='$WORKER_HF_CACHE' \
        VLLM_HOST_IP='$WORKER_VLLM_HOST_IP' NODE_RANK=1 HEADLESS=1 \
        docker compose -p '$project' --env-file .env.dspark \
          -f docker-compose.dspark.yml down --remove-orphans -t 1 2>&1 \
          | grep -v 'No resource found to remove for project' || true
    else
      echo 'No DSpark 0731 worker resources for project $project on $WORKER_HOST; skipping.'
    fi
  " || stop_warn "main DSpark worker stop failed on ${WORKER_HOST}"
}

stop_project() {
  local project="$1"

  capture_project_mmaps "$project" local
  capture_project_mmaps "$project" remote

  # Vision first so a failed main down cannot leave Qwen occupying VRAM.
  stop_vl_sidecar_head "$project"
  stop_vl_sidecar_worker "$project"

  stop_main_head "$project"
  stop_main_worker "$project"

  # Sweep anything left under this compose project on both nodes.
  force_rm_project_containers "$project" local
  force_rm_project_containers "$project" remote
}

main() {
  detect_worker_reachable

  stop_project "$PROJECT_NAME"
  if [ "$LEGACY_PROJECT_NAME" != "$PROJECT_NAME" ]; then
    stop_project "$LEGACY_PROJECT_NAME"
  fi

  cleanup_kv_offload_artifacts

  if [ "$STOP_FAILURES" -gt 0 ]; then
    echo "WARN: $STOP_FAILURES stop/cleanup step(s) failed; a stale rank or KV artifact may remain. Re-run ./stop-deepseek-v4-flash-dspark.sh once both nodes are reachable." >&2
    return 1
  fi

  if [ "${ENABLE_VL_SIDECAR:-0}" = "1" ]; then
    echo "DeepSeek V4 Flash DSpark stopped (0731 + VL vision sidecar)."
  else
    echo "DeepSeek V4 Flash DSpark stopped (0731 text-only; any leftover VL sidecar swept)."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
