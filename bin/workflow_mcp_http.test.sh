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
  printf 'MCP_HOST=%s\n' "${MCP_HOST:-}"
  printf 'MCP_PORT=%s\n' "${MCP_PORT:-}"
} >> "$log_path"
EOF
chmod +x "$TMP_DIR/tsx"

TSX_BIN="$TMP_DIR/tsx" TSX_LOG_PATH="$TSX_LOG" "$ROOT/bin/workflow_mcp_http" --host 0.0.0.0 --port 8791 >/dev/null

if ! grep -q "^arg\\[0\\]=$ROOT/scripts/workflow-mcp-http.ts$" "$TSX_LOG"; then
  echo "Expected bin/workflow_mcp_http to invoke the HTTP server script directly." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^MCP_HOST=0.0.0.0$' "$TSX_LOG"; then
  echo "Expected bin/workflow_mcp_http to forward the host." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

if ! grep -q '^MCP_PORT=8791$' "$TSX_LOG"; then
  echo "Expected bin/workflow_mcp_http to forward the port." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

echo "bin/workflow_mcp_http launcher test passed."
