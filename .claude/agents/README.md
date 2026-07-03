# Autonomous Multi-Agent Workflow System

This directory contains a **5-agent system**: a reusable supervisor/orchestrator/planner/worker pattern with a shared bus and explicit state tracking.

## Current Deployment: Demo Video Production

The worker roles configured today (`@video-recorder`, `@video-verifier`, plus the generic `@front-fixer`/`@back-fixer`) produce and validate the Simple Retail Planner product demo video. The supervisor/orchestrator/bus machinery itself is not demo-specific — a different task could swap in a different worker set.

> Codex note: the parallel Codex-native setup lives in [`.codex/agents`](../../.codex/agents/README.md). Both Claude and Codex share the same `workflow` MCP server via [`.mcp.json`](../../.mcp.json), so runs from both CLI paths contribute to the same shared bus and artifact store.

## System Architecture

```
User Request
    ↓
@supervisor (Loop Owner)
    ├→ run orchestrator turn (planning)
    ├→ spawn workers & deduplicate
    ├→ @video-recorder
    ├→ @video-verifier
    ├→ @front-fixer (for frontend issues)
    ├→ @back-fixer (for backend issues)
    └→ loop back to orchestrator turn
         ↓
      @planner (implicit planning helper)
```

Agents work together hierarchically:
- **Supervisor** (@supervisor) owns the main workflow loop, calls orchestrator for planning, spawns workers, and iterates until completion.
- **Orchestrator** (internal, called by @supervisor) runs planning logic and publishes work decisions to the bus via @planner.
- **Executors** (@video-recorder, @video-verifier) record and analyze videos.
- **Fixers** (@front-fixer, @back-fixer) apply isolated fixes, scoped to their side of the codebase.
- **Planner** (@planner) decides the work order when orchestrator needs help (implicit).

All agents should route unmet worker needs back through the shared bus so the supervisor can spawn the missing role instead of fragmenting state across direct side channels.
Workers report completion via the `worker_turn` MCP tool, which deterministically routes their result through the planner's logic and publishes the resulting bus entries — this is the primary reporting mechanism. Workers should call @planner directly only when they're stuck mid-task and need help.

## Quick Start

### Run Full Workflow
```bash
@supervisor run the full workflow for run: {runId}
```

### Record a Demo (standalone)
```bash
@video-recorder run docker recording
@video-recorder run local recording
```

### Verify a Video (standalone)
```bash
@video-verifier analyze the latest phone recording and verify the flow is correct
```

## Agent Overview

| Agent | Role | Called By | Invocation |
|-------|------|-----------|-----------|
| **@supervisor** | Loop owner, spawn workers | User | Explicit |
| **@video-recorder** | Record demos | @supervisor | Spawned after plan |
| **@video-verifier** | Verify videos | @supervisor | Spawned after plan |
| **@front-fixer** | Fix frontend issues | @supervisor | Spawned after plan |
| **@back-fixer** | Fix backend issues | @supervisor | Spawned after plan |
| **@planner** | Create work orders | Orchestrator, workers | Implicit (on-demand) |

The supervisor owns the main workflow loop. It repeatedly:
1. Calls orchestrator planning logic to inspect state and decide the next worker(s)
2. Collects and deduplicates spawn requests from the bus by `(runId, requestedRole, scope)`
3. Spawns workers via MCP-managed workers and publishes `worker_spawned` events
4. Optionally runs a follow-up orchestrator turn if workers were spawned
5. Loops until the run is complete

The orchestrator is internal logic (not a separate agent) called by @supervisor each iteration. It publishes work decisions to the bus via @planner.

## Workflow

Each iteration of the supervisor's main loop:

1. Supervisor calls orchestrator to inspect state and plan the next work.
2. Orchestrator publishes `worker_request` questions to the bus via @planner.
3. Supervisor collects and deduplicates open `worker_request` questions by `(runId, requestedRole, scope)`.
4. Supervisor spawns MCP-managed workers for each unique request.
5. Supervisor publishes `worker_spawned` events to reflect actual spawns in bus state.
6. Workers (@video-recorder, @video-verifier, @front-fixer, @back-fixer) execute tasks, publishing progress and artifacts.
7. Supervisor may run a follow-up orchestrator turn to re-plan if workers were spawned.
8. If verification finds a frontend-only issue, orchestrator requests @front-fixer; if backend-only, requests @back-fixer.
9. After fixes, recorder reruns and verifier reruns to confirm success.
10. Loop continues until termination condition is met (all-checks-passed, repeated error, or critical blocker).
11. Supervisor reports final result to the user.

## Key Files

- [ARCHITECTURE.md](./ARCHITECTURE.md) — System design and agent roles
- [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md) — Structured logging format (all agents)
- [demo-pipeline.md](./demo-pipeline.md) — Orchestrator
- [video-recorder.md](./video-recorder.md) — Recording executor
- [video-verifier.md](./video-verifier.md) — Verification executor
- [front-fixer.md](./front-fixer.md) — Frontend fixer
- [back-fixer.md](./back-fixer.md) — Backend fixer
- [planner.md](./planner.md) — Planning helper

## MCP Tools & Skills

The workflow is powered by the `workflow` MCP server (registered at [`.mcp.json`](../../.mcp.json)) and three utility skills:
- [/demo-launch](../skills/demo-launch/SKILL.md) — Start or restart @demo-pipeline
- [/monitor-workflow](../skills/monitor-workflow/SKILL.md) — Inspect bus, workers, and logs
- [/planner-bus](../skills/planner-bus/SKILL.md) — Write bus handoff payloads

## Expected Demo Flow

The demo should follow this pattern:

1. Setup and login
2. Load the phone and desktop views
3. Publish the schedule
4. Show notifications and direct links
5. Walk through coverage requests and approvals
