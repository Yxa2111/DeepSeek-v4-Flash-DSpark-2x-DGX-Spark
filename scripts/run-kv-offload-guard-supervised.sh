#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-kv-offload-guard-supervised.sh --output-root DIR --project NAME [guard options]

Create one private, uniquely named evidence directory and exec the KV-offload
node guard.  A per-project flock prevents two supervisors from protecting the
same local Compose project at once.

Required:
  --output-root DIR         absolute private evidence root
  --project NAME            exact Compose project name

All other arguments are passed unchanged to guard-kv-offload-node.sh.  The
caller must not pass --output; this wrapper owns that path.
EOF
}

OUTPUT_ROOT=
PROJECT_NAME=
GUARD_ARGS=()
GUARD_SCRIPT="$(cd "$(dirname "$0")" && pwd)/guard-kv-offload-node.sh"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-root)
      [ "$#" -ge 2 ] || { echo "--output-root requires a value" >&2; exit 2; }
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] || { echo "--project requires a value" >&2; exit 2; }
      PROJECT_NAME="$2"
      GUARD_ARGS+=(--project "$2")
      shift 2
      ;;
    --guard-script)
      # Test-only dependency injection.  The installer never emits this flag.
      [ "$#" -ge 2 ] || { echo "--guard-script requires a value" >&2; exit 2; }
      GUARD_SCRIPT="$2"
      shift 2
      ;;
    --output|--output=*)
      echo "--output is owned by the supervisor wrapper" >&2
      exit 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      GUARD_ARGS+=("$1")
      shift
      ;;
  esac
done

[ -n "$OUTPUT_ROOT" ] || { echo "--output-root is required" >&2; exit 2; }
[ -n "$PROJECT_NAME" ] || { echo "--project is required" >&2; exit 2; }
[[ "$PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || { echo "--project contains unsupported characters" >&2; exit 2; }
[[ "$OUTPUT_ROOT" = /* ]] \
  || { echo "--output-root must be absolute" >&2; exit 2; }
[ ! -L "$OUTPUT_ROOT" ] \
  || { echo "--output-root must not be a symbolic link" >&2; exit 2; }
[ -x "$GUARD_SCRIPT" ] \
  || { echo "guard script is not executable: $GUARD_SCRIPT" >&2; exit 2; }
command -v flock >/dev/null 2>&1 \
  || { echo "flock command is unavailable" >&2; exit 2; }

umask 077
mkdir -p "$OUTPUT_ROOT"
chmod 700 "$OUTPUT_ROOT"
[ "$(stat -c %u "$OUTPUT_ROOT")" = "$(id -u)" ] \
  || { echo "--output-root is not owned by the current user" >&2; exit 2; }

LOCK_FILE="$OUTPUT_ROOT/.${PROJECT_NAME}.lock"
exec 9>"$LOCK_FILE"
flock -n 9 \
  || { echo "another guard supervisor owns project $PROJECT_NAME" >&2; exit 75; }

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$(mktemp -d "$OUTPUT_ROOT/run-${run_stamp}-XXXXXX")"
chmod 700 "$RUN_DIR"
printf 'guard_evidence_dir=%s\n' "$RUN_DIR"

exec "$GUARD_SCRIPT" --output "$RUN_DIR" "${GUARD_ARGS[@]}"
