# Codex Agent Roster

Rails owns orchestration, planning, retries, and process dispatch — see [AGENTS.md](../../AGENTS.md) and [CLAUDE.md](../../CLAUDE.md) at the repo root for the authoritative description of that model. This directory holds the persona prompts (as Codex `developer_instructions` TOML) for every process Rails can spawn as a Codex subagent. There is deliberately no `orchestrator.toml` or `planner.toml`: planning is a bounded, stateless decision function (`PlannerDecisionJob`), run as one tools-disabled structured model call, not a spawned Codex process — and "orchestrator" is Rails' own dispatch logic (`TickRunJob` + `Orchestrator::SpawnRequestedWorkers`), not a subagent either.

> Claude note: the parallel Claude-native personas live in [`.claude/agents`](../../.claude/agents/README.md), sharing the same `workflow` MCP server (registered in [`.mcp.json`](../../.mcp.json)) and the same bus/worker/artifact state, so runs from either CLI path are interchangeable mid-run.

Keep `multi_agent` enabled so Codex can still fan out its own built-in subagents for read-only research or bounded edits within a single agent's own turn — that's a Codex implementation detail local to one turn, separate from the sequential role dispatch described below.

## Roles

At most one worker is active per run at a time — Rails dispatches strictly sequentially (see `Orchestrator::SpawnRequestedWorkers`), so there is no dependency graph to manage, only ever one thing in flight.

| Role | File | Spawned when |
|------|------|---------------|
| `worker` | [worker.toml](./worker.toml) | A generic bus request: run a workspace operation, verify/analyze evidence, or apply a scoped fix. What it actually does comes from the task prompt, not a fixed identity. |
| `infrastructure` | *(worker.toml + the infrastructure skill)* | Same worker contract, layered with the repository-owned reliability workflow for fixing runtime/environment/tooling problems. |
| `verifier` | [verifier.toml](./verifier.toml) | An independent, fresh reproduction of one acceptance criterion's evidence before Rails allows it to close. |
| `project_init` | [project_init.toml](./project_init.toml) | Once per workspace: discovers how to start the local dev environment and which source paths are protected. |
| `chaperone` | [chaperone.toml](./chaperone.toml) | A repeated failure under the same lineage escalates to a strong-model review that decides `continue_small`, `promote`, or `stop`. |
| `seeder` | [seeder.toml](./seeder.toml) | Run finalization, stage 1: inspects the completed diff and adds/updates whatever seed or fixture data this workspace's own convention needs to demonstrate a new human-visible state, then reports the concrete verification steps a reviewer should follow. |
| `reporter` | [reporter.toml](./reporter.toml) | Run finalization, stage 2: audits persisted run history (including the seeder's verification steps) and writes the reviewer-facing `run-summary.md`. |
| `curator` | [curator.toml](./curator.toml) | Run finalization, stage 3: selects real local deliverables for upload as review evidence via `select_review_assets`. |
| `demo` | [demo.toml](./demo.toml) | Run finalization, stage 4: starts (or reuses) the workspace's dev/demo server via `start_run_command`, purely mechanical — it has no task context of its own and does not report verification steps. |
| `committer` | [committer.toml](./committer.toml) | Run finalization, stage 5 (terminal): commits source changes (including anything the seeder wrote) only, once reporter and curator have completed. |

`seeder` → `reporter` → `curator` → `demo` → `committer` run strictly in sequence (`app/jobs/tick_run_job.rb#finalize_completed_run`); each is granted only its own narrow MCP tool slice by `Orchestrator::WorkerMcpServer`, enforced both by the tool list and by a role check inside each tool. Seeder runs first so its verification steps and seeded data are already in place for the reporter's summary and the demo role. `reporter`/`curator`/`committer`/`demo` run with `sandbox_mode = "read-only"` in their TOML except `seeder` and `demo`, which need `"workspace-write"` since their entire job is writing files or starting a process. Unlike every other finalization role, `seeder` is spawned with `write_scope: "scoped_changes"` and the workspace's full `protected_write_patterns` — the same wholesale write grant an implementation worker gets — and it, not `demo`, owns the reviewer-facing verification steps reported via `complete_run_finalization`'s `clickPath` parameter, since only it has both full task context and knowledge of exactly what data now exists.

Planning itself has no agent file or nickname: a worker's `[DONE]`/`[BLOCKED]`/`[FAILED]` result either promotes an already-planned `followingSteps` item directly, or queues one bounded `PlannerDecisionJob` call — never a spawned Codex process.

## Running Nicknames

When subagents are running, look for these role-based nicknames (see `build_worker_nickname` in `app/services/orchestrator/spawn_requested_workers.rb`):

| Role | Nickname to look for |
|---|---|
| `worker` | `worker` (or `worker-2`, `worker-3`, ... for concurrent instances across runs) |
| any other role | the role name itself (`seeder`, `reporter`, `curator`, `demo`, `committer`, `verifier`, `chaperone`, `project_init`, `infrastructure`), suffixed `-1`, `-2`, ... only if a name collision occurs |

## Workflow Notes

- Use structured updates from [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md).
- Rails (`TickRunJob` + `Orchestrator::SpawnRequestedWorkers`) is the only thing that spawns processes; no agent spawns another agent directly.
- A worker never manages its own lifecycle (no `spawn_worker`/`stop_worker`); it reports via `worker_turn` and Rails decides what happens next. `worker_turn` requests a follow-up planner decision via the bus (a Rails job, not a spawned process) with the reported result and the current `followingSteps` queue as context.
- If a worker needs a missing downstream role, it raises `[BLOCKED]` through `worker_turn` (or, mid-task, asks for help) rather than acting outside its assigned scope — Rails and the bounded planner own all follow-up routing.
- Finalization roles (`seeder`/`reporter`/`curator`/`demo`/`committer`) never call each other's tools — `Orchestrator::WorkerMcpServer` and each tool's own role guard enforce that independently.
- Treat verification as streaming work within a single worker turn: run a fast pass first, using the cheapest evidence source that can answer the question, then deeper passes if needed, before reporting via `worker_turn`.
- Long-running work must heartbeat. A worker that goes silent should become `BLOCKED`, not invisible.
- Any command that doesn't exit on its own (a dev server, a watcher) must be started with `start_run_command`, never backgrounded directly — Rails detects a listening port automatically from OS process state.
