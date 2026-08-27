#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: guard-kv-offload-node.sh --output DIR [options]

Per-node safety circuit breaker for one isolated KV-offload Compose project.
It stops only the exact running project container after a numeric host-memory
or exposed-temperature threshold persists.  An optional peer host receives the
same exact-project stop so a TP rank cannot spin after its peer is removed.

Options:
  --output DIR              new or empty private output directory (required)
  --project NAME            compose project, default kv-offload-step06
  --interval SEC            seconds between samples, default 2
  --samples COUNT           finite maximum samples, default 1800
  --min-available-kib KIB   low-memory threshold, default 12582912 (12 GiB)
  --max-temp-millic MC      high-temperature threshold, default 90000
  --consecutive COUNT       consecutive breaches required, default 3
  --stop-timeout SEC        Docker graceful-stop timeout, default 20
  --peer-host HOST          optional TP peer to stop for the same project
  -h, --help                show this help

A safety trigger exits 42 after stopping the exact container (or immediately
when no project container exists). Operational/configuration failures exit
nonzero with a different status.
EOF
}

OUTPUT_DIR=
PROJECT_NAME=kv-offload-step06
INTERVAL_SECONDS=2
MAX_SAMPLES=1800
MIN_AVAILABLE_KIB=12582912
MAX_TEMP_MILLIC=90000
CONSECUTIVE_BREACHES=3
STOP_TIMEOUT_SECONDS=20
PEER_HOST=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || { echo "--output requires a value" >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --project) [ "$#" -ge 2 ] || { echo "--project requires a value" >&2; exit 2; }; PROJECT_NAME="$2"; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || { echo "--interval requires a value" >&2; exit 2; }; INTERVAL_SECONDS="$2"; shift 2 ;;
    --samples) [ "$#" -ge 2 ] || { echo "--samples requires a value" >&2; exit 2; }; MAX_SAMPLES="$2"; shift 2 ;;
    --min-available-kib) [ "$#" -ge 2 ] || { echo "--min-available-kib requires a value" >&2; exit 2; }; MIN_AVAILABLE_KIB="$2"; shift 2 ;;
    --max-temp-millic) [ "$#" -ge 2 ] || { echo "--max-temp-millic requires a value" >&2; exit 2; }; MAX_TEMP_MILLIC="$2"; shift 2 ;;
    --consecutive) [ "$#" -ge 2 ] || { echo "--consecutive requires a value" >&2; exit 2; }; CONSECUTIVE_BREACHES="$2"; shift 2 ;;
    --stop-timeout) [ "$#" -ge 2 ] || { echo "--stop-timeout requires a value" >&2; exit 2; }; STOP_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --peer-host) [ "$#" -ge 2 ] || { echo "--peer-host requires a value" >&2; exit 2; }; PEER_HOST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$OUTPUT_DIR" ] || { echo "--output is required" >&2; exit 2; }
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || { echo "--project contains unsupported characters" >&2; exit 2; }
if [ -n "$PEER_HOST" ] && ! [[ "$PEER_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
  echo "--peer-host contains unsupported characters" >&2
  exit 2
fi
for numeric_name in INTERVAL_SECONDS MAX_SAMPLES MIN_AVAILABLE_KIB \
  MAX_TEMP_MILLIC CONSECUTIVE_BREACHES STOP_TIMEOUT_SECONDS; do
  numeric_value="${!numeric_name}"
  [[ "$numeric_value" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$numeric_name must be a positive integer" >&2; exit 2; }
done

DOCKER_BIN="${KV_GUARD_DOCKER_BIN:-docker}"
SLEEP_BIN="${KV_GUARD_SLEEP_BIN:-sleep}"
SYNC_BIN="${KV_GUARD_SYNC_BIN:-sync}"
SSH_BIN="${KV_GUARD_SSH_BIN:-ssh}"
MEMINFO_PATH="${KV_GUARD_MEMINFO_PATH:-/proc/meminfo}"
THERMAL_ROOT="${KV_GUARD_THERMAL_ROOT:-/sys/class/thermal}"
command -v "$DOCKER_BIN" >/dev/null 2>&1 \
  || { echo "docker command is unavailable: $DOCKER_BIN" >&2; exit 2; }
if [ -n "$PEER_HOST" ]; then
  command -v "$SSH_BIN" >/dev/null 2>&1 \
    || { echo "ssh command is unavailable: $SSH_BIN" >&2; exit 2; }
fi
[ -r "$MEMINFO_PATH" ] || { echo "meminfo is unreadable: $MEMINFO_PATH" >&2; exit 2; }

umask 077
if [ -e "$OUTPUT_DIR" ] \
  && [ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "output directory must be new or empty: $OUTPUT_DIR" >&2
  exit 2
fi
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
SAMPLES_FILE="$OUTPUT_DIR/guard-samples.tsv"
ACTION_LOG="$OUTPUT_DIR/action.log"
START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TRIGGER_REASON=none
STOP_RESULT=not_attempted
PEER_STOP_RESULT=not_configured
printf '%s\n' \
  $'timestamp_utc\tmem_available_kib\tmax_temp_millic\tcontainer_id\tlow_mem_count\thigh_temp_count\taction' \
  > "$SAMPLES_FILE"
: > "$ACTION_LOG"

sync_file() {
  "$SYNC_BIN" -d "$1" >/dev/null 2>&1 \
    || "$SYNC_BIN" "$1" >/dev/null 2>&1 \
    || true
}
sync_file "$SAMPLES_FILE"

finish() {
  local status=$?
  journalctl -k --since "$START_UTC" --no-pager -o short-precise \
    > "$OUTPUT_DIR/kernel-during-guard.txt" 2>&1 || true
  {
    printf 'start_utc=%s\n' "$START_UTC"
    printf 'finish_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'exit_status=%s\n' "$status"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'project=%s\n' "$PROJECT_NAME"
    printf 'min_available_kib=%s\n' "$MIN_AVAILABLE_KIB"
    printf 'max_temp_millic=%s\n' "$MAX_TEMP_MILLIC"
    printf 'consecutive_breaches=%s\n' "$CONSECUTIVE_BREACHES"
    printf 'trigger_reason=%s\n' "$TRIGGER_REASON"
    printf 'stop_result=%s\n' "$STOP_RESULT"
    printf 'peer_host=%s\n' "$PEER_HOST"
    printf 'peer_stop_result=%s\n' "$PEER_STOP_RESULT"
  } > "$OUTPUT_DIR/run.meta"
  sync_file "$OUTPUT_DIR/run.meta"
  sync_file "$ACTION_LOG"
  find "$OUTPUT_DIR" -maxdepth 1 -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z | xargs -0 sha256sum > "$OUTPUT_DIR/MANIFEST.sha256"
  sync_file "$OUTPUT_DIR/MANIFEST.sha256"
  chmod 600 "$OUTPUT_DIR"/*
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

max_temperature() {
  local zone
  local value
  local maximum=0
  for zone in "$THERMAL_ROOT"/thermal_zone*/temp; do
    [ -r "$zone" ] || continue
    value="$(cat "$zone" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+$ ]] || continue
    [ "$value" -gt "$maximum" ] && maximum="$value"
  done
  printf '%s\n' "$maximum"
}

project_containers() {
  "$DOCKER_BIN" ps -q \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=vllm-dspark" \
    2>/dev/null | awk 'NF' | sort -u
}

stop_exact_container() {
  local container_id="$1"
  local exit_code
  local running
  printf '%s stopping exact container %s for project %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$container_id" "$PROJECT_NAME" \
    >> "$ACTION_LOG"
  sync_file "$ACTION_LOG"
  if timeout "$((STOP_TIMEOUT_SECONDS + 10))" \
    "$DOCKER_BIN" stop --timeout "$STOP_TIMEOUT_SECONDS" "$container_id" \
    >> "$ACTION_LOG" 2>&1; then
    exit_code="$($DOCKER_BIN inspect --format '{{.State.ExitCode}}' \
      "$container_id" 2>/dev/null || true)"
    if [ "$exit_code" = 137 ]; then
      STOP_RESULT=timed_kill
    else
      STOP_RESULT=graceful_stop
    fi
  else
    printf '%s graceful stop failed; issuing exact-container kill\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ACTION_LOG"
    sync_file "$ACTION_LOG"
    if timeout 10 "$DOCKER_BIN" kill "$container_id" \
      >> "$ACTION_LOG" 2>&1; then
      STOP_RESULT=forced_kill
    else
      STOP_RESULT=stop_failed
      return 1
    fi
  fi
  running="$($DOCKER_BIN inspect --format '{{.State.Running}}' \
    "$container_id" 2>/dev/null || true)"
  [ "$running" = false ] || { STOP_RESULT=still_running; return 1; }
  return 0
}

stop_peer_project() {
  local remote_command

  [ -n "$PEER_HOST" ] || return 0
  printf '%s stopping peer project %s on %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROJECT_NAME" "$PEER_HOST" \
    >> "$ACTION_LOG"
  sync_file "$ACTION_LOG"
  remote_command=$(cat <<EOF
set -uo pipefail
mapfile -t ids < <(docker ps -q \\
  --filter 'label=com.docker.compose.project=$PROJECT_NAME' \\
  --filter 'label=com.docker.compose.service=vllm-dspark' 2>/dev/null | awk 'NF' | sort -u)
if [ "\${#ids[@]}" -gt 1 ]; then
  echo 'multiple peer containers match exact project' >&2
  exit 2
fi
cid="\${ids[0]:-}"
[ -n "\$cid" ] || exit 0
[[ "\$cid" =~ ^[a-f0-9]{12,64}$ ]] || exit 2
if ! timeout $((STOP_TIMEOUT_SECONDS + 10)) docker stop --timeout $STOP_TIMEOUT_SECONDS "\$cid"; then
  timeout 10 docker kill "\$cid"
fi
[ "\$(docker inspect --format '{{.State.Running}}' "\$cid" 2>/dev/null || true)" = false ]
EOF
)
  if timeout "$((STOP_TIMEOUT_SECONDS + 25))" \
    "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=10 "$PEER_HOST" \
    "$remote_command" >> "$ACTION_LOG" 2>&1; then
    PEER_STOP_RESULT=stopped_or_absent
    return 0
  fi
  PEER_STOP_RESULT=stop_failed
  return 1
}

low_mem_count=0
high_temp_count=0
for ((sample = 0; sample < MAX_SAMPLES; sample++)); do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mem_available="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$MEMINFO_PATH")"
  [[ "$mem_available" =~ ^[0-9]+$ ]] \
    || { echo "MemAvailable is missing or invalid" >&2; exit 2; }
  max_temp="$(max_temperature)"

  if [ "$mem_available" -lt "$MIN_AVAILABLE_KIB" ]; then
    low_mem_count=$((low_mem_count + 1))
  else
    low_mem_count=0
  fi
  if [ "$max_temp" -gt 0 ] && [ "$max_temp" -ge "$MAX_TEMP_MILLIC" ]; then
    high_temp_count=$((high_temp_count + 1))
  else
    high_temp_count=0
  fi

  mapfile -t container_ids < <(project_containers)
  if [ "${#container_ids[@]}" -gt 1 ]; then
    echo "multiple running containers match exact project: ${container_ids[*]}" >&2
    exit 2
  fi
  container_id="${container_ids[0]:-}"
  if [ -n "$container_id" ] && ! [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]]; then
    echo "invalid container ID returned for exact project" >&2
    exit 2
  fi

  action=none
  if [ "$low_mem_count" -ge "$CONSECUTIVE_BREACHES" ]; then
    TRIGGER_REASON=low_memory
    action=trigger_low_memory
  elif [ "$high_temp_count" -ge "$CONSECUTIVE_BREACHES" ]; then
    TRIGGER_REASON=high_temperature
    action=trigger_high_temperature
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$timestamp" "$mem_available" "$max_temp" "$container_id" \
    "$low_mem_count" "$high_temp_count" "$action" >> "$SAMPLES_FILE"
  sync_file "$SAMPLES_FILE"

  if [ "$TRIGGER_REASON" != none ]; then
    action_failed=0
    if [ -n "$container_id" ]; then
      stop_exact_container "$container_id" \
        || action_failed=1
    else
      STOP_RESULT=no_container
    fi
    stop_peer_project || action_failed=1
    if [ "$action_failed" -ne 0 ]; then
      echo "failed to stop one or more exact unsafe TP containers" >&2
      exit 1
    fi
    echo "safety trigger: $TRIGGER_REASON ($STOP_RESULT)" >&2
    exit 42
  fi

  if [ "$sample" -lt $((MAX_SAMPLES - 1)) ]; then
    "$SLEEP_BIN" "$INTERVAL_SECONDS"
  fi
done

printf 'Guard completed without a safety trigger: %s\n' "$OUTPUT_DIR"
