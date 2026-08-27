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
    cat "$FAKE_DOCKER_STATE"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$FAKE_DOCKER"
export FAKE_DOCKER_LOG="$TMP_DIR/docker.log"
export FAKE_DOCKER_STATE="$TMP_DIR/docker.state"
printf 'true\n' > "$FAKE_DOCKER_STATE"

mkdir -p "$TMP_DIR/thermal/thermal_zone0"
printf '50000\n' > "$TMP_DIR/thermal/thermal_zone0/temp"
printf 'MemAvailable:       1000 kB\nSwapFree:       1000 kB\n' \
  > "$TMP_DIR/meminfo-low"

set +e
KV_GUARD_DOCKER_BIN="$FAKE_DOCKER" \
KV_GUARD_SLEEP_BIN=/bin/true \
KV_GUARD_SYNC_BIN=/bin/true \
KV_GUARD_MEMINFO_PATH="$TMP_DIR/meminfo-low" \
KV_GUARD_THERMAL_ROOT="$TMP_DIR/thermal" \
  "$SCRIPT" --output "$TMP_DIR/trigger" --project kv-offload-test \
  --interval 1 --samples 3 --min-available-kib 2000 \
  --max-temp-millic 90000 --consecutive 2 --stop-timeout 5 \
  >"$TMP_DIR/trigger.stdout" 2>"$TMP_DIR/trigger.stderr"
trigger_status=$?
set -e
[ "$trigger_status" -eq 42 ]
grep -Fxq 'stop --time 5 aaaaaaaaaaaa' "$FAKE_DOCKER_LOG"
! grep -q '^kill ' "$FAKE_DOCKER_LOG"
grep -Fq $'1000\t50000\taaaaaaaaaaaa\t2\t0\ttrigger_low_memory' \
  "$TMP_DIR/trigger/guard-samples.tsv"
grep -Fxq 'trigger_reason=low_memory' "$TMP_DIR/trigger/run.meta"
grep -Fxq 'stop_result=graceful_stop' "$TMP_DIR/trigger/run.meta"
sha256sum -c "$TMP_DIR/trigger/MANIFEST.sha256" >/dev/null

: > "$FAKE_DOCKER_LOG"
export FAKE_DOCKER_MODE=none
printf 'MemAvailable:       5000 kB\nSwapFree:       1000 kB\n' \
  > "$TMP_DIR/meminfo-safe"
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
bash -n "$SCRIPT"
echo "KV offload node guard tests passed"
