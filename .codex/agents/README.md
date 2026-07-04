# Codex Multi-Agent Workflow

This project uses Codex `multi_agent` workers with a deterministic supervisor/orchestrator loop and a bus-led fan-out model:

- `orchestrator` is deterministic loop logic in `scripts/orchestrator-turn.ts`; it coordinates record -> verify -> fix -> re-record loops and uses the shared bus as the state ledger.
- `planner` decides handoff payloads and uses `gpt-5.4` for more capable planning.
- `worker` is the single generic task executor: it records demos, runs evidence-based verification passes, or applies a scoped fix, whichever the planner's step/prompt describes, after planner gives the work order.
- For critical demo runs, `orchestrator` should prefer paired `worker` instances so liveness is always covered.
- Keep `multi_agent` enabled so Codex can fan out parallel subagents when the task is split across independent worker instances.

The supervisor calls the orchestrator logic directly in-process. Do not route orchestration through repo CLI wrappers or a standalone LLM orchestrator prompt.
Normal worker completions are handled deterministically: each worker calls the `worker_turn` MCP tool itself when it finishes, which feeds its result into the planner's routing logic and publishes the next steps to the bus automatically. The orchestrator only needs to invoke `planner` directly for cases `worker_turn` doesn't cover, such as stalled/unresponsive workers.

## Running Nicknames

When subagents are running, look for these role-based nicknames:

| Agent | Nickname to look for |
|---|---|
| `orchestrator` | `orchestrator` or `workflow-orchestrator` |
| `worker` | `worker` (or `worker-2`, `worker-3`, ... for concurrent instances) |

When the orchestrator needs to re-ask an active worker through the bus, target the matching nickname for the role above instead of inventing a new recipient.
Workers report completion via `worker_turn`, which deterministically routes their result through the planner's logic and publishes the resulting bus entries — this is the primary reporting mechanism, not ad hoc `append_question` calls.

When the orchestrator needs a handoff plan or worker request payload, invoke `planner` first and then publish the result to the bus.
When `list_open_questions` reveals a new `worker_request` with `action=spawn_worker`, spawn the requested role immediately instead of waiting for the next handoff cycle.
Do not stop after publishing planner jobs; the orchestrator should fan out the matching workers in the same turn.

Use built-in `explorer` subagents for read-only codebase questions and built-in `worker` subagents for bounded edits.
Keep write sets disjoint and verify before reporting success.

## Workflow Notes

- Use structured updates from [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).
- The deterministic orchestrator logic is responsible for publishing only the worker roles required for the current phase; the supervisor performs the actual spawns.
- Treat `multi_agent` as the default execution model for this repo's orchestration tasks.
- Any recording task must go through the `record-demo` skill and `bin/record_demo`.
- All user questions and unresolved blockers should be aggregated on the shared bus, with the orchestrator owning the lifecycle and pulling from that state rather than waiting on a separate manager role.
- When a worker sees an unmet `worker_request`, it should put that request on the shared bus with `action=spawn_worker` and the `requested_role` so the orchestrator can spawn the missing worker.
- Treat verification as streaming work: run a fast pass first, using the cheapest evidence source that can answer the question, then deeper passes if needed.
- The orchestrator can spawn multiple `worker` instances in parallel with different scopes such as `fast`, `medium`, and `slow` when the task is verification, or with disjoint write scopes when the task is a fix.
- The orchestrator can also spawn two `worker` instances when it wants one to execute and one to verify or stand by.
- After a fix, re-run the recorder and verifier rather than reporting success from the code diff alone.
- Long-running work must heartbeat. A recorder or verifier that goes silent should become `BLOCKED`, not invisible.
- If the orchestrator sees a stalled child or a repeated failure pattern, it should call `planner` with the stall context before choosing the next handoff.
- When the orchestrator needs to inspect workers and plan the next move in one turn, use `run_orchestrator_turn`.
