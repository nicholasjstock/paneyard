# Agent Roster

Rails owns orchestration, planning, retries, and process dispatch — see [AGENTS.md](../../AGENTS.md) and [CLAUDE.md](../../CLAUDE.md) at the repo root for the authoritative description of that model. This directory holds the persona prompts for every process Rails can spawn as a Claude subagent. There is deliberately no `planner.md`, `supervisor.md`, or `orchestrator.md` here: planning is a bounded, stateless decision function (`PlannerDecisionJob`), not a spawnable agent, and "orchestrator" is Rails' own dispatch logic (`TickRunJob` + `Orchestrator::SpawnRequestedWorkers`), not a subagent either.

> Codex note: the parallel Codex-native personas live in [`.codex/agents`](../../.codex/agents/README.md), sharing the same `workflow` MCP server (registered in [`.mcp.json`](../../.mcp.json)) and the same bus/worker/artifact state, so runs from either CLI path are interchangeable mid-run.

## Roles

At most one worker is active per run at a time — Rails dispatches strictly sequentially (see `Orchestrator::SpawnRequestedWorkers`).

| Role | File | Spawned when |
|------|------|---------------|
| `worker` | [worker.md](./worker.md) | A generic bus request: run a workspace operation, verify/analyze evidence, or apply a scoped fix. What it actually does comes from the task prompt, not a fixed identity. |
| `infrastructure` | *(worker.md + [../skills/infrastructure/SKILL.md](../skills/infrastructure/SKILL.md))* | Same worker contract, layered with the repository-owned reliability workflow for fixing runtime/environment/tooling problems. |
| `verifier` | [verifier.md](./verifier.md) | An independent, fresh reproduction of one acceptance criterion's evidence before Rails allows it to close. |
| `project_init` | [project_init.md](./project_init.md) | Once per workspace: discovers how to start the local dev environment and which source paths are protected. |
| `chaperone` | [chaperone.md](./chaperone.md) | A repeated failure under the same lineage escalates to a strong-model review that decides `continue_small`, `promote`, or `stop`. |
| `reporter` | [reporter.md](./reporter.md) | Run finalization, stage 1: audits persisted run history and writes the reviewer-facing `run-summary.md`. |
| `curator` | [curator.md](./curator.md) | Run finalization, stage 2: selects real local deliverables for upload as review evidence via `select_review_assets`. |
| `demo` | [demo.md](./demo.md) | Run finalization, stage 3: starts (or reuses) the workspace's dev/demo server via `start_run_command` and reports a `clickPath` so a reviewer can see the change running. |
| `committer` | [committer.md](./committer.md) | Run finalization, stage 4 (terminal): commits source changes only, once reporter and curator have completed. |

`reporter` → `curator` → `demo` → `committer` run strictly in sequence (`app/jobs/tick_run_job.rb#finalize_completed_run`); each is granted only its own narrow MCP tool slice by `Orchestrator::WorkerMcpServer`, enforced both by the tool list and by a role check inside each tool.

Planning itself has no agent file: a worker's `[DONE]`/`[BLOCKED]`/`[FAILED]` result either promotes an already-planned `followingSteps` item directly, or queues one bounded `PlannerDecisionJob` call (tools disabled, structured output only) — never a spawned planner process.

## Key Files

- [ARCHITECTURE.md](./ARCHITECTURE.md) — system design: the run lifecycle, planner context protocol, and finalization pipeline
- [MESSAGING_PROTOCOL.md](./MESSAGING_PROTOCOL.md) — structured logging format all agents use
- [worker.md](./worker.md) — the generic task worker persona, reused as the base for `infrastructure` and `verifier`

## MCP Tools

The workflow is powered by the `workflow` MCP server (registered at [`.mcp.json`](../../.mcp.json)). Tool access per role is enforced in `app/services/orchestrator/worker_mcp_server.rb`; individual tools additionally self-check the authenticated worker's role (e.g. `app/services/mcp_tools/complete_run_finalization_tool.rb`).
