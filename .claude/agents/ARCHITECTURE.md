# Multi-Agent Workflow Architecture

## Current Deployment: Demo Video Production

This orchestration pattern (supervisor → orchestrator → planner → workers, a shared bus, and MCP-managed worker lifecycle) is a reusable workflow shape, not something specific to video recording. The concrete worker set configured today produces the Simple Retail Planner product demo video: `@video-recorder` and `@video-verifier` handle the recording/verification work, alongside the generic `@front-fixer` and `@back-fixer` fix workers. A different deployment could swap in a different worker set for a different task while keeping the same supervisor/orchestrator/bus machinery.

## System Overview

Five specialized agents work together in a hierarchy:

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
└───┬──────────────┬─────────────────┬────────────────────┘
    │              │                 │
  ┌─↓──┐      ┌────↓──────┐   ┌─────↓──────┐
  │    │      │            │   │            │
  ↓    ↓      ↓            ↓   ↓            ↓
 ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
 │ @video-  │ │ @video-  │ │ @front-  │ │ @back-   │
 │ recorder │ │ verifier │ │ fixer    │ │ fixer    │
 │(EXECUTOR)│ │(EXECUTOR)│ │(EXECUTOR)│ │(EXECUTOR)│
 └────┬─────┘ └────┬─────┘ └──────────┘ └──────────┘
      │            │
      └─→ @planner (implicit)
          called when stuck
          ↑
          └──── called by supervisor's
               orchestrator turns
```

Not shown above: each executor/fixer also calls `worker_turn` (a deterministic MCP tool, not a subagent) when it finishes — this feeds the worker's result into the planner's routing logic and publishes the next steps to the bus directly, independent of the `@planner (implicit)` stuck-help path shown here.

## The Complete Loop

```
User Request
    ↓
Record → Verify → Implement → Record → Verify → Report
    ↑                                               ↓
    └───────────────── Iterate if needed ─────────┘
```

## Agent Responsibilities

### Level 0: Fixing
**@front-fixer** (Frontend Fix Worker)
- **Responsibility:** Apply isolated frontend-only fixes based on verifier findings
- **Called by:** @demo-pipeline when verification finds a frontend issue
- **Scope:** `front/**` only
- **Action:** Reads findings → (calls @planner only if stuck) → adds failing test → implements fix → verifies with typecheck/test → reports via `worker_turn`

**@back-fixer** (Backend Fix Worker)
- **Responsibility:** Apply isolated backend-only fixes based on verifier findings
- **Called by:** @demo-pipeline when verification finds a backend issue
- **Scope:** `back/**` only
- **Action:** Reads findings → (calls @planner only if stuck) → adds failing spec → implements fix → verifies with spec → reports via `worker_turn`

### Level 1: Workflow Control
**@demo-pipeline** (Orchestrator)
- **Responsibility:** Coordinate the entire workflow
- **Inputs:** Execution request from the user
- **Outputs:** Complete report with findings
- **Calls:** @video-recorder, @video-verifier, @implementor
- **When to call @planner:** Complex workflows, coordination issues

### Level 2: Execution
**@video-recorder** (Executor)
- **Responsibility:** Record demo videos
- **Inputs:** Recording parameters (local/docker)
- **Outputs:** Video file path or error
- **Calls:** @planner when stuck (syntax errors, diagnostic help); reports every completion via `worker_turn`

**@video-verifier** (Executor)
- **Responsibility:** Analyze and verify videos
- **Inputs:** Video file path, expected flow
- **Outputs:** Analysis report, findings, feedback
- **Calls:** @planner when needed (unclear states, diagnostic help); reports every completion via `worker_turn`

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
  2. Orchestrator decides: spawn @video-recorder
  3. Spawn @video-recorder
     ✅ Returns: video file
  
  4. Call orchestrator → re-plan
  5. Orchestrator decides: spawn @video-verifier
  6. Spawn @video-verifier
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
  2. Orchestrator decides: spawn @video-recorder
  3. Spawn @video-recorder
     ❌ Returns: esbuild compilation error

@video-recorder:
  → Call @planner for recovery plan

@supervisor (iteration 2):
  4. Call orchestrator → re-plan (sees stalled recorder)
  5. Orchestrator decides: spawn @front-fixer
  6. Spawn @front-fixer
     ✅ Fix applied
  
  7. Call orchestrator → re-plan
  8. Orchestrator decides: re-spawn @video-recorder
  9. Spawn @video-recorder
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
- When spawning @front-fixer or @back-fixer, orchestrator should first call @planner to analyze verifier findings.
- **@video-recorder**, **@video-verifier**, **@front-fixer**, **@back-fixer** call `worker_turn` when they finish (deterministically routes their result to the planner's logic and publishes next steps) and call @planner directly only when they're stuck mid-task and need help.
- **@planner** never calls other agents or spawns workers.
- If a worker needs a missing downstream role, write a `worker_request` to the shared bus with the `requested_role`.
- The user sees the result of implicit calls, not the internal planning chatter.
- All agents use the structured messaging protocol from [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).
