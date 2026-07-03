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
  printf 'argc=%s\n' "$#"
  idx=0
  for arg in "$@"; do
    printf 'arg[%s]=%s\n' "$idx" "$arg"
    idx=$((idx + 1))
  done
  printf 'WORKFLOW_HTTP_URL=%s\n' "${WORKFLOW_HTTP_URL:-}"
  printf 'MCP_STATE_UI_HOST=%s\n' "${MCP_STATE_UI_HOST:-}"
  printf 'MCP_STATE_UI_PORT=%s\n' "${MCP_STATE_UI_PORT:-}"
} >> "$log_path"
EOF
chmod +x "$TMP_DIR/tsx"

TSX_BIN="$TMP_DIR/tsx" TSX_LOG_PATH="$TSX_LOG" "$ROOT/bin/workflow_mcp_state_ui" --host 0.0.0.0 --port 8793 >/dev/null

if ! grep -q "^arg\\[0\\]=$ROOT/scripts/workflow-mcp-state-ui.ts$" "$TSX_LOG"; then
  echo "Expected the MCP state UI launcher to run the standalone UI server script." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^MCP_STATE_UI_HOST=0.0.0.0$' "$TSX_LOG"; then
  echo "Expected the MCP state UI launcher to forward the requested host." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^MCP_STATE_UI_PORT=8793$' "$TSX_LOG"; then
  echo "Expected the MCP state UI launcher to forward the requested port." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^WORKFLOW_HTTP_URL=http://127.0.0.1:8788$' "$TSX_LOG"; then
  echo "Expected the MCP state UI launcher to default the workflow HTTP URL to the matching MCP host/port." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

echo "bin/workflow_mcp_state_ui launcher test passed."
