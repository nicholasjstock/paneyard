# Autonomous Multi-Agent Workflow System

This directory contains a **3-agent system**: a reusable supervisor/planner/worker pattern with a shared bus and explicit state tracking. The orchestrator is deterministic loop logic called by the supervisor, not a separate spawnable agent.

## Current Deployment: Demo Video Production

The single generic `@worker` role produces and validates the Simple Retail Planner product demo video — recording, verifying, and applying scoped fixes, whichever the current bus request/prompt describes. The supervisor/orchestrator/bus machinery itself is not demo-specific — a different task could swap in different worker prompts.

> Codex note: the parallel Codex-native setup lives in [`.codex/agents`](../../.codex/agents/README.md). Both Claude and Codex share the same `workflow` MCP server via [`.mcp.json`](../../.mcp.json), so runs from both CLI paths contribute to the same shared bus and artifact store.

## System Architecture

```
User Request
    ↓
@supervisor (Loop Owner)
    ├→ run orchestrator turn (deterministic planning logic)
    ├→ spawn workers & deduplicate
    ├→ @worker (recording, verification, or a scoped fix — exactly one at a time)
    └→ loop back to orchestrator turn
         ↓
      @planner (implicit planning helper)
```

Agents work together hierarchically:
- **Supervisor** (@supervisor) owns the main workflow loop, calls orchestrator for planning, spawns workers, and iterates until completion.
- **Orchestrator** (internal, called by @supervisor) never decides real work itself — a normal tick is a pure no-op. Its only job is detecting trouble: a stalled worker (still running, idle too long), or a dead-ended run (no active workers, no open requests, never marked `completed` — a worker that stopped without completing its handoff, invisible to stall detection since there's no running worker left to check). Either way it publishes a spawn request for a recovery @planner — unless a `blocking` user question is already open for the run, in which case it stays a no-op until that's answered, rather than spawning another @planner to redundantly re-investigate something already awaiting a human.
- **Worker** (@worker) executes whatever the current bus request/prompt describes — recording, verification, or a scoped fix. Execution is strictly sequential: at most one worker instance runs per run at a time, per the planner's `nextStep`/`followingSteps` decision.
- **Planner** (@planner) is spawned for stalled-worker recovery, and after every `worker_turn` completion, to decide the single next step (`nextStep`) plus the queue for later (`followingSteps`). Every planner turn ends by publishing a decision (`planner_turn`, with `nextStep` possibly `null`) or a user question (`append_user_question`) — never silently.

All agents should route unmet worker needs back through the shared bus so the supervisor can spawn the missing role instead of fragmenting state across direct side channels.
Workers report completion via the `worker_turn` MCP tool, which requests a follow-up @planner via a bus spawn request (reused if one is open, or fulfilled by a still-active planner — a stopped fulfillment is stale and gets a fresh request, so a later problem always gets its own planner) with the result and the current `followingSteps` queue as context — the supervisor spawns that planner on its next tick, and this is the primary reporting mechanism. Workers should call @planner directly only when they're stuck mid-task and need help (a separate path from the automatic post-completion request).

## Quick Start

### Run Full Workflow
```bash
@supervisor run the full workflow for run: {runId}
```

### Record a Demo (standalone)
```bash
@worker run docker recording
@worker run local recording
```

### Verify a Video (standalone)
```bash
@worker analyze the latest phone recording and verify the flow is correct
```

## Agent Overview

| Agent | Role | Called By | Invocation |
|-------|------|-----------|-----------|
| **@supervisor** | Loop owner, spawn workers | User | Explicit |
| **@worker** | Record, verify, or apply a scoped fix, per the current bus request | @supervisor | Spawned after plan |
| **@planner** | Create work orders | Orchestrator, workers | Implicit (on-demand) |

The supervisor owns the main workflow loop. It repeatedly:
1. Calls orchestrator planning logic to inspect state and detect stalls
2. Collects and deduplicates spawn requests from the bus by `(runId, requestedRole, scope)`
3. Spawns workers via MCP-managed workers and publishes `worker_spawned` events
4. Optionally runs a follow-up orchestrator turn if workers were spawned
5. Loops until the run is complete

The orchestrator is internal logic (not a separate agent) called by @supervisor each iteration. It never decides real work itself — it only detects stalls and, when it finds one, publishes a spawn request for a recovery @planner.

## Workflow

Each iteration of the supervisor's main loop:

1. Supervisor calls orchestrator to inspect state and detect stalls.
2. Orchestrator is a no-op on a normal tick; on a stall, it publishes a spawn request asking for a recovery @planner.
3. Supervisor collects and deduplicates open spawn requests by `(runId, requestedRole, scope)`.
4. Supervisor spawns MCP-managed workers for each unique request.
5. Supervisor publishes `worker_spawned` events to reflect actual spawns in bus state.
6. The single active worker (@worker) executes its task, publishing progress and artifacts.
7. Supervisor may run a follow-up orchestrator turn to re-check for stalls.
8. If verification finds an issue, the deterministic routing (or a spawned planner instance) directs a scoped fix step to another `@worker` instance with the relevant write scope in its prompt.
9. After fixes, a recording worker reruns and a verification worker reruns to confirm success.
10. Loop continues until termination condition is met (all-checks-passed, repeated error, or critical blocker).
11. Supervisor reports final result to the user.

## Key Files

- [ARCHITECTURE.md](./ARCHITECTURE.md) — System design and agent roles
- [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md) — Structured logging format (all agents)
- [worker.md](./worker.md) — Generic task worker
- [planner.md](./planner.md) — Planning helper

## MCP Tools & Skills

The workflow is powered by the `workflow` MCP server (registered at [`.mcp.json`](../../.mcp.json)) and three utility skills:
- [/monitor-workflow](../skills/monitor-workflow/SKILL.md) — Inspect bus, workers, and logs
- [/planner-bus](../skills/planner-bus/SKILL.md) — Write bus handoff payloads

## Expected Demo Flow

The demo should follow this pattern:

1. Setup and login
2. Load the phone and desktop views
3. Publish the schedule
4. Show notifications and direct links
5. Walk through coverage requests and approvals
