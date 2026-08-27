#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/purge-persistent-kv.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

passed=0
failed=0
ok() { echo "ok - $*"; passed=$((passed + 1)); }
bad() { echo "not ok - $*" >&2; failed=$((failed + 1)); }

ENV_FILE="$TEST_DIR/lab.env"
cat > "$ENV_FILE" <<'EOF'
WORKER_HOST=test-worker
DSPARK_VLLM_IMAGE=test-image:latest
KV_OFFLOAD_MODE=nvme-persistent
KV_OFFLOAD_ROOT=/safe/cache/head
WORKER_KV_OFFLOAD_ROOT=/safe/cache/worker
KV_OFFLOAD_CACHE_IDENTITY=test-identity
KV_PURGE_DOCKER_BIN=true
KV_PURGE_SSH_BIN=true
KV_PURGE_SYNC_BIN=true
EOF

run_mocked() {
  local log="$1"
  shift
  (
    # shellcheck source=purge-persistent-kv.sh
    source "$SCRIPT"
    remote_run() { printf 'remote:%s\n' "$*" >> "$log"; }
    ensure_no_project_container() { printf 'stopped:%s\n' "$1" >> "$log"; }
    preflight_node() { printf 'preflight:%s:%s\n' "$1" "$3" >> "$log"; }
    delete_node_files() {
      local where="$1"
      shift 2
      printf 'delete:%s:%s\n' "$where" "$*" >> "$log"
    }
    verify_node_absent() { printf 'verify:%s:%s\n' "$1" "$3" >> "$log"; }
    main --env-file "$ENV_FILE" --project purge-test \
      --confirm-identity test-identity "$@"
  )
}

log="$TEST_DIR/dry.log"
output="$(run_mocked "$log")"
if grep -Fqx 'stopped:head' "$log" \
  && grep -Fqx 'stopped:worker' "$log" \
  && grep -Fqx 'preflight:head:0' "$log" \
  && grep -Fqx 'preflight:worker:1' "$log" \
  && ! grep -q '^delete:' "$log" \
  && printf '%s\n' "$output" | grep -Fq 'DRY RUN: both-node preflight passed'; then
  ok "dry run performs both-node preflight without deletion"
else
  bad "dry-run ordering or output"
fi

log="$TEST_DIR/execute.log"
run_mocked "$log" --execute >/dev/null
expected=$(cat <<'EOF'
remote:true
stopped:head
stopped:worker
preflight:head:0
preflight:worker:1
delete:head:vllm-kv.slots.index
delete:worker:vllm-kv.slots.rank_1.meta vllm-kv.slots.rank_1
delete:head:vllm-kv.slots.rank_0.meta vllm-kv.slots.rank_0
verify:worker:1
verify:head:0
EOF
)
if [ "$(cat "$log")" = "$expected" ]; then
  ok "execute invalidates scheduler authority before either rank payload"
else
  bad "execute protocol order"
fi

log="$TEST_DIR/running.log"
if (
  source "$SCRIPT"
  remote_run() { :; }
  ensure_no_project_container() {
    printf 'stopped:%s\n' "$1" >> "$log"
    [ "$1" != head ]
  }
  preflight_node() { printf 'preflight\n' >> "$log"; }
  delete_node_files() { printf 'delete\n' >> "$log"; }
  main --env-file "$ENV_FILE" --project purge-test \
    --confirm-identity test-identity --execute
); then
  bad "running head was accepted"
elif [ "$(cat "$log")" = 'stopped:head' ]; then
  ok "any exact-project container rejects purge before metadata access"
else
  bad "running-container failure was not fail-closed"
fi

log="$TEST_DIR/worker-preflight.log"
if (
  source "$SCRIPT"
  remote_run() { :; }
  ensure_no_project_container() { printf 'stopped:%s\n' "$1" >> "$log"; }
  preflight_node() {
    printf 'preflight:%s\n' "$1" >> "$log"
    [ "$1" != worker ]
  }
  delete_node_files() { printf 'delete\n' >> "$log"; }
  main --env-file "$ENV_FILE" --project purge-test \
    --confirm-identity test-identity --execute
); then
  bad "worker metadata failure was accepted"
elif ! grep -q '^delete' "$log" \
  && [ "$(tail -n 1 "$log")" = 'preflight:worker' ]; then
  ok "both metadata preflights complete before first deletion"
else
  bad "metadata failure permitted deletion"
fi

log="$TEST_DIR/worker-delete.log"
if (
  source "$SCRIPT"
  remote_run() { :; }
  ensure_no_project_container() { :; }
  preflight_node() { :; }
  delete_node_files() {
    local where="$1"
    shift 2
    printf 'delete:%s:%s\n' "$where" "$*" >> "$log"
    [ "$where" != worker ]
  }
  verify_node_absent() { printf 'verify\n' >> "$log"; }
  main --env-file "$ENV_FILE" --project purge-test \
    --confirm-identity test-identity --execute
); then
  bad "worker delete failure was accepted"
elif [ "$(cat "$log")" = $'delete:head:vllm-kv.slots.index\ndelete:worker:vllm-kv.slots.rank_1.meta vllm-kv.slots.rank_1' ]; then
  ok "partial failure leaves scheduler authority absent and stops immediately"
else
  bad "partial-delete safety order"
fi

if "$SCRIPT" --env-file "$ENV_FILE" --project purge-test \
  --confirm-identity wrong-identity >/dev/null 2>&1; then
  bad "wrong typed identity was accepted"
else
  ok "typed identity must equal deployment identity"
fi

unsafe_env="$TEST_DIR/unsafe.env"
sed 's|KV_OFFLOAD_ROOT=/safe/cache/head|KV_OFFLOAD_ROOT=/|' \
  "$ENV_FILE" > "$unsafe_env"
if "$SCRIPT" --env-file "$unsafe_env" --project purge-test \
  --confirm-identity test-identity >/dev/null 2>&1; then
  bad "filesystem root was accepted"
else
  ok "broad filesystem root is rejected"
fi

if (
  source "$SCRIPT"
  CONFIRM_IDENTITY=test-identity
  DSPARK_VLLM_IMAGE=test-image
  DOCKER_BIN=docker
  ALLOW_UNVERIFIED_METADATA=0
  command="$(metadata_preflight_command '/safe/cache path' 1)"
  printf '%s\n' "$command" | grep -Fq "src=/safe/cache\\ path"
); then
  ok "remote metadata command shell-quotes roots containing spaces"
else
  bad "metadata command root quoting"
fi

fixture="$TEST_DIR/metadata"
mkdir -m 700 "$fixture"
python3 - "$fixture" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])

def header(kind: str) -> bytes:
    payload = json.dumps(
        {
            "identity": {"cache_identity": "test-identity"},
            "kind": kind,
            "num_slots": 1,
            "record_size": 16 if kind == "rank-manifest" else 96,
            "version": 1,
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    prefix = struct.pack(">8sII32s", b"VKVPM001", 1, len(payload), hashlib.sha256(payload).digest())
    return (prefix + payload).ljust(4096, b"\0")

(root / "vllm-kv.slots.rank_0").write_bytes(b"payload")
(root / "vllm-kv.slots.rank_0.meta").write_bytes(header("rank-manifest") + b"\0" * 16)
(root / "vllm-kv.slots.index").write_bytes(header("scheduler-index") + b"\0" * 96)
for path in root.iterdir():
    os.chmod(path, 0o600)
PY

source "$SCRIPT"
if python3 -c "$METADATA_CHECK_PY" "$fixture" 0 test-identity 0 \
  | grep -Fq 'vllm-kv.slots.index'; then
  ok "real metadata parser accepts matching fixed headers"
else
  bad "matching persistent metadata headers"
fi

if python3 -c "$METADATA_CHECK_PY" "$fixture" 0 different-identity 1 \
  >/dev/null 2>&1; then
  bad "unverified recovery bypassed a valid different identity"
else
  ok "valid different identity is rejected even in recovery mode"
fi

printf X | dd of="$fixture/vllm-kv.slots.rank_0.meta" bs=1 seek=60 conv=notrunc \
  status=none
if python3 -c "$METADATA_CHECK_PY" "$fixture" 0 test-identity 0 \
  >/dev/null 2>&1; then
  bad "corrupt metadata header was accepted by default"
elif python3 -c "$METADATA_CHECK_PY" "$fixture" 0 test-identity 1 \
  | grep -Fq 'explicit recovery enabled'; then
  ok "corrupt metadata requires the explicit recovery flag"
else
  bad "corrupt metadata recovery gate"
fi

echo "RESULT: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
