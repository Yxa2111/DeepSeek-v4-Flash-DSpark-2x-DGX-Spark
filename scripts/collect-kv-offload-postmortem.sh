#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: collect-kv-offload-postmortem.sh --output DIR [options]

Read-only evidence collection. Run on the recovered head before starting the
KV offload project.

Options:
  --output DIR       New or empty private output directory (required)
  --boot OFFSET      journal boot offset, default -1
  --project NAME     compose project, default kv-offload-step05
  -h, --help         show this help
EOF
}

OUTPUT_DIR=
BOOT_OFFSET=-1
PROJECT_NAME=kv-offload-step05
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || { echo "--output requires a value" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --boot)
      [ "$#" -ge 2 ] || { echo "--boot requires a value" >&2; exit 2; }
      BOOT_OFFSET="$2"
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] || { echo "--project requires a value" >&2; exit 2; }
      PROJECT_NAME="$2"
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
[[ "$BOOT_OFFSET" =~ ^-[0-9]+$ ]] \
  || { echo "--boot must be a negative journal boot offset" >&2; exit 2; }
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || { echo "--project contains unsupported characters" >&2; exit 2; }

umask 077
if [ -e "$OUTPUT_DIR" ] && [ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "output directory must be new or empty: $OUTPUT_DIR" >&2
  exit 2
fi
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
STATUS_FILE="$OUTPUT_DIR/capture-status.tsv"
: > "$STATUS_FILE"

capture() {
  local name="$1"
  shift
  local target="$OUTPUT_DIR/${name}.txt"
  local status
  {
    printf '# command:'
    printf ' %q' "$@"
    printf '\n'
    printf '# captured_at_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "$@"
  } > "$target" 2>&1
  status=$?
  printf '%s\t%s\n' "$name" "$status" >> "$STATUS_FILE"
  return 0
}

capture_shell() {
  local name="$1"
  local description="$2"
  shift 2
  local target="$OUTPUT_DIR/${name}.txt"
  local status
  {
    printf '# operation: %s\n' "$description"
    printf '# captured_at_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "$@"
  } > "$target" 2>&1
  status=$?
  printf '%s\t%s\n' "$name" "$status" >> "$STATUS_FILE"
  return 0
}

collect_identity() {
  date --iso-8601=seconds
  hostnamectl 2>/dev/null || hostname
  uptime
  who -b || true
  uname -a
}

collect_memory() {
  free -h
  printf '\n/proc/meminfo\n'
  sed -n '1,80p' /proc/meminfo
  printf '\nswap\n'
  swapon --show --bytes 2>/dev/null || true
  printf '\npressure\n'
  for file in /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory; do
    [ -r "$file" ] && { printf '%s\n' "$file"; sed -n '1,20p' "$file"; }
  done
}

collect_storage() {
  df -hT
  printf '\ninodes\n'
  df -hi
  printf '\nblock devices\n'
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
}

collect_network() {
  ip -br address
  printf '\nroutes\n'
  ip route show table all
  printf '\nlinks\n'
  ip -s link
}

collect_thermal() {
  if command -v sensors >/dev/null 2>&1; then sensors; fi
  for zone in /sys/class/thermal/thermal_zone*; do
    [ -d "$zone" ] || continue
    printf '%s type=' "$zone"
    cat "$zone/type" 2>/dev/null || true
    printf 'temp_millic=' 
    cat "$zone/temp" 2>/dev/null || true
  done
}

collect_docker_project() {
  local cid
  local -a ids=()
  docker ps -a --no-trunc \
    --filter "label=com.docker.compose.project=$PROJECT_NAME"
  mapfile -t ids < <(
    docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME" \
      | awk 'NF' | sort -u
  )
  for cid in "${ids[@]}"; do
    [[ "$cid" =~ ^[a-f0-9]+$ ]] || continue
    docker inspect --format \
      '{{.Id}}\t{{.Name}}\t{{.Config.Image}}\t{{.State.Status}}\t{{.State.ExitCode}}\t{{.State.OOMKilled}}\t{{.State.Error}}\t{{.State.StartedAt}}\t{{.State.FinishedAt}}' \
      "$cid"
    timeout 30 docker logs --timestamps --tail 20000 "$cid" \
      > "$OUTPUT_DIR/docker-${cid}.log" 2>&1 || true
    chmod 600 "$OUTPUT_DIR/docker-${cid}.log"
  done
}

capture_shell identity "current host identity and boot time" collect_identity
capture journal-boots journalctl --list-boots --no-pager
capture previous-kernel journalctl -b "$BOOT_OFFSET" -k --no-pager -o short-precise
capture previous-warnings journalctl -b "$BOOT_OFFSET" -p warning..alert --no-pager -o short-precise
capture previous-docker journalctl -b "$BOOT_OFFSET" -u docker.service --no-pager -o short-precise
capture previous-network journalctl -b "$BOOT_OFFSET" -u NetworkManager.service --no-pager -o short-precise
capture current-kernel journalctl -b 0 -k --no-pager -o short-precise
capture last-reboots last -x
capture failed-units systemctl --failed --no-pager --plain
capture coredumps coredumpctl list --no-pager
capture dmesg timeout 30 dmesg -T
capture_shell memory "current memory, swap, and PSI" collect_memory
capture_shell storage "current disk and inode capacity" collect_storage
capture_shell network "current addresses, routes, and link counters" collect_network
capture_shell thermal "available thermal sensors" collect_thermal
capture nvidia-smi timeout 30 nvidia-smi -q
capture nvme-health timeout 30 nvme list
capture_shell docker-project "limited project state and bounded container logs" collect_docker_project

find "$OUTPUT_DIR" -maxdepth 1 -type f ! -name MANIFEST.sha256 -print0 \
  | sort -z | xargs -0 sha256sum > "$OUTPUT_DIR/MANIFEST.sha256"
chmod 600 "$OUTPUT_DIR"/*

printf 'Postmortem evidence written to %s\n' "$OUTPUT_DIR"
printf 'Review for secrets or prompt content before copying any file into git.\n'
