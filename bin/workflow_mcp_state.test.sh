#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TARGET_ROOT="/Users/stockn/Source/simple-retail-planner/main"
TMP_DIR="$(mktemp -d)"

HTTP_LOG="$TMP_DIR/http.log"
UI_LOG="$TMP_DIR/ui.log"
sleep 60 &
HTTP_STALE_PID=$!
sleep 60 &
UI_STALE_PID=$!

cleanup() {
  kill "$HTTP_STALE_PID" "$UI_STALE_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$TMP_DIR/workflow_mcp_http" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'http argc=%s\n' "$#"
  printf 'HTTP_HOST=%s\n' "${MCP_HOST:-}"
  printf 'HTTP_PORT=%s\n' "${MCP_PORT:-}"
  printf 'WORKFLOW_TARGET_ROOT=%s\n' "${WORKFLOW_TARGET_ROOT:-}"
} >> "${HTTP_LOG_PATH:?}"
exit 0
EOF
chmod +x "$TMP_DIR/workflow_mcp_http"

cat > "$TMP_DIR/workflow_mcp_state_ui" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'ui argc=%s\n' "$#"
  idx=0
  for arg in "$@"; do
    printf 'ui arg[%s]=%s\n' "$idx" "$arg"
    idx=$((idx + 1))
  done
  printf 'WORKFLOW_HTTP_URL=%s\n' "${WORKFLOW_HTTP_URL:-}"
} >> "${UI_LOG_PATH:?}"
sleep 0.2
exit 0
EOF
chmod +x "$TMP_DIR/workflow_mcp_state_ui"

cat > "$TMP_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$TMP_DIR/curl"

cat > "$TMP_DIR/lsof" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"8788"* || "$*" == *"8792"* ]]; then
  printf '%s\n' "${HTTP_STALE_PID:?}"
fi

if [[ "$*" == *"8789"* || "$*" == *"8793"* ]]; then
  printf '%s\n' "${UI_STALE_PID:?}"
fi
EOF
chmod +x "$TMP_DIR/lsof"

PATH="$TMP_DIR:$PATH" \
HTTP_LOG_PATH="$HTTP_LOG" \
UI_LOG_PATH="$UI_LOG" \
HTTP_STALE_PID="$HTTP_STALE_PID" \
UI_STALE_PID="$UI_STALE_PID" \
HTTP_BIN="$TMP_DIR/workflow_mcp_http" \
UI_BIN="$TMP_DIR/workflow_mcp_state_ui" \
SKIP_MCP_STATE_WAIT=1 \
"$ROOT/bin/workflow_mcp_state" --host 0.0.0.0 --http-port 8792 --ui-port 8793 >/dev/null

if ! grep -q '^HTTP_HOST=0.0.0.0$' "$HTTP_LOG"; then
  echo "Expected the combined launcher to start the HTTP server with the requested host." >&2
  cat "$HTTP_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^HTTP_PORT=8792$' "$HTTP_LOG"; then
  echo "Expected the combined launcher to start the HTTP server on the requested port." >&2
  cat "$HTTP_LOG" >&2 || true
  exit 1
fi

if ! grep -q "^WORKFLOW_TARGET_ROOT=$DEFAULT_TARGET_ROOT$" "$HTTP_LOG"; then
  echo "Expected the combined launcher to default WORKFLOW_TARGET_ROOT to $DEFAULT_TARGET_ROOT and pass it through to the HTTP server." >&2
  cat "$HTTP_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^ui arg\[2\]=--port$' "$UI_LOG"; then
  echo "Expected the combined launcher to pass the UI port through." >&2
  cat "$UI_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^ui arg\[3\]=8793$' "$UI_LOG"; then
  echo "Expected the combined launcher to pass the UI port value through." >&2
  cat "$UI_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^WORKFLOW_HTTP_URL=http://0.0.0.0:8792$' "$UI_LOG"; then
  echo "Expected the combined launcher to point the UI at the launched HTTP server." >&2
  cat "$UI_LOG" >&2 || true
  exit 1
fi

if kill -0 "$HTTP_STALE_PID" 2>/dev/null; then
  echo "Expected the combined launcher to clear the stale HTTP listener before starting." >&2
  exit 1
fi

if kill -0 "$UI_STALE_PID" 2>/dev/null; then
  echo "Expected the combined launcher to clear the stale UI listener before starting." >&2
  exit 1
fi

echo "bin/workflow_mcp_state combined launcher test passed."
