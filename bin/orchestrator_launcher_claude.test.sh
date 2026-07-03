#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TARGET_ROOT="/Users/stockn/Source/simple-retail-planner/main"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CLAUDE_LOG="$TMP_DIR/claude.log"

cat > "$TMP_DIR/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${CLAUDE_LOG_PATH:?}"

{
  printf 'cwd=%s\n' "$PWD"
  printf 'argc=%s\n' "$#"
  idx=0
  for arg in "$@"; do
    printf 'arg[%s]=%s\n' "$idx" "$arg"
    idx=$((idx + 1))
  done
} >> "$log_path"
EOF
chmod +x "$TMP_DIR/claude"

PATH="$TMP_DIR:$PATH" \
CLAUDE_LOG_PATH="$CLAUDE_LOG" \
CLAUDE_BIN="$TMP_DIR/claude" \
  "$ROOT/bin/orchestrator_launcher_claude" \
    --run-id=demo-2026-07-03 \
    --task="Coordinate the next handoff." \
    --scenario=both \
    --frontend-url=http://localhost:5174 \
    --stale-after-ms=60000 \
    >/dev/null

if ! grep -q "^cwd=$DEFAULT_TARGET_ROOT$" "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to default WORKFLOW_TARGET_ROOT to $DEFAULT_TARGET_ROOT and run from there for MCP config access." >&2
  cat "$CLAUDE_LOG"
  exit 1
fi

if ! grep -q -- '^arg\[[0-9]\+\]=--agent$' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to select an agent via --agent." >&2
  exit 1
fi

if ! grep -q '^arg\[[0-9]\+\]=demo-pipeline$' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to select the existing demo-pipeline orchestrator agent (auto-discovered from .claude/agents), not an ad hoc --agents definition." >&2
  cat "$CLAUDE_LOG"
  exit 1
fi

if grep -q -- '^arg\[[0-9]\+\]=--agents$' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to not pass --agents; demo-pipeline is already a registered agent." >&2
  cat "$CLAUDE_LOG"
  exit 1
fi

if ! grep -q -- '^arg\[[0-9]\+\]=--permission-mode$' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to set a permission mode." >&2
  exit 1
fi

if ! grep -q '^arg\[[0-9]\+\]=bypassPermissions$' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to bypass permission prompts for unattended runs." >&2
  exit 1
fi

if ! grep -q -- '^arg\[[0-9]\+\]=-p$' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to run claude in non-interactive print mode for a single tick." >&2
  exit 1
fi

if ! grep -q 'Launch the orchestrator for the current run' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to include the launch task in the prompt." >&2
  exit 1
fi

if ! grep -q 'Use only MCP tools for orchestration and state inspection' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to make MCP-only permissions explicit." >&2
  exit 1
fi

if ! grep -q 'runId: demo-2026-07-03' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to pass through --run-id." >&2
  exit 1
fi

if ! grep -q 'scenario: both' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to pass through --scenario." >&2
  exit 1
fi

if ! grep -q 'frontendUrl: http://localhost:5174' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to pass through --frontend-url." >&2
  exit 1
fi

if ! grep -q 'staleAfterMs: 60000' "$CLAUDE_LOG"; then
  echo "Expected bin/orchestrator_launcher_claude to pass through --stale-after-ms." >&2
  exit 1
fi

echo "bin/orchestrator_launcher_claude launcher test passed."

# --- Retry behavior: claude -p can race the workflow MCP server's stdio
# handshake and run a turn with zero mcp__workflow__* tools available. The
# launcher should detect that signature and retry a bounded number of times.

RETRY_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" "$RETRY_TMP_DIR"' EXIT

RETRY_COUNTER_FILE="$RETRY_TMP_DIR/attempts.count"
RETRY_LOG="$RETRY_TMP_DIR/claude.log"
echo 0 > "$RETRY_COUNTER_FILE"

cat > "$RETRY_TMP_DIR/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

counter_file="${RETRY_COUNTER_FILE:?}"
log_path="${RETRY_LOG_PATH:?}"
succeed_on_attempt="${SUCCEED_ON_ATTEMPT:-1}"

attempt="$(($(cat "$counter_file") + 1))"
echo "$attempt" > "$counter_file"
echo "attempt=$attempt" >> "$log_path"

if [[ "$attempt" -lt "$succeed_on_attempt" ]]; then
  echo "The \`workflow\` MCP server is still connecting, so its tools aren't loaded yet."
else
  echo "run_orchestrator_turn completed successfully."
fi
EOF
chmod +x "$RETRY_TMP_DIR/claude"

# Case 1: fails twice (no workflow tools yet), then succeeds on the third try.
: > "$RETRY_LOG"
echo 0 > "$RETRY_COUNTER_FILE"
retry_output="$(
  PATH="$RETRY_TMP_DIR:$PATH" \
  RETRY_COUNTER_FILE="$RETRY_COUNTER_FILE" \
  RETRY_LOG_PATH="$RETRY_LOG" \
  CLAUDE_BIN="$RETRY_TMP_DIR/claude" \
  SUCCEED_ON_ATTEMPT=3 \
  ORCHESTRATOR_CLAUDE_RETRY_DELAY_SECONDS=0 \
    "$ROOT/bin/orchestrator_launcher_claude" --run-id=demo-retry 2>&1
)"
retry_exit=$?

if [[ "$retry_exit" -ne 0 ]]; then
  echo "Expected bin/orchestrator_launcher_claude to succeed once claude connects to the workflow server within the retry budget." >&2
  echo "$retry_output" >&2
  exit 1
fi

if [[ "$(cat "$RETRY_COUNTER_FILE")" -ne 3 ]]; then
  echo "Expected bin/orchestrator_launcher_claude to retry exactly until success (3 attempts)." >&2
  cat "$RETRY_LOG" >&2
  exit 1
fi

if [[ "$retry_output" != *"run_orchestrator_turn completed successfully."* ]]; then
  echo "Expected bin/orchestrator_launcher_claude to print the successful attempt's output." >&2
  echo "$retry_output" >&2
  exit 1
fi

# Case 2: never connects; launcher must give up after a bounded number of attempts.
: > "$RETRY_LOG"
echo 0 > "$RETRY_COUNTER_FILE"
set +e
give_up_output="$(
  PATH="$RETRY_TMP_DIR:$PATH" \
  RETRY_COUNTER_FILE="$RETRY_COUNTER_FILE" \
  RETRY_LOG_PATH="$RETRY_LOG" \
  CLAUDE_BIN="$RETRY_TMP_DIR/claude" \
  SUCCEED_ON_ATTEMPT=999 \
  ORCHESTRATOR_CLAUDE_RETRY_DELAY_SECONDS=0 \
  ORCHESTRATOR_CLAUDE_MAX_ATTEMPTS=3 \
    "$ROOT/bin/orchestrator_launcher_claude" --run-id=demo-retry 2>&1
)"
give_up_exit=$?
set -e

if [[ "$give_up_exit" -eq 0 ]]; then
  echo "Expected bin/orchestrator_launcher_claude to fail once retries are exhausted without a successful connection." >&2
  echo "$give_up_output" >&2
  exit 1
fi

if [[ "$(cat "$RETRY_COUNTER_FILE")" -ne 3 ]]; then
  echo "Expected bin/orchestrator_launcher_claude to stop retrying at ORCHESTRATOR_CLAUDE_MAX_ATTEMPTS (3), got $(cat "$RETRY_COUNTER_FILE") attempts." >&2
  cat "$RETRY_LOG" >&2
  exit 1
fi

echo "bin/orchestrator_launcher_claude retry test passed."
