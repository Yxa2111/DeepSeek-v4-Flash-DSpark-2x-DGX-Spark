#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/guard-kv-offload-node.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT HUP INT TERM

FAKE_DOCKER="$TMP_DIR/docker"
cat > "$FAKE_DOCKER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps)
    case "${FAKE_DOCKER_MODE:-one}" in
      none) ;;
      one) printf '%s\n' aaaaaaaaaaaa ;;
      many) printf '%s\n' aaaaaaaaaaaa bbbbbbbbbbbb ;;
    esac
    ;;
  stop)
    printf 'false\n' > "$FAKE_DOCKER_STATE"
    printf '%s\n' "${*: -1}"
    ;;
  kill)
    printf 'false\n' > "$FAKE_DOCKER_STATE"
    printf '%s\n' "${*: -1}"
    ;;
  inspect)
    if [ "$3" = '{{.State.ExitCode}}' ]; then
      printf '%s\n' "${FAKE_DOCKER_EXIT_CODE:-0}"
    else
      cat "$FAKE_DOCKER_STATE"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$FAKE_DOCKER"
export FAKE_DOCKER_LOG="$TMP_DIR/docker.log"
export FAKE_DOCKER_STATE="$TMP_DIR/docker.state"
printf 'true\n' > "$FAKE_DOCKER_STATE"

FAKE_SSH="$TMP_DIR/ssh"
cat > "$FAKE_SSH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
remote_command="${*: -1}"
if [[ "$remote_command" == *kv_guard_peer_probe* ]]; then
  case "${FAKE_SSH_MODE:-running}" in
    running) printf 'running\n' ;;
    absent) printf 'absent\n' ;;
    fail) exit 255 ;;
    fail-once)
      count=0
      [ ! -f "$FAKE_SSH_COUNT" ] || count="$(cat "$FAKE_SSH_COUNT")"
      count=$((count + 1))
      printf '%s\n' "$count" > "$FAKE_SSH_COUNT"
      if [ "$count" -eq 1 ]; then exit 255; fi
      printf 'running\n'
      ;;
    *) exit 2 ;;
  esac
fi
EOF
chmod 700 "$FAKE_SSH"
export FAKE_SSH_LOG="$TMP_DIR/ssh.log"
export FAKE_SSH_COUNT="$TMP_DIR/ssh.count"

mkdir -p "$TMP_DIR/thermal/thermal_zone0"
printf '50000\n' > "$TMP_DIR/thermal/thermal_zone0/temp"
printf 'MemAvailable:       1000 kB\nSwapFree:       1000 kB\n' \
  > "$TMP_DIR/meminfo-low"
printf 'MemAvailable:       5000 kB\nSwapFree:       1000 kB\n' \
  > "$TMP_DIR/meminfo-safe"

set +e
KV_GUARD_DOCKER_BIN="$FAKE_DOCKER" \
KV_GUARD_SLEEP_BIN=/bin/true \
KV_GUARD_SYNC_BIN=/bin/true \
KV_GUARD_SSH_BIN="$FAKE_SSH" \
KV_GUARD_MEMINFO_PATH="$TMP_DIR/meminfo-low" \
KV_GUARD_THERMAL_ROOT="$TMP_DIR/thermal" \
  "$SCRIPT" --output "$TMP_DIR/trigger" --project kv-offload-test \
  --interval 1 --samples 3 --min-available-kib 2000 \
  --max-temp-millic 90000 --consecutive 2 --stop-timeout 5 \
  --peer-host 192.0.2.20 \
  >"$TMP_DIR/trigger.stdout" 2>"$TMP_DIR/trigger.stderr"
trigger_status=$?
set -e
[ "$trigger_status" -eq 42 ]
grep -Fxq 'stop --timeout 5 aaaaaaaaaaaa' "$FAKE_DOCKER_LOG"
! grep -q '^kill ' "$FAKE_DOCKER_LOG"
grep -Fq -- '-o BatchMode=yes -o ConnectTimeout=10 192.0.2.20' "$FAKE_SSH_LOG"
grep -Fq 'label=com.docker.compose.project=kv-offload-test' "$FAKE_SSH_LOG"
grep -Fq 'docker stop --timeout 5' "$FAKE_SSH_LOG"
grep -Fq $'1000\t50000\taaaaaaaaaaaa\t2\t0\tdisabled\t0\ttrigger_low_memory' \
  "$TMP_DIR/trigger/guard-samples.tsv"
grep -Fxq 'trigger_reason=low_memory' "$TMP_DIR/trigger/run.meta"
grep -Fxq 'stop_result=graceful_stop' "$TMP_DIR/trigger/run.meta"
grep -Fxq 'peer_stop_result=stopped_or_absent' "$TMP_DIR/trigger/run.meta"
sha256sum -c "$TMP_DIR/trigger/MANIFEST.sha256" >/dev/null

: > "$FAKE_DOCKER_LOG"
export FAKE_DOCKER_MODE=one
export FAKE_DOCKER_EXIT_CODE=137
printf 'true\n' > "$FAKE_DOCKER_STATE"
set +e
KV_GUARD_DOCKER_BIN="$FAKE_DOCKER" \
KV_GUARD_SLEEP_BIN=/bin/true \
KV_GUARD_SYNC_BIN=/bin/true \
KV_GUARD_MEMINFO_PATH="$TMP_DIR/meminfo-low" \
KV_GUARD_THERMAL_ROOT="$TMP_DIR/thermal" \
  "$SCRIPT" --output "$TMP_DIR/timed-kill" --project kv-offload-test \
  --interval 1 --samples 1 --min-available-kib 2000 \
  --max-temp-millic 90000 --consecutive 1 --stop-timeout 5 \
  >/dev/null 2>&1
timed_kill_status=$?
set -e
[ "$timed_kill_status" -eq 42 ]
grep -Fxq 'stop_result=timed_kill' "$TMP_DIR/timed-kill/run.meta"
unset FAKE_DOCKER_EXIT_CODE

: > "$FAKE_DOCKER_LOG"
: > "$FAKE_SSH_LOG"
export FAKE_DOCKER_MODE=one
export FAKE_SSH_MODE=fail
printf 'true\n' > "$FAKE_DOCKER_STATE"
set +e
KV_GUARD_DOCKER_BIN="$FAKE_DOCKER" \
KV_GUARD_SLEEP_BIN=/bin/true \
KV_GUARD_SYNC_BIN=/bin/true \
KV_GUARD_SSH_BIN="$FAKE_SSH" \
KV_GUARD_MEMINFO_PATH="$TMP_DIR/meminfo-safe" \
KV_GUARD_THERMAL_ROOT="$TMP_DIR/thermal" \
  "$SCRIPT" --output "$TMP_DIR/peer-failed" --project kv-offload-test \
  --interval 1 --samples 3 --min-available-kib 2000 \
  --max-temp-millic 90000 --consecutive 2 --stop-timeout 5 \
  --peer-host 192.0.2.20 --peer-check-consecutive 2 \
  >/dev/null 2>&1
peer_failed_status=$?
set -e
[ "$peer_failed_status" -eq 42 ]
grep -Fxq 'stop --timeout 5 aaaaaaaaaaaa' "$FAKE_DOCKER_LOG"
grep -Fq $'unreachable\t1\tnone' \
  "$TMP_DIR/peer-failed/guard-samples.tsv"
grep -Fq $'unreachable\t2\ttrigger_peer_unavailable' \
  "$TMP_DIR/peer-failed/guard-samples.tsv"
grep -Fxq 'trigger_reason=peer_unavailable' \
  "$TMP_DIR/peer-failed/run.meta"
grep -Fxq 'last_peer_state=unreachable' \
  "$TMP_DIR/peer-failed/run.meta"
grep -Fxq 'peer_stop_result=skipped_peer_unavailable' \
  "$TMP_DIR/peer-failed/run.meta"
! grep -Fq 'docker stop --timeout 5' "$FAKE_SSH_LOG"

: > "$FAKE_DOCKER_LOG"
: > "$FAKE_SSH_LOG"
rm -f "$FAKE_SSH_COUNT"
export FAKE_SSH_MODE=fail-once
printf 'true\n' > "$FAKE_DOCKER_STATE"
KV_GUARD_DOCKER_BIN="$FAKE_DOCKER" \
KV_GUARD_SLEEP_BIN=/bin/true \
KV_GUARD_SYNC_BIN=/bin/true \
KV_GUARD_SSH_BIN="$FAKE_SSH" \
KV_GUARD_MEMINFO_PATH="$TMP_DIR/meminfo-safe" \
KV_GUARD_THERMAL_ROOT="$TMP_DIR/thermal" \
  "$SCRIPT" --output "$TMP_DIR/peer-recovers" --project kv-offload-test \
  --interval 1 --samples 3 --min-available-kib 2000 \
  --max-temp-millic 90000 --consecutive 2 --stop-timeout 5 \
  --peer-host 192.0.2.20 --peer-check-consecutive 2 \
  >/dev/null
grep -Fq $'unreachable\t1\tnone' \
  "$TMP_DIR/peer-recovers/guard-samples.tsv"
grep -Fq $'running\t0\tnone' \
  "$TMP_DIR/peer-recovers/guard-samples.tsv"
grep -Fxq 'trigger_reason=none' "$TMP_DIR/peer-recovers/run.meta"
! grep -Eq '^(stop|kill) ' "$FAKE_DOCKER_LOG"
unset FAKE_SSH_MODE

: > "$FAKE_DOCKER_LOG"
export FAKE_DOCKER_MODE=none
KV_GUARD_DOCKER_BIN="$FAKE_DOCKER" \
KV_GUARD_SLEEP_BIN=/bin/true \
KV_GUARD_SYNC_BIN=/bin/true \
KV_GUARD_MEMINFO_PATH="$TMP_DIR/meminfo-safe" \
KV_GUARD_THERMAL_ROOT="$TMP_DIR/thermal" \
  "$SCRIPT" --output "$TMP_DIR/safe" --project kv-offload-test \
  --interval 1 --samples 1 --min-available-kib 2000 \
  --max-temp-millic 90000 --consecutive 1 >/dev/null
! grep -Eq '^(stop|kill) ' "$FAKE_DOCKER_LOG"
grep -Fxq 'trigger_reason=none' "$TMP_DIR/safe/run.meta"

export FAKE_DOCKER_MODE=many
set +e
KV_GUARD_DOCKER_BIN="$FAKE_DOCKER" \
KV_GUARD_SLEEP_BIN=/bin/true \
KV_GUARD_SYNC_BIN=/bin/true \
KV_GUARD_MEMINFO_PATH="$TMP_DIR/meminfo-safe" \
KV_GUARD_THERMAL_ROOT="$TMP_DIR/thermal" \
  "$SCRIPT" --output "$TMP_DIR/many" --project kv-offload-test \
  --interval 1 --samples 1 --min-available-kib 2000 \
  --max-temp-millic 90000 --consecutive 1 >/dev/null 2>&1
many_status=$?
set -e
[ "$many_status" -eq 2 ]

"$SCRIPT" --help | grep -Fq 'node safety circuit breaker'
set +e
"$SCRIPT" --output "$TMP_DIR/bad-peer" --peer-host=-oProxyCommand=bad \
  >/dev/null 2>&1
bad_peer_status=$?
set -e
[ "$bad_peer_status" -eq 2 ]
set +e
"$SCRIPT" --output "$TMP_DIR/missing-peer" --peer-check-consecutive 2 \
  >/dev/null 2>&1
missing_peer_status=$?
set -e
[ "$missing_peer_status" -eq 2 ]
bash -n "$SCRIPT"
echo "KV offload node guard tests passed"
