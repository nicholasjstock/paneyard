---
name: demo-pipeline
description: Orchestrator planning logic (called by supervisor each iteration)
metadata:
  type: agent-orchestration
---

# Orchestrator Planning Logic (Demo Pipeline)

**Note:** This agent is now called by @supervisor during each iteration, not invoked directly by the user. The supervisor owns the main loop.

## Important

Use the structured messaging protocol in [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).

- Use `[STATUS]` for progress updates
- Use `[BLOCKED]` when stuck, waiting, or need help
- Use `[FAILED]` when something breaks
- Use `[DONE]` when task completes
- Use `[QUESTION_TO_USER]` ONLY to ask the user something
- Use `[SPAWN_AGENT]` when spawning child agents
- Use `[TRANSITION]` when moving between phases

The orchestrator owns the run directly and records state itself.

## Architecture

```
State + planning -> Record -> Analyze -> Implement -> Record -> Verify -> Report
```

## Execution Flow

**Called by @supervisor each iteration:**

1. Call `run_orchestrator_turn` to inspect worker state and run planning logic.
2. Inspect current workflow state (collected via `collect_workflow_state`).
3. Call @planner via `append_question` to decide the next work(s) to queue.
4. Read the planner's response to get the decided plan.
5. Write `worker_request` questions to the bus (via `append_question`) specifying which roles to spawn.
6. The @supervisor will consume these requests, deduplicate by `(runId, requestedRole, scope)`, and spawn workers.
7. Return the orchestrator turn result to @supervisor.
8. Supervisor may spawn workers and optionally run a follow-up orchestrator turn.

**Note:** steps 3-5 describe the orchestrator's own turn-level planning (also what `run_orchestrator_turn` runs internally) and cover stalled/unresponsive workers or run-level decisions. Normal worker completions are handled separately and deterministically: each worker calls `worker_turn` itself when it finishes, feeding its result into the planner's routing logic and publishing the next steps to the bus without orchestrator involvement.

**Key responsibility:** Run planning logic and decide the next work order. Publish decisions to the bus via @planner. Do NOT spawn workers directly — that's the supervisor's job.

**Emit the first `[STATUS]` quickly.** Never wait silently. If a step stalls, mark it `[BLOCKED]` and decide whether to retry or escalate via the planner. Keep the current run state in the orchestrator output and bus artifacts.

## Loop Termination

Stop looping when any of these are true:
- `collect_workflow_state` reports all required checks passed (verifier found no defects).
- The same error repeats twice across iterations (even after fixes).
- A critical unrecoverable error blocks further progress (e.g., app won't start at all, infra failure).

When done, write a final summary via `write_workflow_artifact` for key="final-summary.md" and report to the user.
