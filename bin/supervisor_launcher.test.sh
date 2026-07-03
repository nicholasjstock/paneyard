#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TSX_LOG="$TMP_DIR/tsx.log"

cat > "$TMP_DIR/tsx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${TSX_LOG_PATH:?}"

{
  printf 'pwd=%s\n' "$PWD"
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
    "$ROOT/bin/supervisor_launcher" --interval-ms=4321 2>&1
)"

if [[ "$launcher_output" != *"Launching deterministic supervisor loop."* ]]; then
  echo "Expected bin/supervisor_launcher to print the deterministic supervisor banner." >&2
  exit 1
fi

if [[ "$launcher_output" != *"Supervisor script: $ROOT/scripts/supervisor-loop.ts"* ]]; then
  echo "Expected bin/supervisor_launcher to print the supervisor loop script path." >&2
  exit 1
fi

if [[ "$launcher_output" != *"Workflow state dir: $ROOT/front/demo-output/agents-sdk"* ]]; then
  echo "Expected bin/supervisor_launcher to print the workflow state directory." >&2
  exit 1
fi

if grep -q 'codex' "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher to stop invoking codex." >&2
  exit 1
fi

if ! grep -q "^pwd=$ROOT$" "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher to execute from the repo root." >&2
  exit 1
fi

if ! grep -q "^arg\\[0\\]=$ROOT/scripts/supervisor-loop.ts$" "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher to exec the supervisor loop TypeScript entrypoint." >&2
  exit 1
fi

if ! grep -q '^arg\[[0-9]\+\]=--interval-ms=4321$' "$TSX_LOG"; then
  echo "Expected bin/supervisor_launcher to pass through CLI arguments to the supervisor loop." >&2
  exit 1
fi

echo "bin/supervisor_launcher launcher test passed."
