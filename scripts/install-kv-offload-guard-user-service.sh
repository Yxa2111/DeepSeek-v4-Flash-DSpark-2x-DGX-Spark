#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-kv-offload-guard-user-service.sh --project NAME --peer-host HOST [options]

Install a continuously supervised per-node KV-offload guard as a user-systemd
service.  This does not start or restart the model service.

Required:
  --project NAME                exact Compose project name
  --peer-host HOST              TP peer reached by non-interactive SSH

Options:
  --output-root DIR             default ~/.local/state/dspark-kv-peer-guard/NAME
  --interval SEC                default 2
  --samples COUNT               default 43200 (one evidence set per day)
  --min-available-kib KIB       default 12582912 (12 GiB)
  --max-temp-millic MC          default 90000
  --consecutive COUNT           resource breach threshold, default 3
  --peer-check-consecutive N    peer failure threshold, default 3
  --stop-timeout SEC            Docker graceful-stop timeout, default 20
  --enable-now                  enable and restart the installed unit
  -h, --help                    show this help
EOF
}

PROJECT_NAME=
PEER_HOST=
OUTPUT_ROOT=
INTERVAL_SECONDS=2
MAX_SAMPLES=43200
MIN_AVAILABLE_KIB=12582912
MAX_TEMP_MILLIC=90000
CONSECUTIVE_BREACHES=3
PEER_CHECK_CONSECUTIVE=3
STOP_TIMEOUT_SECONDS=20
ENABLE_NOW=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) [ "$#" -ge 2 ] || { echo "--project requires a value" >&2; exit 2; }; PROJECT_NAME="$2"; shift 2 ;;
    --peer-host) [ "$#" -ge 2 ] || { echo "--peer-host requires a value" >&2; exit 2; }; PEER_HOST="$2"; shift 2 ;;
    --output-root) [ "$#" -ge 2 ] || { echo "--output-root requires a value" >&2; exit 2; }; OUTPUT_ROOT="$2"; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || { echo "--interval requires a value" >&2; exit 2; }; INTERVAL_SECONDS="$2"; shift 2 ;;
    --samples) [ "$#" -ge 2 ] || { echo "--samples requires a value" >&2; exit 2; }; MAX_SAMPLES="$2"; shift 2 ;;
    --min-available-kib) [ "$#" -ge 2 ] || { echo "--min-available-kib requires a value" >&2; exit 2; }; MIN_AVAILABLE_KIB="$2"; shift 2 ;;
    --max-temp-millic) [ "$#" -ge 2 ] || { echo "--max-temp-millic requires a value" >&2; exit 2; }; MAX_TEMP_MILLIC="$2"; shift 2 ;;
    --consecutive) [ "$#" -ge 2 ] || { echo "--consecutive requires a value" >&2; exit 2; }; CONSECUTIVE_BREACHES="$2"; shift 2 ;;
    --peer-check-consecutive) [ "$#" -ge 2 ] || { echo "--peer-check-consecutive requires a value" >&2; exit 2; }; PEER_CHECK_CONSECUTIVE="$2"; shift 2 ;;
    --stop-timeout) [ "$#" -ge 2 ] || { echo "--stop-timeout requires a value" >&2; exit 2; }; STOP_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --enable-now) ENABLE_NOW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT_NAME" ] || { echo "--project is required" >&2; exit 2; }
[ -n "$PEER_HOST" ] || { echo "--peer-host is required" >&2; exit 2; }
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || { echo "--project contains unsupported characters" >&2; exit 2; }
[[ "$PEER_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] \
  || { echo "--peer-host contains unsupported characters" >&2; exit 2; }
for numeric_name in INTERVAL_SECONDS MAX_SAMPLES MIN_AVAILABLE_KIB \
  MAX_TEMP_MILLIC CONSECUTIVE_BREACHES PEER_CHECK_CONSECUTIVE \
  STOP_TIMEOUT_SECONDS; do
  numeric_value="${!numeric_name}"
  [[ "$numeric_value" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$numeric_name must be a positive integer" >&2; exit 2; }
done

USER_HOME="${KV_GUARD_USER_HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"
[ -n "$USER_HOME" ] && [[ "$USER_HOME" = /* ]] \
  || { echo "unable to resolve an absolute user home" >&2; exit 2; }
if [ -z "$OUTPUT_ROOT" ]; then
  OUTPUT_ROOT="$USER_HOME/.local/state/dspark-kv-peer-guard/$PROJECT_NAME"
fi
[[ "$OUTPUT_ROOT" = /* ]] \
  || { echo "--output-root must be absolute" >&2; exit 2; }
# Unit generation intentionally accepts only simple absolute paths.  This
# prevents whitespace, newlines and systemd specifiers from changing ExecStart.
[[ "$OUTPUT_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] \
  || { echo "--output-root contains unsupported characters" >&2; exit 2; }
case "/$OUTPUT_ROOT/" in
  */../*|*/./*) echo "--output-root must not contain dot components" >&2; exit 2 ;;
esac
[ ! -L "$OUTPUT_ROOT" ] \
  || { echo "--output-root must not be a symbolic link" >&2; exit 2; }

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_SOURCE="$SOURCE_DIR/run-kv-offload-guard-supervised.sh"
GUARD_SOURCE="$SOURCE_DIR/guard-kv-offload-node.sh"
[ -x "$WRAPPER_SOURCE" ] || { echo "missing executable wrapper: $WRAPPER_SOURCE" >&2; exit 2; }
[ -x "$GUARD_SOURCE" ] || { echo "missing executable guard: $GUARD_SOURCE" >&2; exit 2; }

INSTALL_DIR="$USER_HOME/.local/libexec/dspark-kv-peer-guard"
UNIT_DIR="$USER_HOME/.config/systemd/user"
UNIT_NAME="dspark-kv-peer-guard-${PROJECT_NAME}.service"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"
SYSTEMCTL_BIN="${KV_GUARD_SYSTEMCTL_BIN:-systemctl}"

umask 077
mkdir -p "$INSTALL_DIR" "$UNIT_DIR" "$OUTPUT_ROOT"
chmod 700 "$INSTALL_DIR" "$OUTPUT_ROOT"
[ "$(stat -c %u "$OUTPUT_ROOT")" = "$(id -u)" ] \
  || { echo "--output-root is not owned by the current user" >&2; exit 2; }
install -m 700 "$WRAPPER_SOURCE" "$INSTALL_DIR/run-kv-offload-guard-supervised.sh"
install -m 700 "$GUARD_SOURCE" "$INSTALL_DIR/guard-kv-offload-node.sh"

UNIT_TMP="$(mktemp "$UNIT_DIR/.${UNIT_NAME}.XXXXXX")"
trap 'rm -f -- "$UNIT_TMP"' EXIT HUP INT TERM
printf '%s\n' \
  '[Unit]' \
  "Description=DGX Spark KV offload guard for $PROJECT_NAME" \
  'Documentation=https://github.com/Yxa2111/DeepSeek-v4-Flash-DSpark-2x-DGX-Spark' \
  'StartLimitIntervalSec=0' \
  '' \
  '[Service]' \
  'Type=simple' \
  "ExecStart=$INSTALL_DIR/run-kv-offload-guard-supervised.sh --output-root $OUTPUT_ROOT --project $PROJECT_NAME --interval $INTERVAL_SECONDS --samples $MAX_SAMPLES --min-available-kib $MIN_AVAILABLE_KIB --max-temp-millic $MAX_TEMP_MILLIC --consecutive $CONSECUTIVE_BREACHES --stop-timeout $STOP_TIMEOUT_SECONDS --peer-host $PEER_HOST --peer-check-consecutive $PEER_CHECK_CONSECUTIVE" \
  'Restart=always' \
  'RestartSec=5' \
  'TimeoutStopSec=30' \
  'KillSignal=SIGTERM' \
  'UMask=0077' \
  'NoNewPrivileges=yes' \
  'PrivateTmp=yes' \
  '' \
  '[Install]' \
  'WantedBy=default.target' \
  > "$UNIT_TMP"
chmod 600 "$UNIT_TMP"
mv -f -- "$UNIT_TMP" "$UNIT_PATH"
trap - EXIT HUP INT TERM

printf 'unit_name=%s\n' "$UNIT_NAME"
printf 'unit_path=%s\n' "$UNIT_PATH"
printf 'output_root=%s\n' "$OUTPUT_ROOT"

if [ "$ENABLE_NOW" -eq 1 ]; then
  command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 \
    || { echo "systemctl command is unavailable: $SYSTEMCTL_BIN" >&2; exit 2; }
  "$SYSTEMCTL_BIN" --user daemon-reload
  "$SYSTEMCTL_BIN" --user enable "$UNIT_NAME"
  "$SYSTEMCTL_BIN" --user restart "$UNIT_NAME"
  printf 'service_state=enabled_and_restarted\n'
else
  printf 'service_state=installed_not_started\n'
fi
