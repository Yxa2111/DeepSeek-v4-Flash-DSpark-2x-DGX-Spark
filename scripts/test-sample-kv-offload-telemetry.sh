#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/sample-kv-offload-telemetry.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

"$SCRIPT" --help | grep -Fq 'Read-only per-node sampler'
if "$SCRIPT" --output "$TMP_DIR/bad" --interval 0 >/dev/null 2>&1; then
  echo "zero interval accepted" >&2
  exit 1
fi

"$SCRIPT" --output "$TMP_DIR/run" --project no-such-kv-project \
  --interval 1 --samples 1 >/dev/null
[ "$(stat -c %a "$TMP_DIR/run")" = 700 ]
[ "$(stat -c %a "$TMP_DIR/run/samples.tsv")" = 600 ]
[ "$(wc -l < "$TMP_DIR/run/samples.tsv")" -eq 2 ]
awk -F '\t' 'NF != 22 { exit 1 }' "$TMP_DIR/run/samples.tsv"
grep -Fq $'cgroup_oom\tcgroup_oom_kill\tio_rbytes\tio_wbytes' \
  "$TMP_DIR/run/samples.tsv"
grep -Fq $'max_temp_millic\tgpu_temp_c\tgpu_util_percent\tgpu_power_w\tgpu_sm_clock_mhz' \
  "$TMP_DIR/run/samples.tsv"
grep -Fq 'project=no-such-kv-project' "$TMP_DIR/run/run.meta"
sha256sum -c "$TMP_DIR/run/MANIFEST.sha256" >/dev/null

if rg -n '\b(docker (rm|stop|kill|restart)|systemctl (start|stop|restart|reboot|poweroff)|shutdown|reboot|poweroff|rm -[rf])\b' "$SCRIPT"; then
  echo "sampler contains a mutating operational command" >&2
  exit 1
fi

echo "KV offload telemetry sampler tests passed"
