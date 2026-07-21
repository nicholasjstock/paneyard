# Orchestrator Reliability TODO

This checklist comes from the `demo-20260719-091717-8d06` failure review. Items are ordered by containment risk and by the dependencies between fixes.

## Worker containment and identity

- [x] Enforce execution policy at the launcher boundary while retaining Bash: `artifact_only` workers receive a read-only target, and writing workers receive exact-path grants.
- [x] Include the worker's exact `nickname`, `scope`, `runId`, and artifact name in its prompt and environment so `worker_turn` cannot depend on model guesses.
- [x] Authenticate worker-originated MCP calls against the active worker identity instead of trusting caller-supplied `askedBy`, `nickname`, or `scope` values.
- [x] Prevent a worker with a rejected or incomplete handoff from spawning a concurrent replacement that bypasses planner/chaperone routing.

## Process ownership and recovery

- [ ] `StopRunJob` only cascades to `Worker`s, never to `RunCommand`s (`app/jobs/stop_run_job.rb`) — stopping a run leaves any dev servers/recordings it started (e.g. backend, Vite, `record-demo`) running and squatting ports for the next run to trip over. `Orchestrator::RunCommandRunner.stop_all_for_run(run:, reason:)` already does the right thing for a single run; `StopRunJob#perform` just needs to call it alongside `stop_active_workers`. Found 2026-07-21: a `vite --port 5174` process from an earlier stopped run was still alive and orphaned (reparented to pid 1) hours later, contributing to port-collision failures in a later run.

- [x] Keep repository commands inside the Codex/Claude launcher sandbox and worker process group; workers run native commands in the foreground rather than requiring Rails-owned command declarations.
- [x] Treat a worker exit without handoff as a persisted failed step attempt with a stable lineage and failure signature.
- [x] Route repeated equivalent worker failures through the chaperone before another retry. **Known incomplete** — only covers `execution_mode: diagnosis`; see "Chaperone scope" section below for what this misses in practice.
- [x] Preserve and expose the worker's final response for Claude workers, not only Codex workers.

## Chaperone scope — root cause confirmed with run data, fix plan below

The "route repeated equivalent worker failures through the chaperone" item below is checked off, but `run-20260721-141933-116c` (2026-07-21) showed it doesn't actually cover most of what fails in practice. Re-investigated 2026-07-21 against the run's own DB rows and each worker's `last_message` — this is no longer a hypothesis, it's confirmed.

**What actually happened, concretely:** over ~35 minutes, 7 workers (`worker`, `verifier`, `infrastructure`, `infrastructure-1`, `infrastructure-2`, `infrastructure-3`, `worker-1`, `worker-2`) churned on what was fundamentally one problem — backend/frontend port coordination breaking the phone-demo recording. Zero chaperone reviews were created. Two compounding, now-confirmed reasons:

1. **Mode gating (confirmed root cause).** `Orchestrator::ChaperoneTrigger` is only ever called from `Turn.record_diagnosis_attempt` (`app/services/orchestrator/turn.rb:90-93`), which bails out unless `SpawnRequestedWorkers.execution_mode(request) == "diagnosis"`. Every worker in this run ran in `recording`, `verification`, or `infrastructure` mode — never `diagnosis`. Read directly from `last_message` files:
   - `worker-1` (mode `recording`, handoff completed): `"**[BLOCKED]** Phone demo performance measurement could not be completed. ... port configuration mismatch between the running backend (port 3001) and the recording infrastructure (defaults to 3000)."` — a clean, well-evidenced, correctly-tagged `[BLOCKED]` report of the exact root cause.
   - `infrastructure-2` (mode `recording`, handoff completed): `"The measurement attempt is blocked due to missing infrastructure—the frontend and backend app servers are not responding."`
   - `infrastructure-3` (mode `recording`, handoff completed): `"Blocker reported. Planner queued follow-up decision..."`

   All three called `worker_turn` and reported a real, diagnosable blocker. Because `record_diagnosis_attempt` bails on mode before it ever looks at the result text, **none of these three produced a `StepAttempt` row** — they were invisible to `ChaperoneTrigger` even though they self-reported cleanly. Meanwhile the only two `StepAttempt`s that *did* get created (`verifier` and `infrastructure-1`) came from a completely different, already mode-agnostic path: `WorkerReconcileJob#record_failed_attempt` (`app/jobs/worker_reconcile_job.rb:118-136`), which fires when a worker's process dies *without* completing handoff, regardless of mode. So today a worker that silently crashes is more visible to the chaperone than one that correctly reports `[BLOCKED]`/`[FAILED]` in a non-diagnosis mode — exactly backwards. Fix: generalize `record_diagnosis_attempt` to record a `StepAttempt` for any mode (reusing the same outcome-classification logic `WorkerReconcileJob` already has), not just `diagnosis`.
2. **Lineage discontinuity (confirmed, independent).** The planner minted a *different* `lineage_key` on almost every retry of the same blocked objective: `measure-demo-performance`, `acceptance:demo-perf-baseline`, `reduce-demo-pause-durations`, `verify-demo-performance-improvement` (used twice), `infrastructure:demo-servers-startup`, `measure:phone-demo-baseline-runtime`, `diagnosis:record-demo-port-config` — 7 distinct lineage keys for one problem. `ChaperoneTrigger` counts failures *per lineage_key* (`app/services/orchestrator/chaperone_trigger.rb:6-9`), so even with (1) fixed, this run would likely still have looked like 7 first-time attempts rather than one repeated failure. `lineage_key` is planner-controlled (`app/services/orchestrator/planner.rb:108`, defaults to the step's `artifact` name) with nothing forcing continuity across conceptually-identical retries.

**Decided, not just open questions anymore:**
- (1) is a real bug, not deliberate scope — fix by generalizing `record_diagnosis_attempt`/`StepAttempt` creation to every mode.
- (2) is real, and the fix is not to lean on the planner to preserve `lineage_key` — there's already a more stable join in the schema. `AcceptanceCriteria.record_step!` (`acceptance_criteria.rb:112`) writes an `AcceptanceCriterionStep` row linking every dispatched step's `lineage_key` to the (immutable, planner-can't-rename-it) `acceptance_criterion_key` it addresses. Checked against this run's actual rows: 5 distinct `lineage_key`s (`measure-demo-performance`, `verify-demo-performance-improvement`, `infrastructure:demo-servers-startup`, `measure:phone-demo-baseline-runtime`, `diagnosis:record-demo-port-config`) all map to the same `demo-perf-baseline` criterion. Counting blocked/failed `StepAttempt`s per `(run_id, criterion_key)` — resolved via that existing join — instead of per `(run_id, lineage_key, mode)` would have caught this run around the 2nd-3rd attempt, with no new bookkeeping and no dependence on the planner cooperating on naming.
- On the chaperone's action space: **not** giving it new step-authoring power (would duplicate the planner and violate the "curated observability, one decision" boundary in `CLAUDE.md`). Instead, `continue_small`/`promote` should be able to carry a chaperone-revised retry instruction instead of blindly repeating `source.text` verbatim — see plan below. This directly addresses cases like `worker-1`'s, where a bare retry with the identical instruction would just hit the same port mismatch again.

**Agreed follow-up plan (not yet implemented):**
- [ ] Generalize `Turn.record_diagnosis_attempt` (`app/services/orchestrator/turn.rb:90`) to create a `StepAttempt` for any `execution_mode`, not only `diagnosis` — reuse the outcome-classification already duplicated in `WorkerReconcileJob#record_failed_attempt`. Add regression coverage: a `recording`/`infrastructure` mode worker reporting `[BLOCKED]`/`[FAILED]` via `worker_turn` must produce a `StepAttempt` and reach `ChaperoneTrigger`.
- [ ] Rework `ChaperoneTrigger.call` to count failures by acceptance-criterion key, not `lineage_key`: for the triggering attempt's `lineage_key`, look up its `AcceptanceCriterionStep` row(s) to find the criterion(s) it addresses, then count blocked/failed `StepAttempt`s across *every* `lineage_key` that maps to the same criterion (join through `AcceptanceCriterionStep`, not equality on `lineage_key`). Falls back to today's `lineage_key`-only counting for attempts with no criterion link (e.g. `workflow-plan.md` planner-subject reviews). Add regression coverage: two failed attempts under different `lineage_key`s but the same criterion must trigger a review; two failed attempts under different criteria must not.
- [ ] Let `submit_chaperone_decision` accept an optional `revisedInstruction` string, used only for `continue_small`/`promote`. In `Orchestrator::ApplyChaperoneDecision`, the new `SpawnRequest`'s `text:` becomes `revised_instruction.presence || source.text` (context still records `"Chaperone #{action}: #{summary}"`). Update the chaperone agent prompt (`.claude/agents/chaperone.md`) to use it only when the attempts show a concrete, fixable condition (wrong port, stale env, missing prerequisite) that repeating the same instruction would just hit again — not for a plain reasoning retry.
- [ ] Regression coverage for all three above; run `bundle exec rspec` and `bin/rubocop`.

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
