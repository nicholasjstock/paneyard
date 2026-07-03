#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TSX_LOG="$TMP_DIR/tsx.log"

cat > "$TMP_DIR/tsx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'argc=%s\n' "$#"
  idx=0
  for arg in "$@"; do
    printf 'arg[%s]=%s\n' "$idx" "$arg"
    idx=$((idx + 1))
  done
  printf 'WORKFLOW_TARGET_ROOT=%s\n' "${WORKFLOW_TARGET_ROOT:-}"
} >> "${TSX_LOG_PATH:?}"
EOF
chmod +x "$TMP_DIR/tsx"

TSX_BIN="$TMP_DIR/tsx" TSX_LOG_PATH="$TSX_LOG" "$ROOT/bin/workflow_mcp_server" >/dev/null

if ! grep -q "^arg\\[0\\]=$ROOT/scripts/workflow-mcp-server.ts$" "$TSX_LOG"; then
  echo "Expected bin/workflow_mcp_server to invoke the MCP server script directly." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

if ! grep -q "^WORKFLOW_TARGET_ROOT=$ROOT$" "$TSX_LOG"; then
  echo "Expected bin/workflow_mcp_server to default WORKFLOW_TARGET_ROOT to the package root." >&2
  cat "$TSX_LOG" >&2 || true
  exit 1
fi

echo "bin/workflow_mcp_server launcher test passed."
