#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TSX_LOG="$TMP_DIR/tsx.log"
TAIL_LOG="$TMP_DIR/tail.log"

cat > "$TMP_DIR/tsx" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if printf '%s\n' "\$*" | grep -q -- '--log-path'; then
  printf '/tmp/workflow-workers/front-fixer.log\n'
  exit 0
fi
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

cat > "$TMP_DIR/tail" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TAIL_LOG"
EOF
chmod +x "$TMP_DIR/tail"

PATH="$TMP_DIR:$PATH" TSX_BIN="$TMP_DIR/tsx" "$ROOT/bin/workflow_worker_follow" front-fixer --tail 12 --path /tmp/workers.json >/dev/null || true

if ! grep -q '^-n 12 -F /tmp/workflow-workers/front-fixer.log$' "$TAIL_LOG"; then
  echo "Expected bin/workflow_worker_follow to tail the resolved worker log path." >&2
  exit 1
fi

echo "bin/workflow_worker_follow helper test passed."
