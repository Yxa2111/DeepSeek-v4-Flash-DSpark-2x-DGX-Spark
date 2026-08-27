#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: sample-kv-offload-telemetry.sh --output DIR [options]

Read-only per-node sampler for a running KV offload stress test.

Options:
  --output DIR       new or empty private output directory (required)
  --project NAME     compose project, default kv-offload-step05
  --interval SEC     seconds between samples, default 5
  --samples COUNT    maximum samples, default 720
  -h, --help         show this help
EOF
}

OUTPUT_DIR=
PROJECT_NAME=kv-offload-step05
INTERVAL_SECONDS=5
MAX_SAMPLES=720
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || { echo "--output requires a value" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] || { echo "--project requires a value" >&2; exit 2; }
      PROJECT_NAME="$2"
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || { echo "--interval requires a value" >&2; exit 2; }
      INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --samples)
      [ "$#" -ge 2 ] || { echo "--samples requires a value" >&2; exit 2; }
      MAX_SAMPLES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$OUTPUT_DIR" ] || { echo "--output is required" >&2; exit 2; }
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || { echo "--project contains unsupported characters" >&2; exit 2; }
[[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "--interval must be a positive integer" >&2; exit 2; }
[[ "$MAX_SAMPLES" =~ ^[1-9][0-9]*$ ]] \
  || { echo "--samples must be a positive integer" >&2; exit 2; }

umask 077
if [ -e "$OUTPUT_DIR" ] && [ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "output directory must be new or empty: $OUTPUT_DIR" >&2
  exit 2
fi
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

SAMPLES_FILE="$OUTPUT_DIR/samples.tsv"
START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' \
  $'timestamp_utc\tepoch\tmem_available_kib\tswap_free_kib\tload1\tpsi_mem_some_avg10\tpsi_mem_full_avg10\tcontainer_id\tpid\tcgroup_memory_current\tcgroup_memory_peak\tcgroup_oom\tcgroup_oom_kill\tio_rbytes\tio_wbytes\tio_rios\tio_wios\tmax_temp_millic\tgpu_temp_c\tgpu_util_percent\tgpu_power_w\tgpu_sm_clock_mhz' \
  > "$SAMPLES_FILE"
sync -d "$SAMPLES_FILE"

finish() {
  local status=$?
  journalctl -k --since "$START_UTC" --no-pager -o short-precise \
    > "$OUTPUT_DIR/kernel-during-run.txt" 2>&1 || true
  {
    printf 'start_utc=%s\n' "$START_UTC"
    printf 'finish_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'exit_status=%s\n' "$status"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'project=%s\n' "$PROJECT_NAME"
    printf 'interval_seconds=%s\n' "$INTERVAL_SECONDS"
    printf 'max_samples=%s\n' "$MAX_SAMPLES"
  } > "$OUTPUT_DIR/run.meta"
  find "$OUTPUT_DIR" -maxdepth 1 -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z | xargs -0 sha256sum > "$OUTPUT_DIR/MANIFEST.sha256"
  chmod 600 "$OUTPUT_DIR"/*
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

metric_from_psi() {
  local kind="$1"
  awk -v kind="$kind" '$1 == kind { for (i=2; i<=NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; exit } }' \
    /proc/pressure/memory 2>/dev/null
}

cgroup_event() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '$1 == key { print $2; exit }' "$file" 2>/dev/null
}

cgroup_io_total() {
  local file="$1"
  local key="$2"
  awk -v key="$key" '{ for (i=2; i<=NF; i++) { split($i, pair, "="); if (pair[1] == key) total += pair[2] } } END { print total + 0 }' \
    "$file" 2>/dev/null
}

max_temperature() {
  local zone
  local value
  local maximum=0
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$zone" ] || continue
    value="$(cat "$zone" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+$ ]] || continue
    [ "$value" -gt "$maximum" ] && maximum="$value"
  done
  printf '%s\n' "$maximum"
}

gpu_sample() {
  local row
  local gpu_temp=
  local gpu_util=
  local gpu_power=
  local gpu_clock=
  if command -v nvidia-smi >/dev/null 2>&1; then
    row="$(timeout 3 nvidia-smi \
      --query-gpu=temperature.gpu,utilization.gpu,power.draw,clocks.current.sm \
      --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
    if [ -n "$row" ]; then
      IFS=, read -r gpu_temp gpu_util gpu_power gpu_clock <<< "$row"
      gpu_temp="${gpu_temp//[[:space:]]/}"
      gpu_util="${gpu_util//[[:space:]]/}"
      gpu_power="${gpu_power//[[:space:]]/}"
      gpu_clock="${gpu_clock//[[:space:]]/}"
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$gpu_temp" "$gpu_util" "$gpu_power" "$gpu_clock"
}

for ((sample = 0; sample < MAX_SAMPLES; sample++)); do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"
  mem_available="$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)"
  swap_free="$(awk '$1 == "SwapFree:" { print $2 }' /proc/meminfo)"
  load1="$(awk '{ print $1 }' /proc/loadavg)"
  psi_some="$(metric_from_psi some)"
  psi_full="$(metric_from_psi full)"

  mapfile -t container_ids < <(
    {
      docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" \
        --filter "name=${PROJECT_NAME}-vllm-dspark" 2>/dev/null || true
      docker ps -q --filter "name=${PROJECT_NAME}-vllm-dspark" 2>/dev/null || true
    } | awk 'NF' | sort -u
  )
  if [ "${#container_ids[@]}" -eq 1 ] && [[ "${container_ids[0]}" =~ ^[a-f0-9]+$ ]]; then
    container_id="${container_ids[0]}"
    pid="$(docker inspect --format '{{.State.Pid}}' "$container_id" 2>/dev/null || true)"
  else
    container_id="${container_ids[*]:-}"
    pid=
  fi

  cgroup_root=
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$pid/cgroup" ]; then
    cgroup_path="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$pid/cgroup")"
    [ -n "$cgroup_path" ] && cgroup_root="/sys/fs/cgroup${cgroup_path}"
  fi

  memory_current=
  memory_peak=
  oom=
  oom_kill=
  io_rbytes=
  io_wbytes=
  io_rios=
  io_wios=
  if [ -n "$cgroup_root" ] && [ -d "$cgroup_root" ]; then
    memory_current="$(cat "$cgroup_root/memory.current" 2>/dev/null || true)"
    memory_peak="$(cat "$cgroup_root/memory.peak" 2>/dev/null || true)"
    oom="$(cgroup_event "$cgroup_root/memory.events" oom)"
    oom_kill="$(cgroup_event "$cgroup_root/memory.events" oom_kill)"
    io_rbytes="$(cgroup_io_total "$cgroup_root/io.stat" rbytes)"
    io_wbytes="$(cgroup_io_total "$cgroup_root/io.stat" wbytes)"
    io_rios="$(cgroup_io_total "$cgroup_root/io.stat" rios)"
    io_wios="$(cgroup_io_total "$cgroup_root/io.stat" wios)"
  fi

  gpu_values="$(gpu_sample)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$timestamp" "$epoch" "$mem_available" "$swap_free" "$load1" \
    "$psi_some" "$psi_full" "$container_id" "$pid" "$memory_current" \
    "$memory_peak" "$oom" "$oom_kill" "$io_rbytes" "$io_wbytes" \
    "$io_rios" "$io_wios" "$(max_temperature)" "$gpu_values" \
    >> "$SAMPLES_FILE"
  sync -d "$SAMPLES_FILE"

  if [ "$sample" -lt $((MAX_SAMPLES - 1)) ]; then
    sleep "$INTERVAL_SECONDS"
  fi
done

printf 'Telemetry written to %s\n' "$OUTPUT_DIR"
