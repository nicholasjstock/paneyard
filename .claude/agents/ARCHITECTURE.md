# Multi-Agent Workflow Architecture

## System Overview

Rails owns orchestration state, planning, retries, and process dispatch (see [AGENTS.md](../../AGENTS.md) and [CLAUDE.md](../../CLAUDE.md)). There is no supervisor loop, no planner agent process, and no fixed set of workers running in parallel — a run has at most one active worker (or one bounded planner decision, or one chaperone review) at a time. What lives in this directory is the persona prompt layered onto whichever subagent process Rails decides to spawn next.

> Codex note: the parallel Codex-native setup lives in [`.codex/agents`](../../.codex/agents/README.md). Both Claude and Codex share the same `workflow` MCP server (`.mcp.json`), so the bus, worker state, and artifacts are visible across both CLI paths within the same run.

```
┌──────────────────────────────────────────────────────────┐
│                         USER                              │
└───────────────────────────┬────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│  TickRunJob (recurring Rails job)                         │
│  - executor + liveness observer, not a second planner     │
│  - detects stalls / dead ends, requests recovery planning │
│  - drives Orchestrator::SpawnRequestedWorkers each tick    │
└───┬─────────────────────┬─────────────────────┬───────────┘
    │                     │                     │
    ↓                     ↓                     ↓
 spawn one           run one bounded        dispatch a
 Worker subagent     PlannerDecisionJob      chaperone review
 (worker/verifier/   (tools disabled,        (repeated failure
 infrastructure/     structured output       under one lineage)
 project_init/       only -- no OS
 reporter/curator/   process spawned)
 seeder/demo/
 committer)
```

Execution is strictly sequential: `Orchestrator::SpawnRequestedWorkers.call_locked` (`app/services/orchestrator/spawn_requested_workers.rb`) refuses to spawn anything while a worker is already `running` for the run, or while a `PlannerDecision` is `queued`/`running`, or (except for its own reviewer) while a `ChaperoneReview` is open.

## The Run Lifecycle

```
worker executes its assigned task
    ↓
worker_turn: [DONE] | [BLOCKED] | [FAILED]
    ↓
[DONE] + a validated followingSteps queue → Rails promotes the next step directly (no planner call)
otherwise                                  → Rails queues one bounded PlannerDecisionJob
    ↓
planner_turn: nextStep (+ followingSteps) | needs_context | needs_stronger_model
    ↓
Rails dispatches nextStep, resolves needs_context and reruns, or reruns on the stronger tier
    ↓
... repeats until the run's following-steps queue and acceptance criteria are satisfied ...
    ↓
run reaches phase "completed" → finalization pipeline (below)
```

## Planning: a bounded decision function, not an agent

A planner turn is not a spawned process — it is one `PlannerDecisionJob` run with tools disabled, built from a compact brief (`Orchestrator::PlannerBrief`) and validated/persisted by `Orchestrator::Turn`. Every turn returns exactly one of:

- `nextStep` (+ `followingSteps`) — the single next unit of work, queued for direct promotion after that worker's `[DONE]`.
- `needs_context` — one `contextRequest` (`source`, `reference`, `question`, `offset`, `maxChars`); Rails resolves it and reruns with accumulated context. An identical repeated request is rejected since it cannot add information.
- `needs_stronger_model` — Rails reruns the same decision on the stronger tier with unchanged context; the promotion is recorded.

Planning always starts on the smaller model tier. See [AGENTS.md](../../AGENTS.md)'s Planner Context Protocol section for the exact contract, and `app/jobs/planner_decision_job.rb` / `app/services/orchestrator/{planner_brief,planner_context_resolver,planner_decision_runner,turn}.rb` for the implementation.

## Recovery and the chaperone

`TickRunJob` detects two conditions worth escalating: a worker stalled (running but idle past threshold), or a dead-ended run (no active worker, no open request, never marked `completed`). Either publishes a spawn request for a recovery planner decision — suppressed while a `blocking` `UserQuestion` is already open, so the same stall is never re-escalated twice.

Repeated unsuccessful attempts under one stable `lineageKey` trigger a **chaperone** (`chaperone.md`, `sonnet`): a strong-model review confined to the capability-scoped `/mcp/chaperone` endpoint (`Orchestrator::ChaperoneMcpServer` — curated state, bounded artifact reads, and a single `submit_chaperone_decision` call). It decides `continue_small`, `promote`, or `stop`; it never gets arbitrary SQL, filesystem, or shell access.

## Finalization pipeline

Once a run reaches `phase: "completed"`, `TickRunJob#finalize_completed_run` queues five terminal roles strictly in sequence, each with its own narrow MCP tool slice (`Orchestrator::WorkerMcpServer`) and its own role check inside the tools it's allowed to call:

```
run completed
  → seeder     (write_scoped_file, write seed-data.md,             → complete_run_finalization
                report clickPath = verification steps)
  → reporter   (get_run_audit, write run-summary.md)               → complete_run_finalization
  → curator    (select_review_assets, write review-assets.md)      → complete_run_finalization
  → demo       (start_run_command, write demo-notes.md)            → complete_run_finalization
  → committer  (list_git_change_requests, commit_run_changes)       -- terminal, no handoff call
  → Rails pushes the branch, creates a draft evidence release,
    uploads curator's selected assets, opens the PR with the
    reporter's summary (which already includes the seeder's
    verification steps, read back via get_run_audit)
  → approval → Rails deletes the draft release, merges, removes the worktree
```

Seeder runs first, ahead of reporter and curator, for two reasons: the reporter's audit must be able to describe what was seeded and how to verify it, and the demo role needs the seeded data to already exist. Seeder — not demo — owns the reviewer-facing verification steps (`complete_run_finalization`'s `clickPath` parameter, the same field `worker_turn` also exposes to ordinary workers): it is the only finalization role with both full task context (`get_run_context`) and knowledge of exactly what data now exists, where demo has neither and is purely mechanical (start/reuse the server, confirm it is listening). Reporter, curator, and seeder must explicitly call `complete_run_finalization` after writing their assigned artifact; committer only commits and never calls it. Unlike every other finalization role, seeder is spawned with `write_scope: "scoped_changes"` and the workspace's full `protected_write_patterns` — the same wholesale grant an implementation worker gets — because its entire job is writing real seed/fixture files for the committer to pick up afterward. Any `run_commands` process the demo role starts (or any other worker leaves running) is stopped automatically once the run reaches a terminal status (`Run#stop_active_run_commands`) — no manual cleanup step is needed.

## Coordination Rules

- Rails (`TickRunJob` + `Orchestrator::SpawnRequestedWorkers`) is the only thing that spawns processes; no agent spawns another agent directly.
- A worker never manages its own lifecycle (no `spawn_worker`/`stop_worker`); it reports via `worker_turn` and Rails decides what happens next.
- If a worker needs a missing downstream capability, it raises `[BLOCKED]` through `worker_turn` (or, mid-task, asks a spawned planner) rather than acting outside its assigned scope.
- Finalization roles never call each other's tools — `Orchestrator::WorkerMcpServer` and each tool's own role guard enforce that independently.
- All agents use the structured messaging protocol from [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).
