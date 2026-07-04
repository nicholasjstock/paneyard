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
 ┌──────────┐ ┌──────────┐
 │ @worker  │ │ @worker  │  ... as many concurrent instances
 │(EXECUTOR)│ │(EXECUTOR)│      as the plan calls for
 └────┬─────┘ └────┬─────┘
      │            │
      └─→ @planner (implicit)
          called when stuck
          ↑
          └──── called by supervisor's
               orchestrator turns
```

Not shown above: each worker instance also calls `worker_turn` (a deterministic MCP tool, not a subagent) when it finishes — this feeds the worker's result into the planner's routing logic and publishes the next steps to the bus directly, independent of the `@planner (implicit)` stuck-help path shown here.

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
- **Called by:** the deterministic orchestrator logic, whenever the plan needs a recording, verification, or fix step
- **Inputs:** Recording parameters, a video/artifact file path plus expected flow, or a verifier finding plus write scope — depending on the task
- **Outputs:** Video file path, analysis report, or fix diff plus verification result — depending on the task
- **Calls:** @planner when stuck (syntax errors, diagnostic help, unclear state); reports every completion via `worker_turn`

### Level 1: Workflow Control
**Orchestrator** (deterministic loop logic, not a separate agent)
- **Responsibility:** Coordinate the entire workflow
- **Inputs:** Execution request from the user, current bus/worker state
- **Outputs:** Complete report with findings
- **Calls:** @worker (one or more concurrent instances)
- **When to call @planner:** Complex workflows, coordination issues, stalled/unresponsive workers

### Level 3: Planning (Implicit)
**@planner** (Helper)
- **Responsibility:** Create step-by-step plans
- **Inputs:** Task description from any agent
- **Outputs:** Structured plan with steps, dependencies, error handling
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
- **Orchestrator** (called by @supervisor) publishes work decisions to the bus via `append_question` (kind: `worker_request`).
- **Orchestrator** calls @planner when it needs help deciding the next work order.
- When spawning a scoped fix task, orchestrator should first call @planner to analyze verifier findings and decide the write scope.
- **@worker** calls `worker_turn` when it finishes (deterministically routes its result to the planner's logic and publishes next steps) and calls @planner directly only when it's stuck mid-task and needs help.
- **@planner** never calls other agents or spawns workers.
- If a worker needs a missing downstream role, write a `worker_request` to the shared bus with the `requested_role`.
- The user sees the result of implicit calls, not the internal planning chatter.
- All agents use the structured messaging protocol from [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).
