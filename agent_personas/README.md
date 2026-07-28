# Agent Persona Roster

Rails owns orchestration, planning, retries, and process dispatch — see [AGENTS.md](../AGENTS.md) and [CLAUDE.md](../CLAUDE.md) at the repo root for the authoritative description of that model. This directory holds the one persona prompt per role that Rails spawns as a subagent, shared by both the Claude and Codex launcher paths (`Orchestrator::WorkerSpawner#build_prompt_with_persona`) — they share the same `workflow` MCP server (registered in [`.mcp.json`](../.mcp.json)) and the same bus/worker/artifact state, so a run is interchangeable mid-run regardless of which CLI it's using. There is deliberately no `planner.md`, `supervisor.md`, or `orchestrator.md` here: planning is a bounded, stateless decision function (`PlannerDecisionJob`), not a spawnable agent, and "orchestrator" is Rails' own dispatch logic (`TickRunJob` + `Orchestrator::SpawnRequestedWorkers`), not a subagent either.

These used to be two per-driver copies (`.claude/agents/*.md`, `.codex/agents/*.toml`) manually kept in sync by hand — confirmed the actual instructional content was identical or near-identical between them, and that duplication already caused real drift once (a stale pre-Rails-orchestrator instruction block existed only in one copy). Neither driver's frontmatter/TOML metadata fields (`model`, `model_reasoning_effort`, `sandbox_mode`) were ever read by `WorkerSpawner` either — it only ever does `File.read` on the body text; real model/tier/effort selection lives entirely in `WorkerSpawner` and `spawn_requested_workers.rb`.

Codex detail worth keeping in mind even though it's shared: keep `multi_agent` enabled so Codex can still fan out its own built-in subagents for read-only research or bounded edits within a single agent's own turn — that's a Codex implementation detail local to one turn, separate from the sequential role dispatch described below.

## Roles

At most one worker is active per run at a time — Rails dispatches strictly sequentially (see `Orchestrator::SpawnRequestedWorkers`), so there is no dependency graph to manage, only ever one thing in flight.

| Role | File | Spawned when |
|------|------|---------------|
| `worker` | [worker.md](./worker.md) | A generic bus request: run a workspace operation, verify/analyze evidence, or apply a scoped fix. What it actually does comes from the task prompt, not a fixed identity. |
| `infrastructure` | *(worker.md + [infrastructure_skill.md](./infrastructure_skill.md))* | Same worker contract, layered with the repository-owned reliability workflow for fixing runtime/environment/tooling problems. |
| `verifier` | [verifier.md](./verifier.md) | An independent, fresh reproduction of one acceptance criterion's evidence before Rails allows it to close. |
| `project_init` | [project_init.md](./project_init.md) | Once per workspace: discovers how to start the local dev environment and which source paths are protected. |
| `chaperone` | [chaperone.md](./chaperone.md) | A repeated failure under the same lineage escalates to a strong-model review that decides `continue_small`, `promote`, or `stop`. |
| `seeder` | [seeder.md](./seeder.md) | Run finalization, stage 1: inspects the completed diff and adds/updates whatever seed or fixture data this workspace's own convention needs to demonstrate a new human-visible state, then reports the concrete verification steps a reviewer should follow. |
| `reporter` | [reporter.md](./reporter.md) | Run finalization, stage 2: audits persisted run history (including the seeder's verification steps) and writes the reviewer-facing `run-summary.md`. |
| `curator` | [curator.md](./curator.md) | Run finalization, stage 3: selects real local deliverables for upload as review evidence via `select_review_assets`. |
| `demo` | [demo.md](./demo.md) | Run finalization, stage 4: starts (or reuses) the workspace's dev/demo server via `start_run_command`, purely mechanical — it has no task context of its own and does not report verification steps. |
| `git` | [git.md](./git.md) | Run finalization, stage 5 (terminal): the one role with real `.git` write access. Commits source changes, rebases onto `origin/main` (resolving any conflicts itself), pushes, and creates/updates the pull request — once seeder, reporter, curator, and demo have completed. |

`seeder` → `reporter` → `curator` → `demo` → `git` run strictly in sequence (`app/jobs/tick_run_job.rb#finalize_completed_run`); each is granted only its own narrow MCP tool slice by `Orchestrator::WorkerMcpServer`, enforced both by the tool list and by a role check inside each tool. Seeder runs first so its verification steps (and any seeded data) are already in place for every later stage — otherwise the reporter's summary would omit them and demo would have nothing to demonstrate. Unlike the other finalization roles, `seeder` runs with `write_scope: "scoped_changes"` and the workspace's full `protected_write_patterns` — the same wholesale write grant an implementation worker gets — since its whole job is writing real source files (seed scripts, fixtures, factories). It reports its verification steps via `complete_run_finalization`'s `clickPath` parameter — the same mechanism `demo` used to own — because it is the only finalization role with both full task context (`get_run_context`) and knowledge of exactly what data now exists.

Every other role is git-blind by design (`WorkerExecutionPolicy` unconditionally excludes `.git` from writable paths regardless of `write_scope`). `git` is the sole exception, spawned with `write_scope: "git_managed"`; it always starts on the small model tier, and a repeated `[BLOCKED]` failure escalates through `Orchestrator::GitPublicationRecovery` → the normal chaperone threshold, exactly like `VerifierRecovery` does for verifier work — a planner cannot legally dispatch either role directly (see `StepPolicy::PLANNER_STEP_OWNERS`).

Planning itself has no agent file: a worker's `[DONE]`/`[BLOCKED]`/`[FAILED]` result either promotes an already-planned `followingSteps` item directly, or queues one bounded `PlannerDecisionJob` call (tools disabled, structured output only) — never a spawned planner process.

## Running Nicknames

When subagents are running, look for these role-based nicknames (see `build_worker_nickname` in `app/services/orchestrator/spawn_requested_workers.rb`):

| Role | Nickname to look for |
|---|---|
| `worker` | `worker` (or `worker-2`, `worker-3`, ... for concurrent instances across runs) |
| any other role | the role name itself (`seeder`, `reporter`, `curator`, `demo`, `git`, `verifier`, `chaperone`, `project_init`, `infrastructure`), suffixed `-1`, `-2`, ... only if a name collision occurs |

## Key Files

- [ARCHITECTURE.md](../ARCHITECTURE.md) — system design: the run lifecycle, planner context protocol, and finalization pipeline
- [worker.md](./worker.md) — the generic task worker persona, reused as the base for `infrastructure` and `verifier`

## MCP Tools

The workflow is powered by the `workflow` MCP server (registered at [`.mcp.json`](../.mcp.json)). Tool access per role is enforced in `app/services/orchestrator/worker_mcp_server.rb`; individual tools additionally self-check the authenticated worker's role (e.g. `app/services/mcp_tools/complete_run_finalization_tool.rb`).
