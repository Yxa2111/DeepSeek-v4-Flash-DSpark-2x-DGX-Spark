#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/collect-kv-offload-postmortem.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

"$SCRIPT" --help | grep -Fq 'Read-only evidence collection'

if "$SCRIPT" --output "$TMP_DIR/out" --boot current >/dev/null 2>&1; then
  echo "invalid boot offset accepted" >&2
  exit 1
fi

mkdir -p "$TMP_DIR/not-empty"
printf 'keep\n' > "$TMP_DIR/not-empty/user-file"
if "$SCRIPT" --output "$TMP_DIR/not-empty" >/dev/null 2>&1; then
  echo "non-empty output directory accepted" >&2
  exit 1
fi
[ "$(cat "$TMP_DIR/not-empty/user-file")" = keep ]

if rg -n '\b(docker (rm|stop|kill|restart)|systemctl (start|stop|restart|reboot|poweroff)|shutdown|reboot|poweroff|rm -[rf])\b' "$SCRIPT"; then
  echo "collector contains a mutating operational command" >&2
  exit 1
fi

grep -Fq "'{{.Id}}\\t{{.Name}}\\t{{.Config.Image}}" "$SCRIPT"
if grep -Eq 'docker inspect( |.*)--format.*(Config\.Env|json \.)' "$SCRIPT"; then
  echo "collector may dump container environment/secrets" >&2
  exit 1
fi

echo "KV offload postmortem collector tests passed"
