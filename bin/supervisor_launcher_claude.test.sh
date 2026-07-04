#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TARGET_ROOT="/Users/stockn/Source/simple-retail-planner/main"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TSX_LOG="$TMP_DIR/tsx.log"

cat > "$TMP_DIR/tsx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${TSX_LOG_PATH:?}"

{
  printf 'pwd=%s\n' "$PWD"
  printf 'WORKFLOW_WORKER_DRIVER=%s\n' "${WORKFLOW_WORKER_DRIVER:-}"
  printf 'argc=%s\n' "$#"
  idx=0
  for arg in "$@"; do
    printf 'arg[%s]=%s\n' "$idx" "$arg"
    idx=$((idx + 1))
  done
} >> "$log_path"
EOF
chmod +x "$TMP_DIR/tsx"

launcher_output="$(
  PATH="$TMP_DIR:$PATH" \
  TSX_LOG_PATH="$TSX_LOG" \
  TSX_BIN="$TMP_DIR/tsx" \
    "$ROOT/bin/supervisor_launcher_claude" --run-id=demo-2026-07-03 2>&1
)"

if [[ "$launcher_output" != *"Launching deterministic supervisor loop"* ]]; then
  echo "Expected bin/supervisor_launcher_claude to print the deterministic supervisor loop banner." >&2
  exit 1
fi

if [[ "$launcher_output" != *"Supervisor script: $ROOT/scripts/supervisor-loop.ts"* ]]; then
  echo "Expected bin/supervisor_launcher_claude to print the supervisor loop script path." >&2
  exit 1
fi

if ! grep -q "^pwd=$DEFAULT_TARGET_ROOT$" "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher_claude to default WORKFLOW_TARGET_ROOT to $DEFAULT_TARGET_ROOT and run from there." >&2
  exit 1
fi

if ! grep -q "^arg\\[0\\]=$ROOT/scripts/supervisor-loop.ts$" "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher_claude to exec the supervisor loop TypeScript entrypoint." >&2
  exit 1
fi

if grep -q '^arg\[[0-9]\+\]=--once$' "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher_claude to loop continuously by default, not force --once." >&2
  exit 1
fi

if ! grep -q '^arg\[[0-9]\+\]=--run-id=demo-2026-07-03$' "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher_claude to pass through caller CLI arguments." >&2
  exit 1
fi

if ! grep -q "^WORKFLOW_WORKER_DRIVER=claude$" "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher_claude to set WORKFLOW_WORKER_DRIVER=claude so workers spawn via claude too." >&2
  cat "$TSX_LOG"
  exit 1
fi

> "$TSX_LOG"

launcher_output_once="$(
  PATH="$TMP_DIR:$PATH" \
  TSX_LOG_PATH="$TSX_LOG" \
  TSX_BIN="$TMP_DIR/tsx" \
    "$ROOT/bin/supervisor_launcher_claude" --once --run-id=demo-2026-07-03 2>&1
)"

once_count="$(grep -c '^arg\[[0-9]\+\]=--once$' "$TSX_LOG")"
if [[ "$once_count" -ne 1 ]]; then
  echo "Expected bin/supervisor_launcher_claude to pass an explicit --once straight through for a single tick." >&2
  cat "$TSX_LOG"
  exit 1
fi

echo "bin/supervisor_launcher_claude launcher test passed."
