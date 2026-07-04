#!/usr/bin/env bash
# bin/live_claude_workflow_smoke.sh [OPTIONS]
#
# Run a real Claude-worker workflow smoke test through the packaged bin/
# entrypoints. This runs a single supervisor tick via
# bin/supervisor_launcher_claude, waits for the baseline worker roles to
# spawn, verifies bus/worker state, then cleans up.
#
# Note: this path expects worker launches to use the `claude` driver, so
# `claude` must be present in PATH.
#
# Options:
#   --target-root PATH       Workflow target repo to orchestrate
#   --timeout-seconds N      How long to wait for expected workers after the tick
#   --help                   Show this message
#
# Environment:
#   WORKFLOW_LIVE_TARGET_ROOT
#
# Examples:
#   bin/live_claude_workflow_smoke.sh
#   bin/live_claude_workflow_smoke.sh --target-root /Users/stockn/Source/simple-retail-planner/main

set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
DEFAULT_TARGET_ROOT="/Users/stockn/Source/simple-retail-planner/main"
TARGET_ROOT="${WORKFLOW_LIVE_TARGET_ROOT:-$DEFAULT_TARGET_ROOT}"
# The supervisor only reacts to what's already on the bus — it never seeds the
# first request itself, and a real planner subprocess reasoning about the task
# takes minutes, not seconds. 90s was never actually validated against a real
# end-to-end run; 240s gives the planner -> recorder/verifier chain a
# realistic shot at completing within one supervisor process lifetime.
TIMEOUT_SECONDS=240

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  echo "Missing timeout/gtimeout in PATH (macOS: brew install coreutils)." >&2
  exit 1
fi

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-root)
      shift
      TARGET_ROOT="${1:-}"
      ;;
    --timeout-seconds)
      shift
      TIMEOUT_SECONDS="${1:-}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -x "$(command -v claude)" ]]; then
  echo "Missing claude in PATH." >&2
  exit 1
fi

if [[ ! -d "$TARGET_ROOT" ]]; then
  echo "Missing target root: $TARGET_ROOT" >&2
  exit 1
fi

if [[ ! -d "$TARGET_ROOT/front" ]]; then
  echo "Target root does not look like a workflow consumer repo: missing $TARGET_ROOT/front" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
STATE_DIR="$TMP_DIR/state"
LOG_PATH="$TMP_DIR/supervisor.log"
WORKERS_PATH="$STATE_DIR/workers.json"
BUS_PATH="$STATE_DIR/workflow-bus.json"
RUN_ID="live-claude-smoke-$(date +%s)"

mkdir -p "$STATE_DIR"

cleanup() {
  set +e

  if [[ -f "$WORKERS_PATH" ]]; then
    node -e '
      const fs = require("fs")
      const file = process.argv[1]
      const data = JSON.parse(fs.readFileSync(file, "utf8"))
      for (const worker of data.workers || []) {
        if (worker && worker.status === "running" && Number.isInteger(worker.pid) && worker.pid > 0) {
          try { process.kill(worker.pid, "SIGTERM") } catch {}
        }
      }
    ' "$WORKERS_PATH" || true
  fi

  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo "Starting live Claude workflow smoke."
echo "Package root: $ROOT"
echo "Target root: $TARGET_ROOT"
echo "State dir: $STATE_DIR"
echo "Run id: $RUN_ID"

echo "Seeding an initial planner job onto the bus (the supervisor never seeds one itself)."
TSX_BIN="${TSX_BIN:-$ROOT/node_modules/.bin/tsx}"
if [[ ! -x "$TSX_BIN" ]]; then
  echo "Missing tsx binary at $TSX_BIN" >&2
  exit 1
fi
(
  cd "$ROOT"
  WORKFLOW_STATE_DIR="$STATE_DIR" "$TSX_BIN" -e '
    import { createWorkflowBus } from "./scripts/workflow-bus"
    import { queueLongPhoneDemoPlannerJob } from "./scripts/workflow-mcp"
    const bus = createWorkflowBus()
    const request = queueLongPhoneDemoPlannerJob(bus, {
      runId: process.argv[1],
      frontendUrl: process.argv[2],
      task: "Live Claude smoke: verify the baseline workflow spawn chain through the packaged claude-worker supervisor launcher.",
    })
    console.log(`Seeded planner request ${request.requestId}.`)
  ' "$RUN_ID" "http://127.0.0.1:4173"
)

set +e
WORKFLOW_TARGET_ROOT="$TARGET_ROOT" \
WORKFLOW_STATE_DIR="$STATE_DIR" \
  "$TIMEOUT_BIN" "$TIMEOUT_SECONDS" \
  "$ROOT/bin/supervisor_launcher_claude" \
  --run-id="$RUN_ID" \
  --task="Live Claude smoke: verify the baseline workflow spawn chain through the packaged claude-worker supervisor launcher." \
  --scenario=phone \
  --frontend-url=http://127.0.0.1:4173 \
  >"$LOG_PATH" 2>&1
supervisor_status=$?
set -e

if [[ "$supervisor_status" -ne 0 ]]; then
  echo "bin/supervisor_launcher_claude exited with status $supervisor_status." >&2
  echo "" >&2
  echo "Supervisor log:" >&2
  sed -n '1,240p' "$LOG_PATH" >&2 || true
  exit 1
fi

deadline=$((SECONDS + 15))
spawn_ok=false

while (( SECONDS < deadline )); do
  if [[ -f "$WORKERS_PATH" ]]; then
    if node -e '
      const fs = require("fs")
      const file = process.argv[1]
      const data = JSON.parse(fs.readFileSync(file, "utf8"))
      const runningWorkerCount = (data.workers || []).filter((w) => w.status === "running" && w.role === "worker").length
      if (runningWorkerCount >= 2) process.exit(0)
      process.exit(1)
    ' "$WORKERS_PATH"; then
      spawn_ok=true
      break
    fi
  fi

  sleep 1
done

if [[ "$spawn_ok" != true ]]; then
  echo "Timed out waiting for at least 2 concurrent worker-role workers (recorder + verifier) to spawn." >&2
  echo "" >&2
  echo "Supervisor log:" >&2
  sed -n '1,240p' "$LOG_PATH" >&2 || true
  echo "" >&2
  if [[ -f "$WORKERS_PATH" ]]; then
    echo "Observed workers:" >&2
    WORKFLOW_TARGET_ROOT="$TARGET_ROOT" "$ROOT/bin/workflow_workers" --path "$WORKERS_PATH" >&2 || true
  fi
  exit 1
fi

node -e '
  const fs = require("fs")
  const workers = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  const bus = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
  const running = (workers.workers || []).filter((w) => w.status === "running")
  const roles = running.map((w) => w.role).sort()
  const eventTypes = (bus.events || []).map((event) => event.type)
  const openRequests = (bus.spawnRequests || []).filter((request) => request.status === "open")

  const assert = (condition, message) => {
    if (!condition) {
      console.error(message)
      process.exit(1)
    }
  }

  const workerRoleCount = roles.filter((role) => role === "worker").length
  assert(workerRoleCount >= 2, `expected at least 2 running 'worker' role workers (recorder + verifier), saw ${workerRoleCount}`)
  assert(eventTypes.includes("run.status"), "run.status event was not recorded")
  assert(eventTypes.includes("spawn_request.created"), "spawn_request.created event was not recorded")
  assert(eventTypes.includes("worker.spawned"), "worker.spawned event was not recorded")
  assert(openRequests.length === 0, `expected no open spawn requests after fulfillment, saw ${openRequests.length}`)
  console.log(JSON.stringify({
    runningRoles: roles,
    eventTypes,
    openSpawnRequests: openRequests.length,
  }, null, 2))
' "$WORKERS_PATH" "$BUS_PATH"

echo "Live Claude workflow smoke passed."
