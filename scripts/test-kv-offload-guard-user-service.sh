#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/scripts/run-kv-offload-guard-supervised.sh"
INSTALLER="$ROOT/scripts/install-kv-offload-guard-user-service.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT HUP INT TERM

FAKE_GUARD="$TMP_DIR/fake-guard"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" > "$FAKE_GUARD_LOG"' \
  'exit "${FAKE_GUARD_STATUS:-0}"' \
  > "$FAKE_GUARD"
chmod 700 "$FAKE_GUARD"
export FAKE_GUARD_LOG="$TMP_DIR/fake-guard.log"

mkdir -p "$TMP_DIR/evidence"
FAKE_GUARD_STATUS=42 "$WRAPPER" \
  --output-root "$TMP_DIR/evidence" \
  --project kv-offload-test \
  --guard-script "$FAKE_GUARD" \
  --interval 2 --samples 5 \
  > "$TMP_DIR/wrapper.out" 2> "$TMP_DIR/wrapper.err" \
  || wrapper_status=$?
[ "${wrapper_status:-0}" -eq 42 ]
run_dir="$(sed -n 's/^guard_evidence_dir=//p' "$TMP_DIR/wrapper.out")"
[ -d "$run_dir" ]
case "$run_dir" in "$TMP_DIR/evidence"/run-*) ;; *) exit 1 ;; esac
grep -Fq -- "--output $run_dir --project kv-offload-test --interval 2 --samples 5" \
  "$FAKE_GUARD_LOG"
[ "$(stat -c %a "$TMP_DIR/evidence")" = 700 ]
[ "$(stat -c %a "$run_dir")" = 700 ]

ln -s "$TMP_DIR/evidence" "$TMP_DIR/evidence-link"
set +e
"$WRAPPER" --output-root "$TMP_DIR/evidence-link" \
  --project kv-offload-test --guard-script "$FAKE_GUARD" \
  >/dev/null 2>&1
symlink_status=$?
"$WRAPPER" --output-root "$TMP_DIR/evidence" --project kv-offload-test \
  --guard-script "$FAKE_GUARD" --output "$TMP_DIR/escape" \
  >/dev/null 2>&1
output_status=$?
set -e
[ "$symlink_status" -eq 2 ]
[ "$output_status" -eq 2 ]

exec 8>"$TMP_DIR/evidence/.kv-offload-test.lock"
flock -n 8
set +e
"$WRAPPER" --output-root "$TMP_DIR/evidence" \
  --project kv-offload-test --guard-script "$FAKE_GUARD" \
  >/dev/null 2>&1
duplicate_status=$?
set -e
[ "$duplicate_status" -eq 75 ]
flock -u 8
exec 8>&-

FAKE_SYSTEMCTL="$TMP_DIR/fake-systemctl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "$FAKE_SYSTEMCTL_LOG"' \
  > "$FAKE_SYSTEMCTL"
chmod 700 "$FAKE_SYSTEMCTL"
export FAKE_SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"

TEST_HOME="$TMP_DIR/home"
KV_GUARD_USER_HOME="$TEST_HOME" \
KV_GUARD_SYSTEMCTL_BIN="$FAKE_SYSTEMCTL" \
  "$INSTALLER" --project kv-offload-test --peer-host 192.0.2.20 \
  --output-root "$TEST_HOME/state/guard" --interval 3 --samples 10 \
  --min-available-kib 4000 --max-temp-millic 85000 \
  --consecutive 4 --peer-check-consecutive 5 --stop-timeout 6 \
  --enable-now > "$TMP_DIR/install.out"

UNIT_NAME=dspark-kv-peer-guard-kv-offload-test.service
UNIT_PATH="$TEST_HOME/.config/systemd/user/$UNIT_NAME"
[ -f "$UNIT_PATH" ]
[ "$(stat -c %a "$UNIT_PATH")" = 600 ]
[ "$(stat -c %a "$TEST_HOME/.local/libexec/dspark-kv-peer-guard/guard-kv-offload-node.sh")" = 700 ]
grep -Fxq "ExecStart=$TEST_HOME/.local/libexec/dspark-kv-peer-guard/run-kv-offload-guard-supervised.sh --output-root $TEST_HOME/state/guard --project kv-offload-test --interval 3 --samples 10 --min-available-kib 4000 --max-temp-millic 85000 --consecutive 4 --stop-timeout 6 --peer-host 192.0.2.20 --peer-check-consecutive 5" "$UNIT_PATH"
grep -Fxq 'Restart=always' "$UNIT_PATH"
grep -Fxq 'NoNewPrivileges=yes' "$UNIT_PATH"
grep -Fxq -- '--user daemon-reload' "$FAKE_SYSTEMCTL_LOG"
grep -Fxq -- "--user enable $UNIT_NAME" "$FAKE_SYSTEMCTL_LOG"
grep -Fxq -- "--user restart $UNIT_NAME" "$FAKE_SYSTEMCTL_LOG"
grep -Fxq 'service_state=enabled_and_restarted' "$TMP_DIR/install.out"

set +e
KV_GUARD_USER_HOME="$TEST_HOME" "$INSTALLER" \
  --project kv-offload-test --peer-host=-oProxyCommand=bad \
  >/dev/null 2>&1
bad_peer_status=$?
KV_GUARD_USER_HOME="$TEST_HOME" "$INSTALLER" \
  --project kv-offload-test --peer-host 192.0.2.20 \
  --output-root '/tmp/bad path' >/dev/null 2>&1
bad_path_status=$?
set -e
[ "$bad_peer_status" -eq 2 ]
[ "$bad_path_status" -eq 2 ]

bash -n "$WRAPPER"
bash -n "$INSTALLER"
echo "KV offload guard user-service tests passed"
