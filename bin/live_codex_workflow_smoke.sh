#!/usr/bin/env bash
# bin/live_codex_workflow_smoke.sh [OPTIONS]
#
# Run a real Codex-driven workflow smoke test through the packaged bin/
# entrypoints. This launches the actual supervisor loop, waits for the
# baseline worker roles to spawn, verifies bus/worker state, then cleans up.
#
# Options:
#   --target-root PATH       Workflow target repo to orchestrate
#   --timeout-seconds N      How long to wait for expected workers
#   --interval-ms N          Supervisor loop interval during the smoke
#   --help                   Show this message
#
# Environment:
#   WORKFLOW_LIVE_TARGET_ROOT
#
# Examples:
#   bin/live_codex_workflow_smoke.sh
#   bin/live_codex_workflow_smoke.sh --target-root /Users/stockn/Source/simple-retail-planner/main

set -euo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
DEFAULT_TARGET_ROOT="/Users/stockn/Source/simple-retail-planner/main"
TARGET_ROOT="${WORKFLOW_LIVE_TARGET_ROOT:-$DEFAULT_TARGET_ROOT}"
TIMEOUT_SECONDS=45
INTERVAL_MS=1000

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
    --interval-ms)
      shift
      INTERVAL_MS="${1:-}"
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

if [[ ! -x "$(command -v codex)" ]]; then
  echo "Missing codex in PATH." >&2
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
RUN_ID="live-codex-smoke-$(date +%s)"
SUPERVISOR_PID=""

mkdir -p "$STATE_DIR"

cleanup() {
  set +e

  if [[ -n "$SUPERVISOR_PID" ]] && kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
    kill "$SUPERVISOR_PID" 2>/dev/null || true
    wait "$SUPERVISOR_PID" 2>/dev/null || true
  fi

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

echo "Starting live Codex workflow smoke."
echo "Package root: $ROOT"
echo "Target root: $TARGET_ROOT"
echo "State dir: $STATE_DIR"
echo "Run id: $RUN_ID"

WORKFLOW_TARGET_ROOT="$TARGET_ROOT" \
WORKFLOW_STATE_DIR="$STATE_DIR" \
  "$ROOT/bin/supervisor_launcher" \
  --run-id="$RUN_ID" \
  --task="Live Codex smoke: verify the baseline workflow spawn chain through the packaged supervisor launcher." \
  --scenario=phone \
  --frontend-url=http://127.0.0.1:4173 \
  --interval-ms="$INTERVAL_MS" \
  >"$LOG_PATH" 2>&1 &

SUPERVISOR_PID=$!

deadline=$((SECONDS + TIMEOUT_SECONDS))
spawn_ok=false

while (( SECONDS < deadline )); do
  if [[ -f "$WORKERS_PATH" ]]; then
    if node -e '
      const fs = require("fs")
      const file = process.argv[1]
      const data = JSON.parse(fs.readFileSync(file, "utf8"))
      const running = new Set((data.workers || []).filter((w) => w.status === "running").map((w) => w.role))
      if (running.has("demo_recorder") && running.has("demo_verifier")) process.exit(0)
      process.exit(1)
    ' "$WORKERS_PATH"; then
      spawn_ok=true
      break
    fi
  fi

  if [[ -n "$SUPERVISOR_PID" ]] && ! kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
    echo "Supervisor exited before expected workers appeared." >&2
    break
  fi

  sleep 1
done

if [[ "$spawn_ok" != true ]]; then
  echo "Timed out waiting for demo_recorder and demo_verifier to spawn." >&2
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

  assert(roles.includes("demo_recorder"), "demo_recorder was not left running")
  assert(roles.includes("demo_verifier"), "demo_verifier was not left running")
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

echo "Live Codex workflow smoke passed."
