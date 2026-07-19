# Orchestrator Reliability TODO

This checklist comes from the `demo-20260719-091717-8d06` failure review. Items are ordered by containment risk and by the dependencies between fixes.

## Worker containment and identity

- [x] Enforce execution policy at the launcher boundary while retaining Bash: `artifact_only` workers receive a read-only target, and writing workers receive exact-path grants.
- [x] Include the worker's exact `nickname`, `scope`, `runId`, and artifact name in its prompt and environment so `worker_turn` cannot depend on model guesses.
- [x] Authenticate worker-originated MCP calls against the active worker identity instead of trusting caller-supplied `askedBy`, `nickname`, or `scope` values.
- [x] Prevent a worker with a rejected or incomplete handoff from spawning a concurrent replacement that bypasses planner/chaperone routing.

## Process ownership and recovery

- [x] Keep repository commands inside the Codex/Claude launcher sandbox and worker process group; workers run native commands in the foreground rather than requiring Rails-owned command declarations.
- [x] Treat a worker exit without handoff as a persisted failed step attempt with a stable lineage and failure signature.
- [x] Route repeated equivalent worker failures through the chaperone before another retry.
- [x] Preserve and expose the worker's final response for Claude workers, not only Codex workers.

## State and integration correctness

- [x] Deduplicate unchanged `run.status` events, especially the five-second `waiting_on_capacity` update.
- [x] Enforce command safety at the Codex/Claude launcher boundary without requiring workspace-owned orchestrator configuration.
- [x] Add deterministic generic preflight checks for only the target root and selected launcher.
- [x] Make local orchestrator startup fail early with an actionable dependency/setup message and document the recovery command.

## Verification

- [x] Add regression coverage for policy enforcement, identity injection, authenticated spawn/handoff calls, durable command ownership, failed-attempt persistence, chaperone routing, event deduplication, and service-specific health checks.
- [x] Run the full RSpec suite and RuboCop.
- [ ] Start a fresh phone-demo run and verify that its sandboxed worker discovers and runs the repository's native baseline command, or reports one precise, recoverable native-command blocker.
  - Fresh run `run-20260719-105857-e314` is resumably waiting on a real Claude 429 capacity reset at 14:10 Europe/Paris; its planner request remains open and no model tokens were consumed. Continue observing after capacity returns.
