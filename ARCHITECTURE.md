# Multi-Agent Workflow Architecture

## System Overview

Rails owns orchestration state, planning, retries, and process dispatch (see [AGENTS.md](./AGENTS.md) and [CLAUDE.md](./CLAUDE.md)). There is no supervisor loop, no planner agent process, and no fixed set of workers running in parallel — a run has at most one active worker (or one bounded planner decision, or one chaperone review) at a time. [`agent_personas/`](./agent_personas) holds the one persona prompt per role, shared by both drivers, layered onto whichever subagent process Rails decides to spawn next.

> Both Claude and Codex read the exact same persona file per role from `agent_personas/` (`Orchestrator::WorkerSpawner#build_prompt_with_persona`) and share the same `workflow` MCP server (`.mcp.json`), so the bus, worker state, and artifacts are visible across both CLI paths within the same run. This used to be two per-driver copies kept in sync by hand; confirmed the content was identical or near-identical, and that duplication already caused real drift once.

```
┌──────────────────────────────────────────────────────────┐
│                         USER                              │
└───────────────────────────┬────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│  TickRunJob (recurring Rails job)                         │
│  - executor + liveness observer, not a second planner     │
│  - detects stalls / dead ends, requests recovery planning │
│  - drives Orchestrator::SpawnRequestedWorkers each tick    │
└───┬─────────────────────┬─────────────────────┬───────────┘
    │                     │                     │
    ↓                     ↓                     ↓
 spawn one           run one bounded        dispatch a
 Worker subagent     PlannerDecisionJob      chaperone review
 (worker/verifier/   (tools disabled,        (repeated failure
 infrastructure/     structured output       under one lineage)
 project_init/       only -- no OS
 reporter/curator/   process spawned)
 seeder/demo/git)
```

Execution is strictly sequential: `Orchestrator::SpawnRequestedWorkers.call_locked` (`app/services/orchestrator/spawn_requested_workers.rb`) refuses to spawn anything while a worker is already `running` for the run, or while a `PlannerDecision` is `queued`/`running`, or (except for its own reviewer) while a `ChaperoneReview` is open.

## Claude vs. Codex: how a spawned worker actually runs

Both drivers get the same task, the same `write_scope`/`allowed_paths`, the same `workflow` MCP tools, and now the same persona text — but `Orchestrator::WorkerSpawner` runs them with genuinely different process shapes, for reasons specific to each CLI, not stylistic preference.

**`chdir` differs, and it's load-bearing.** A Codex worker's process starts directly inside `root_dir` (the real worktree). A Claude worker's process starts inside a disposable scratch directory (`tmp/workers/<run_id>-<role>`) instead — `root_dir` is granted only via `--add-dir`, which is a read/tool-access grant, not a new working directory. This is deliberate: confirmed live, Claude's Bash tool always implicitly permits writes to its own current working directory, regardless of what's on the Edit/Write allow-list (a worker granted only `Bash,Read,Grep,Glob` still wrote a real file into its cwd). If a Claude worker `chdir`'d straight into `root_dir`, every worker — including a `source_protected` one meant to be fully read-only — would get unrestricted write access to the real repository via Bash alone, defeating `WorkerExecutionPolicy` entirely. Codex's own `--sandbox <mode>` is a genuine OS/policy-level write restriction rather than a cwd trick, so `chdir`-ing it into `root_dir` carries no equivalent risk.

**Side effect: `CLAUDE.md` isn't auto-discovered for a Claude worker.** Since its process never actually starts inside a real git checkout, Claude's own project-instructions convention never triggers — confirmed live via the exact real invocation shape (`--add-dir`, no Edit/Write, `bypassPermissions`). `worker_identity_prompt` (`app/services/orchestrator/worker_spawner.rb`) compensates by telling a Claude worker explicitly to read `#{target_root}/CLAUDE.md`, only when `driver == "claude"`. Codex workers need no such note — `chdir`-ing into the real worktree means `AGENTS.md` auto-loads correctly on its own (also confirmed live); adding the note there would be redundant.

**Session resumption is why the scratch directory is keyed on `(run_id, role)`, not a session or worker id.** (See git history: `e4440f9`, "Fix worker session resumption.") Claude Code's own session storage is scoped to the exact cwd path a session was created in — a fresh directory per spawn broke `--resume` outright ("No conversation found with session ID"), and once a same-role worker inherited a now-dead session id, every subsequent spawn kept inheriting it, forever. Neither driver is pre-assigned a session id anymore either (Claude used to be; nothing forced that, since the admin chat's own `ClaudeProvider` already let Claude mint its own and discover it afterward, exactly like Codex) — both mint their own session id on a fresh spawn and Rails learns it after the fact from the captured log (`Orchestrator::LogReader.claude_session_id`/`codex_session_id`). Confirmed live, twice: a stable, shared directory correctly resumes the right session among several distinct ones with no cross-contamination; and `prior_worker_for_resume` reconciling a not-yet-backfilled predecessor's session id lazily, right at the point of decision (rather than only ever depending on `WorkerReconcileJob`'s recurring tick), correctly resumed a real predecessor's session with zero reconciliation job ever having run. `(run_id, role)` is the one thing guaranteed identical between the spawn that creates a session and any later spawn that resumes it, known before either process starts, unlike a session id that doesn't exist yet on a fresh spawn.

**Codex has its own startup guard worth knowing about.** `codex exec`/`codex exec resume` refuse to start at all outside a trusted or git-tracked directory unless passed `--skip-git-repo-check` — required for the workspace admin chat (`CodexProvider::build_args`) since its cwd (`Workspace#root_path`) is deliberately not a git repository itself, and also passed defensively in `PlannerDecisionRunner.run_codex` even though `run.target_root` is always a real worktree in practice. Task workers (`WorkerSpawner`) don't need it for the same reason.

**Two independent knobs per spawn: model tier and reasoning effort.** `model_tier` (`small`/`strong`) picks the model name (`claude_model_for`/`codex_model_for`); `effort` is a separate, optional parameter threaded through `claude_args` (`--effort <level>`) and `codex_args` (`-c model_reasoning_effort="<level>"`, since Codex has no dedicated flag). They can be set independently — the chaperone spawn passes `model_tier: "strong", effort: "high"`; the planner defaults to `effort: "high"` regardless of its own tier (`PlannerDecisionRunner::DEFAULT_EFFORT`). Unset anywhere else, both CLIs fall back to their own default.

## The Run Lifecycle

```
worker executes its assigned task
    ↓
worker_turn: [DONE] | [BLOCKED] | [FAILED]
    ↓
[DONE] + a validated followingSteps queue → Rails promotes the next step directly (no planner call)
otherwise                                  → Rails queues one bounded PlannerDecisionJob
    ↓
planner_turn: nextStep (+ followingSteps) | needs_context | needs_stronger_model
    ↓
Rails dispatches nextStep, resolves needs_context and reruns, or reruns on the stronger tier
    ↓
... repeats until the run's following-steps queue and acceptance criteria are satisfied ...
    ↓
run reaches phase "completed" → finalization pipeline (below)
```

## Planning: a bounded decision function, not an agent

A planner turn is not a spawned process — it is one `PlannerDecisionJob` run with tools disabled, built from a compact brief (`Orchestrator::PlannerBrief`) and validated/persisted by `Orchestrator::Turn`. Every turn returns exactly one of:

- `nextStep` (+ `followingSteps`) — the single next unit of work, queued for direct promotion after that worker's `[DONE]`.
- `needs_context` — one `contextRequest` (`source`, `reference`, `question`, `offset`, `maxChars`); Rails resolves it and reruns with accumulated context. An identical repeated request is rejected since it cannot add information.
- `needs_stronger_model` — Rails reruns the same decision on the stronger tier with unchanged context; the promotion is recorded.

Planning always starts on the smaller model tier, at high reasoning effort by default (see above). See [AGENTS.md](./AGENTS.md)'s Planner Context Protocol section for the exact contract, and `app/jobs/planner_decision_job.rb` / `app/services/orchestrator/{planner_brief,planner_context_resolver,planner_decision_runner,turn}.rb` for the implementation.

## Recovery and the chaperone

`TickRunJob` detects two conditions worth escalating: a worker stalled (running but idle past threshold), or a dead-ended run (no active worker, no open request, never marked `completed`). Either publishes a spawn request for a recovery planner decision — suppressed while a `blocking` `UserQuestion` is already open, so the same stall is never re-escalated twice.

Repeated unsuccessful attempts under one stable `lineageKey` trigger a **chaperone** (`agent_personas/chaperone.md`, strong model tier, high effort): a strong-model review confined to the capability-scoped `/mcp/chaperone` endpoint (`Orchestrator::ChaperoneMcpServer` — curated state, bounded artifact reads, and a single `submit_chaperone_decision` call). It decides `continue_small`, `promote`, or `stop`; it never gets arbitrary SQL, filesystem, or shell access. Its persona covers both review types it might see (a planner-subject or a diagnosis-lineage review) — it reads `subjectType` off `get_chaperone_state` to know which applies; Rails doesn't pick between two different prompts.

## Finalization pipeline

Once a run reaches `phase: "completed"`, `TickRunJob#finalize_completed_run` queues five terminal roles strictly in sequence, each with its own narrow MCP tool slice (`Orchestrator::WorkerMcpServer`) and its own role check inside the tools it's allowed to call:

```
run completed
  → seeder     (write_scoped_file, write seed-data.md,             → complete_run_finalization
                report clickPath = verification steps)
  → reporter   (get_run_audit, write run-summary.md)               → complete_run_finalization
  → curator    (select_review_assets, write review-assets.md)      → complete_run_finalization
  → demo       (start_run_command, write demo-notes.md)            → complete_run_finalization
  → git        (real .git access: commit, rebase onto origin/main,  → finalize_run_publication
                resolving any conflicts itself; push; gh pr
                create/edit/ready; gh release for review assets)
  → approval → Rails deletes the draft release, merges, removes the worktree
```

Seeder runs first, ahead of reporter and curator, for two reasons: the reporter's audit must be able to describe what was seeded and how to verify it, and the demo role needs the seeded data to already exist. Seeder — not demo — owns the reviewer-facing verification steps (`complete_run_finalization`'s `clickPath` parameter, the same field `worker_turn` also exposes to ordinary workers): it is the only finalization role with both full task context (`get_run_context`) and knowledge of exactly what data now exists, where demo has neither and is purely mechanical (start/reuse the server, confirm it is listening). Reporter, curator, and seeder must explicitly call `complete_run_finalization` after writing their assigned artifact; the git worker calls `finalize_run_publication` instead, exactly once, as its own terminal signal. Unlike every other finalization role, seeder is spawned with `write_scope: "scoped_changes"` and the workspace's full `protected_write_patterns` — the same wholesale grant an implementation worker gets — because its entire job is writing real seed/fixture files for the git worker to pick up afterward. Any `run_commands` process the demo role starts (or any other worker leaves running) is stopped automatically once the run reaches a terminal status (`Run#stop_active_run_commands`) — no manual cleanup step is needed.

Note: each finalization `SpawnRequest`'s task `text` is deliberately just `"Begin."` — the full behavior lives entirely in that role's persona file (auto-prepended to every spawn of that role), not restated inline. This also used to be a second, hand-maintained copy of each persona's rules.

### The git worker: the one role with real `.git` access

Every other role in this system is git-blind by design — `WorkerExecutionPolicy` unconditionally excludes `.git` from every writable path, regardless of `write_scope`. The `git` role is the sole, deliberate exception: it is spawned with `write_scope: "git_managed"`, which grants full recursive write over its worktree (including `.git`), and its persona (`agent_personas/git.md`) owns the *entire* commit → conflict-repair → rebase → push → PR sequence itself, using real `git status`/`git diff`/`git log` visibility — not a text description of which paths conflicted.

It always starts on the small model tier, same as any other dispatch — never hardcoded to strong. If it reports `[BLOCKED]` (a genuinely ambiguous conflict, or repeated rejected pushes), `Orchestrator::GitPublicationRecovery` intercepts that failure the same way `VerifierRecovery` does for verifier work (a planner cannot legally dispatch `git`-role work either — see `StepPolicy::PLANNER_STEP_OWNERS`): the first failure just requeues a fresh small-tier git worker directly; a second failure on the same lineage crosses the normal chaperone threshold and a strong-model chaperone review decides whether to continue small, promote, or stop.

A PR comment resuming an already-published run always triggers a fresh git-worker reconciliation pass first (`Orchestrator::PullRequestResume` → `RunPublication.queue_worker!`), regardless of what the comment says — rebasing against `main` is cheap and idempotent, so there is no special phrase to match. The comment still goes to the planner too, in case it also asks for further work; the planner already knows (from its own brief) that git/commit hygiene is never something it should plan around.

## Coordination Rules

- Rails (`TickRunJob` + `Orchestrator::SpawnRequestedWorkers`) is the only thing that spawns processes; no agent spawns another agent directly.
- A worker never manages its own lifecycle (no `spawn_worker`/`stop_worker`); it reports via `worker_turn` and Rails decides what happens next.
- If a worker needs a missing downstream capability, it raises `[BLOCKED]` through `worker_turn` (or, mid-task, asks a spawned planner) rather than acting outside its assigned scope.
- Finalization roles never call each other's tools — `Orchestrator::WorkerMcpServer` and each tool's own role guard enforce that independently.
