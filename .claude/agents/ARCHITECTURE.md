# Multi-Agent Workflow Architecture

## Current Deployment: Demo Video Production

This orchestration pattern (supervisor → orchestrator → planner → workers, a shared bus, and MCP-managed worker lifecycle) is a reusable workflow shape, not something specific to video recording. The concrete deployment configured today produces the Simple Retail Planner product demo video using a single generic `@worker` role: it records, verifies, and applies scoped fixes, whichever the current bus request/prompt describes. A different deployment could swap in different worker prompts for a different task while keeping the same supervisor/orchestrator/bus machinery.

## System Overview

Three agents work together in a hierarchy, plus deterministic orchestrator loop logic:

> Codex note: the parallel Codex-native setup lives in [`.codex/agents`](../../.codex/agents/README.md). Both Claude and Codex share the same `workflow` MCP server (registered at repo root in `.mcp.json` for Claude), so the bus, worker state, and artifacts are visible across both CLI paths.

```
┌────────────────────────────────────────────────────────┐
│                  USER                                  │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ↓
┌────────────────────────────────────────────────────────┐
│          @supervisor (LOOP OWNER)                      │
│    Run orchestrator turns, spawn workers, iterate      │
└───┬──────────────┬─────────────────────────────────────┘
    │              │
  ┌─↓──┐      ┌────↓──────┐
  │    │      │            │
  ↓    ↓      ↓            ↓
 ┌──────────┐
 │ @worker  │  ... exactly one at a time — execution is
 │(EXECUTOR)│      strictly sequential, per the planner's
 └────┬─────┘      nextStep/followingSteps decision
      │
      └─→ @planner (implicit)
          called when stuck
          ↑
          └──── called by supervisor's
               orchestrator turns
```

Not shown above: each worker instance also calls `worker_turn` (a deterministic MCP tool, not a subagent) when it finishes — this spawns a fresh @planner instance, handing it the result and the current `followingSteps` queue, so *that* planner is the one that decides and publishes the next step. This happens independent of the `@planner (implicit)` stuck-help path shown here.

## The Complete Loop

```
User Request
    ↓
Record → Verify → Implement → Record → Verify → Report
    ↑                                               ↓
    └───────────────── Iterate if needed ─────────┘
```

## Agent Responsibilities

### Level 0/2: Execution (single generic role)
**@worker** (Executor)
- **Responsibility:** Whatever the current bus request/prompt describes — recording a demo, verifying/analyzing artifacts, or applying an isolated scoped fix (frontend, backend, infra, or otherwise). The write scope for a fix task (e.g. `front/**`, `back/**`) comes from the task's prompt, not from a fixed identity.
- **Called by:** the supervisor, spawned for whichever single `nextStep` the current planner instance just decided
- **Inputs:** Recording parameters, a video/artifact file path plus expected flow, or a verifier finding plus write scope — depending on the task
- **Outputs:** Video file path, analysis report, or fix diff plus verification result — depending on the task
- **Calls:** @planner when stuck (syntax errors, diagnostic help, unclear state); reports every completion via `worker_turn`, which spawns a fresh @planner to decide what happens next

### Level 1: Workflow Control
**Orchestrator** (deterministic loop logic, not a separate agent)
- **Responsibility:** Detect stalls — it never decides real work itself
- **Inputs:** Execution request from the user, current bus/worker state
- **Outputs:** Nothing, on a normal tick (a true no-op); on a stall, a spawn request for a recovery @planner
- **Calls:** Nothing directly — publishes a spawn request that the supervisor turns into a spawn
- **When to call @planner:** Only when a worker has stalled (gone idle past the stall threshold) and needs a recovery decision.

### Level 3: Planning (Implicit)
**@planner** (Helper)
- **Responsibility:** Decide the single next step (`nextStep`) plus the queue for later (`followingSteps`), and publish that decision to the bus — never execute it. This is the only place real work gets decided; execution is strictly sequential, one step in flight at a time, so there is no dependency graph to manage.
- **Inputs:** Current bus/worker state, the reporting worker's result (or, for stall recovery, the stall finding), and the `followingSteps` queue handed down from the previous planner invocation
- **Outputs:** A `planner_turn` call (`nextStep`, possibly `null`, plus `followingSteps`) or an `append_user_question` call — always exactly one of these per turn
- **Calls:** No one (it is only consulted when needed)

## Communication Flows

### Happy Path
```
User: @supervisor run the full workflow

@supervisor (iteration 1):
  1. Call orchestrator → plan
  2. Orchestrator decides: spawn @worker (recording task)
  3. Spawn @worker
     ✅ Returns: video file
  
  4. Call orchestrator → re-plan
  5. Orchestrator decides: spawn @worker (verification task)
  6. Spawn @worker
     ✅ Returns: analysis report
  
  7. Call orchestrator → re-plan
  8. Orchestrator decides: run complete
  
@supervisor reports final result to user
```

### Error Recovery Path
```
User: @supervisor run the full workflow

@supervisor (iteration 1):
  1. Call orchestrator → plan
  2. Orchestrator decides: spawn @worker (recording task)
  3. Spawn @worker
     ❌ Returns: esbuild compilation error

@worker:
  → Call @planner for recovery plan

@supervisor (iteration 2):
  4. Call orchestrator → re-plan (sees stalled worker)
  5. Orchestrator decides: spawn @worker (scoped fix task, front/** scope)
  6. Spawn @worker
     ✅ Fix applied
  
  7. Call orchestrator → re-plan
  8. Orchestrator decides: re-spawn @worker (recording task)
  9. Spawn @worker
     ✅ Returns: video file
  
  10. Continue iterating until complete
```

## Coordination Rules

- **@supervisor** owns the main workflow loop and iteration control.
- **@supervisor** calls orchestrator planning logic each iteration via `run_orchestrator_turn`.
- **@supervisor** spawns workers via MCP-managed workers based on orchestrator decisions.
- **@supervisor** deduplicates requests by `(runId, requestedRole, scope)` and publishes `worker_spawned` events.
- **Orchestrator** never decides real work itself. A normal tick is a pure no-op; the only thing it ever does is detect a stalled worker and publish a spawn request for a recovery @planner (via the same `appendSpawnRequest` path @planner's `planner_turn` uses).
- **@worker** calls `worker_turn` when it finishes; this always spawns a fresh @planner instance (unless one is already active for the run) with the reported result and the current `followingSteps` queue as context, so that planner decides and publishes the actual next step. @worker calls @planner directly only when it's stuck mid-task and needs help — a different path from the automatic post-completion spawn.
- **@planner** never calls other agents or spawns workers; every planner turn ends by calling `planner_turn` (with `nextStep`, or `null` if none needed, plus `followingSteps`) or `append_user_question` — never silently.
- If a worker needs a missing downstream role, append a spawn request to the shared bus with the `requestedRole`.
- The user sees the result of implicit calls, not the internal planning chatter.
- All agents use the structured messaging protocol from [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).
