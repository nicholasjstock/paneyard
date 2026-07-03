#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TSX_LOG="$TMP_DIR/tsx.log"

cat > "$TMP_DIR/tsx" <<EOF
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'argc=%s\n' "\$#"
  idx=0
  for arg in "\$@"; do
    printf 'arg[%s]=%s\n' "\$idx" "\$arg"
    idx=\$((idx + 1))
  done
} >> "$TSX_LOG"
EOF
chmod +x "$TMP_DIR/tsx"

TSX_BIN="$TMP_DIR/tsx" "$ROOT/bin/workflow_bus" --path /tmp/workflow-bus.json --limit 5

if ! grep -q "^arg\\[0\\]=$ROOT/scripts/workflow-bus-inspect.ts\$" "$TSX_LOG"; then
  echo "Expected bin/workflow_bus to invoke the bus inspector script directly." >&2
  exit 1
fi

if ! grep -q '^arg\[1\]=--path$' "$TSX_LOG"; then
  echo "Expected bin/workflow_bus to forward the custom storage path." >&2
  exit 1
fi

if ! grep -q '^arg\[2\]=/tmp/workflow-bus.json$' "$TSX_LOG"; then
  echo "Expected bin/workflow_bus to forward the custom storage path value." >&2
  exit 1
fi

if ! grep -q '^arg\[3\]=--limit$' "$TSX_LOG"; then
  echo "Expected bin/workflow_bus to forward the event limit." >&2
  exit 1
fi

if ! grep -q '^arg\[4\]=5$' "$TSX_LOG"; then
  echo "Expected bin/workflow_bus to forward the event limit value." >&2
  exit 1
fi

: > "$TSX_LOG"
TSX_BIN="$TMP_DIR/tsx" "$ROOT/bin/workflow_bus" --json >/dev/null

if ! grep -q '^arg\[1\]=--json$' "$TSX_LOG"; then
  echo "Expected bin/workflow_bus to forward the json flag." >&2
  exit 1
fi

echo "bin/workflow_bus helper test passed."
