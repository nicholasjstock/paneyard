#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TSX_LOG="$TMP_DIR/launcher.log"
STDIN_LOG="$TMP_DIR/stdin.log"

cat > "$TMP_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${CODEX_LOG_PATH:?}"
stdin_path="${CODEX_STDIN_PATH:?}"

{
  printf 'argc=%s\n' "$#"
  printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}"
  idx=0
  for arg in "$@"; do
    printf 'arg[%s]=%s\n' "$idx" "$arg"
    idx=$((idx + 1))
  done
} >> "$log_path"

workspace=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C)
      workspace="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$workspace" ]]; then
  echo "missing workspace" >&2
  exit 1
fi

if [[ "$workspace" == *"/Users/stockn/Source/simple-retail-planner/main"* ]]; then
  echo "workspace should be empty and outside the repo" >&2
  exit 1
fi

if [[ -n "$(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "workspace is not empty" >&2
  exit 1
fi

cat > "$stdin_path"
EOF
chmod +x "$TMP_DIR/codex"

PATH="$TMP_DIR:$PATH" \
CODEX_LOG_PATH="$TSX_LOG" \
CODEX_STDIN_PATH="$STDIN_LOG" \
  "$ROOT/bin/orchestrator_launcher" >/dev/null

code_home_path="$(sed -n 's/^CODEX_HOME=//p' "$TSX_LOG")"
if [[ -z "$code_home_path" ]]; then
  echo "Expected bin/orchestrator_launcher to set an isolated CODEX_HOME." >&2
  exit 1
fi

if [[ "$code_home_path" == *"/Users/stockn/Source/simple-retail-planner/main"* ]]; then
  echo "Expected CODEX_HOME to live outside the repo." >&2
  exit 1
fi

profile_path="$code_home_path/orchestrator.config.toml"
if [[ ! -f "$profile_path" ]]; then
  echo "Expected bin/orchestrator_launcher to create a dedicated orchestrator profile." >&2
  exit 1
fi

if ! grep -q '^arg\[0\]=exec$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to invoke `codex exec`." >&2
  exit 1
fi

if ! grep -q '^arg\[1\]=--profile$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to select the orchestrator profile." >&2
  exit 1
fi

if ! grep -q '^arg\[2\]=orchestrator$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to use the orchestrator profile." >&2
  exit 1
fi

if ! grep -q '^arg\[3\]=--sandbox$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to set a read-only sandbox." >&2
  exit 1
fi

if ! grep -q '^arg\[4\]=read-only$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to use read-only sandboxing." >&2
  exit 1
fi

if ! grep -q '^arg\[5\]=--dangerously-bypass-hook-trust$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to trust its generated hooks for this run." >&2
  exit 1
fi

if ! grep -q '^arg\[6\]=-C$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to set an isolated workspace." >&2
  exit 1
fi

if ! grep -q '^arg\[8\]=--skip-git-repo-check$' "$TSX_LOG"; then
  echo "Expected bin/orchestrator_launcher to skip git repo checks in the empty workspace." >&2
  exit 1
fi

if ! grep -q 'name = "orchestrator"' "$STDIN_LOG"; then
  echo "Expected bin/orchestrator_launcher to feed the orchestrator prompt." >&2
  exit 1
fi

if ! grep -q 'Launch the orchestrator for the current run' "$STDIN_LOG"; then
  echo "Expected bin/orchestrator_launcher to append the launch task." >&2
  exit 1
fi

if ! grep -q 'Use only MCP tools for orchestration and state inspection' "$STDIN_LOG"; then
  echo "Expected bin/orchestrator_launcher to make MCP-only permissions explicit." >&2
  exit 1
fi

if ! grep -q 'run exactly one orchestration tick' "$STDIN_LOG"; then
  echo "Expected bin/orchestrator_launcher to constrain the orchestrator to one tick." >&2
  exit 1
fi

if ! grep -q '^approval_policy = "never"$' "$profile_path"; then
  echo "Expected the orchestrator profile to disable approvals." >&2
  exit 1
fi

if ! grep -q '^sandbox_mode = "read-only"$' "$profile_path"; then
  echo "Expected the orchestrator profile to force read-only sandboxing." >&2
  exit 1
fi

if ! grep -q '^allow_login_shell = false$' "$profile_path"; then
  echo "Expected the orchestrator profile to disable login shells." >&2
  exit 1
fi

if ! grep -q '^required = true$' "$profile_path"; then
  echo "Expected the workflow MCP server to be required in the orchestrator profile." >&2
  exit 1
fi

if ! grep -q '^default_tools_approval_mode = "approve"$' "$profile_path"; then
  echo "Expected the workflow MCP server to keep its explicit tool approval mode." >&2
  exit 1
fi

if ! grep -Fq 'args = ["wf-mcp-server"]' "$profile_path"; then
  echo "Expected the orchestrator profile to invoke the packaged wf-mcp-server binary." >&2
  exit 1
fi

if ! grep -Fq "cwd = \"$ROOT/front\"" "$profile_path"; then
  echo "Expected the orchestrator profile to point MCP cwd at the target repo front/ directory." >&2
  exit 1
fi

if ! grep -Fq "env = { WORKFLOW_TARGET_ROOT = \"$ROOT\", WORKFLOW_STATE_DIR = \"\" }" "$profile_path"; then
  echo "Expected the orchestrator profile to pass WORKFLOW_TARGET_ROOT and WORKFLOW_STATE_DIR through to the MCP server." >&2
  exit 1
fi

if ! grep -Fq 'matcher = "^(Bash|apply_patch|Edit|Write)$"' "$profile_path"; then
  echo "Expected the orchestrator profile to block non-MCP tool use." >&2
  exit 1
fi

echo "bin/orchestrator_launcher launcher test passed."
