# Codex Multi-Agent Workflow

This project uses Codex `multi_agent` orchestration with a bus-led fan-out model:

- `orchestrator` coordinates record -> verify -> fix -> re-record loops and uses the shared bus as the state ledger.
- `planner` decides handoff payloads and uses `gpt-5.4` for more capable planning.
- `demo_recorder` records demo runs via the `record-demo` skill, monitors progress, and validates artifacts after planner gives the work order.
- `demo_verifier` runs evidence-based verification passes after planner gives the work order, starting with the fastest evidence source that can answer the question.
- `front_fixer` owns frontend-only fixes after planner gives the work order.
- `back_fixer` owns backend-only fixes after planner gives the work order.
- `infra_fixer` owns repo-local infrastructure and toolchain fixes after planner gives the work order.
- `general_fixer` owns anything that does not fit the specialized fixer scopes after planner gives the work order.
- For critical demo runs, `orchestrator` should prefer paired workers per specialized role so liveness is always covered.
- Keep `multi_agent` enabled so Codex can fan out parallel subagents when the task is split across independent roles.

Before Codex launches `orchestrator`, invoke `planner` to determine the current run context and initial handoff shape. Do not route orchestration back through repo CLI wrappers or ask the parent to run `npm` just to start orchestration.
Normal worker completions are handled deterministically: each worker calls the `worker_turn` MCP tool itself when it finishes, which feeds its result into the planner's routing logic and publishes the next steps to the bus automatically. The orchestrator only needs to invoke `planner` directly for cases `worker_turn` doesn't cover, such as stalled/unresponsive workers.

## Running Nicknames

When subagents are running, look for these role-based nicknames:

| Agent | Nickname to look for |
|---|---|
| `orchestrator` | `orchestrator` or `workflow-orchestrator` |
| `demo_recorder` | `demo-recorder` or `recording-worker` |
| `demo_verifier` | `demo-verifier` or `video-checker` |
| `front_fixer` | `front-fixer` |
| `back_fixer` | `back-fixer` |
| `infra_fixer` | `infra-fixer` |
| `general_fixer` | `general-fixer` |

When the orchestrator needs to re-ask an active worker through the bus, target the matching nickname for the role above instead of inventing a new recipient.
Workers report completion via `worker_turn`, which deterministically routes their result through the planner's logic and publishes the resulting bus entries — this is the primary reporting mechanism, not ad hoc `append_question` calls.

When the orchestrator needs a handoff plan or worker request payload, invoke `planner` first and then publish the result to the bus.
When `list_open_questions` reveals a new `worker_request` with `action=spawn_worker`, spawn the requested role immediately instead of waiting for the next handoff cycle.
Do not stop after publishing planner jobs; the orchestrator should fan out the matching workers in the same turn.

Use built-in `explorer` subagents for read-only codebase questions and built-in `worker` subagents for bounded edits.
Keep write sets disjoint and verify before reporting success.

## Workflow Notes

- Use structured updates from [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).
- Invoke `orchestrator`; it is responsible for spawning only the worker roles required for the current phase.
- Treat `multi_agent` as the default execution model for this repo's orchestration tasks.
- Any recording task must go through the `record-demo` skill and `bin/record_demo`.
- All user questions and unresolved blockers should be aggregated on the shared bus, with the orchestrator owning the lifecycle and pulling from that state rather than waiting on a separate manager role.
- When a worker sees an unmet `worker_request`, it should put that request on the shared bus with `action=spawn_worker` and the `requested_role` so the orchestrator can spawn the missing worker.
- Treat verification as streaming work: run a fast pass first, using the cheapest evidence source that can answer the question, then deeper passes if needed.
- The orchestrator can spawn multiple `demo_verifier` runs in parallel with different scopes such as `fast`, `medium`, and `slow`.
- The orchestrator can also spawn two instances of a specialized worker role when it wants one to execute and one to verify or stand by.
- After a fix, re-run the recorder and verifier rather than reporting success from the code diff alone.
- Long-running work must heartbeat. A recorder or verifier that goes silent should become `BLOCKED`, not invisible.
- If the orchestrator sees a stalled child or a repeated failure pattern, it should call `planner` with the stall context before choosing the next handoff.
- When the orchestrator needs to inspect workers and plan the next move in one turn, use `run_orchestrator_turn`.
