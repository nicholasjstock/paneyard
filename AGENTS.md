# Repository Guidelines

## Operating Context

This is not a typical multi-tenant web app under normal clone/test/deploy development. It is a single-operator local tool: one person runs it continuously on their own machine (`bin/service`, wrapping `bin/production`) and there is deliberately no authentication (`ApplicationController#current_operator`'s own comment: "No auth in v1 (single-user local tool)") -- the operator is always the person at the keyboard, or a Telegram user on the configured allow-list (`Telegram::Configuration`, `README.md`'s "Telegram admin chat" section).

**It edits its own source.** This repository is itself registered as one of its own `Workspace` rows -- a run launched from this instance's own UI can hand an autonomous agent write access to the orchestrator's own codebase, which that same running process then supervises, publishes as a PR, and may need to restart itself for (`bin/service restart`, see below). There is no runtime sandbox protecting this repository from itself; the safety net is entirely human PR review before merge, same as any other workspace. Keep this in mind for anything touching process supervision, `config/queue.yml`/`config/recurring.yml`, or the git-worktree lifecycle: a bug here can affect the very process trying to fix it.

**It also edits other, unrelated repos side by side.** The same running instance manages arbitrary target projects as separate `Workspace` rows (each with its own `main` checkout plus sibling run worktrees, its own GitHub repo/owner) -- there is nothing workflow-orchestrator-specific baked into how a run operates; workspace-scoping is the whole point of the `Workspace` model (see below).

**Remote control is a real, load-bearing surface, not a side feature.** Beyond the local web UI, an operator can drive any workspace's admin chat from Telegram (`Telegram::UpdateProcessor`, `Orchestrator::WorkspaceAdminChatDriver`), and GitHub operations across every managed repo (regardless of which account owns it) authenticate through one GitHub App installation (`Orchestrator::GitHubAppAuth`, `GITHUB_APP_SETUP.md`) rather than per-repo credentials.

## Project Structure & Module Organization
This repository is a Rails 8 application organized around `Workspace` as the top-level boundary. New work should start from a specific workspace, and related runs, sessions, events, and artifacts should stay nested under that workspace in code and UI flow. Core server code lives in `app/`: controllers in `app/controllers`, persistence models in `app/models`, background jobs in `app/jobs`, and orchestration logic in `app/services/orchestrator` and `app/services/mcp_tools`. Frontend code uses importmap + Stimulus under `app/javascript`, with views in `app/views` and static assets in `public/`. Database schema and migrations live in `db/`. Operational notes and handoff material belong in root-level docs such as `HANDOFF.md`.

## Build, Test, and Development Commands
Run `bin/setup` to install gems, prepare the database, and clear stale logs/tmp files. Use `bin/dev` for local development; it starts both the Rails server and the Solid Queue worker process so recurring jobs fire. Use `bin/rails db:prepare` after schema changes, and `bin/rails console` for local inspection. Run `bin/ci` before opening a PR; it executes setup, RuboCop, `bundler-audit`, `bin/importmap audit`, and Brakeman.

### Restarting the long-running production instance

`bin/production` (real `storage/production.sqlite3`, real workspaces) is normally kept running continuously, not launched fresh per session. `config/queue.yml` (worker/thread pool shape) and `config/recurring.yml` (the static recurring-job schedule) are both read once at Solid Queue's boot and are **not** picked up by `WORKFLOW_HOT_RELOAD`'s code reloading -- a change to either requires restarting the Solid Queue process, and `bin/production` ties Puma and Solid Queue together as one unit (killing either child stops both).

Don't start `bin/production` directly and don't kill its pid by hand -- use `bin/service` instead, which daemonizes it (detached from any terminal, logs to `log/production_service.log`, tracks its pid in `tmp/pids/production.pid`):

```bash
bin/service start    # no-ops if already running
bin/service stop
bin/service restart  # apply a queue.yml/recurring.yml/credentials change
bin/service status
```

Any agent session (including this one) should run `bin/service restart` directly after a config change that needs it, rather than asking the operator to manage a foreground terminal pane.

## Coding Style & Naming Conventions
Follow the default Rails Omakase style configured in `.rubocop.yml`; run `bin/rubocop` to check formatting. Use two-space indentation in Ruby and keep class and module names `CamelCase` with file names in `snake_case`. Match existing Rails naming patterns such as `*_controller.rb`, `*_job.rb`, and service objects under `app/services/...`. Keep JavaScript controllers in `app/javascript/controllers` with Stimulus-style names like `hello_controller.js`.

## Workspace-First Design
Treat `Workspace` as the precursor to everything else. When adding routes, screens, jobs, or persistence, prefer shapes that scope data by workspace first, then by the nested resource, for example `/workspaces/:workspace_id/runs/:id`. Avoid introducing new top-level flows that bypass workspace selection unless the feature is truly global.

## Sessions, Not Orchestration

Rails does not decide what an agent does next. It decides **which job runs, where, and what happens to the branch afterwards**. Everything else belongs to one continuous interactive session.

A run is a queued job. `RunDispatchJob` claims the oldest queued run when a slot frees (global cap, `Orchestrator::RunConcurrency`, `WORKFLOW_MAX_CONCURRENT_RUNS`, default 4). `StartRunSessionJob` provisions a git worktree and opens **one** interactive `claude`/`codex`/`opencode` session in a herdr pane rooted in it, with the task submitted as live input. That session owns the job end to end: it explores, edits, runs tests, commits, and pushes. The operator can watch it and type into it — from their own herdr client, or from the run screen's message box.

There is no planner, no step queue, no per-step worker, no chaperone, and no acceptance-criteria tree. Do not reintroduce them. If a run needs to change direction, the way to do that is to talk to its session (`Orchestrator::RunSessionRunner.prompt!`), which is also how a pull-request comment reaches it.

A session calls the `report_idle` MCP tool with `done`, `blocked`, or `failed` every time it stops working. This reports, it does not end the run: the pane stays open, the process stays up, the concurrency slot stays held, and nothing is pushed or published. The operator reads the pane and decides — **Open pull request**, send more work (`RunSessionRunner.prompt!`), or **Close session**, which is the only thing that kills the CLI and frees the slot. A session therefore reports many times over a run, and each report is a checkpoint describing only the interval since the previous one; they accumulate as `RunCheckpoint` rows, so the newest is current state and the sequence is the run's history. `RunSessionReconcileJob` is the safety net for a session that genuinely died (pane closed, CLI quit or crashed) — an idle session is not an anomaly to it.

Because the operator holds the slot until they close a session, an unreviewed run blocks the queue: `RunConcurrency::DEFAULT_LIMIT` is 4, overridable with `WORKFLOW_MAX_CONCURRENT_RUNS`.

Key implementation files: `app/services/orchestrator/{herdr,run_session_runner,session_args,session_env,run_prompt,run_concurrency,run_completion}.rb`, `app/jobs/{run_dispatch_job,start_run_session_job,run_session_reconcile_job}.rb`, `app/models/run_session.rb`.

### herdr owns the processes

`Orchestrator::Herdr` is a thin JSON-RPC client for the operator's already-running herdr server (Unix socket, newline-delimited JSON). herdr owns every pty and process; Rails only remembers which pane, which pid, and which CLI session id.

The per-driver flags in `Orchestrator::SessionArgs` were established by running these CLIs for real inside a pane, and several contradict what `--help` implies (codex's `--dangerously-bypass-approvals-and-sandbox` breaks the interactive command; opencode silently never receives input without `--mini`). Do not "simplify" a flag out of that file without re-verifying it live.

Accepted trade-off: a real interactive TUI produces human-rendered output, not structured JSON, so there is **no cost/usage/token accounting for a session**. That was only ever recoverable from `--print --output-format stream-json`, which is exactly the mode this design abandons. Missing cost data is not a bug.

### Worktrees are the durable artifact

Every run gets a sibling worktree of the workspace's `main` checkout (`Orchestrator::GitWorktree`) on a `workflow/<name>` branch. Two things reclaim them, and nothing else should: `RunPublication.cleanup_merged_run!` after a PR merges, and `Orchestrator::WorktreeJanitor` for runs that ended some other way. The janitor never touches `main` and never removes a dirty worktree — uncommitted work in a failed run is exactly what an operator wants back. `--force` is reserved for the explicit per-run button.

### Full access, human review

A session runs with full access to its own worktree (`--permission-mode bypassPermissions`, `-s danger-full-access`, `--auto`). The per-step filesystem sandbox is gone with the planner that authorized it, and so are the protected-path patterns that outlived it as a line of prompt prose. The safety net is human PR review, same as it always actually was.

## Testing Guidelines
The repository uses RSpec under `spec/`. Add service and job regression coverage for run/session state changes, and system coverage for UI behavior. Run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`.

Stub `Orchestrator::Herdr` in specs — never open a live socket, because herdr's mutating calls have real, visible effects in the operator's own session. Do not consume live model capacity to verify dispatch or arg building.

Use real git where git behavior is the thing under test (`spec/services/orchestrator/{worktree_janitor,run_publication}_spec.rb` build actual repos, worktrees, and a bare `origin`): the rules that matter — is this worktree dirty, is there anything to push — are only meaningful against real git. `spec/support/run_fixtures.rb` provides `create_workspace`/`create_run`/`create_run_and_session`.

## Commit & Pull Request Guidelines
Recent commit history favors short, imperative summaries such as `Flatten ops/ into the repo root` and `Port the TS orchestrator engine to Ruby`. Keep commits focused and descriptive. PRs should include a concise problem statement, the implementation approach, any schema or job-queue impact, and manual verification steps. Link related issues when available and include screenshots only for UI changes.

## Security & Configuration Tips
Do not commit decrypted credentials, database dumps, or logs containing run data. Review changes to `config/credentials.yml.enc`, queue configuration, and any MCP tool implementation carefully, because they affect what a session can reach and how a run reports its result.

## MCP Boundary

A session reaches Rails through exactly one endpoint, `/mcp/run`, authenticated by that session's own bearer capability (`RunSession#capability_token_digest`) and dead the moment the session ends. It exposes eight tools (`Orchestrator::RunMcpServer::TOOLS`) and nothing more.

Keep it that way. Anything a real interactive CLI can already do for itself — read files, run commands, edit code, start a dev server — is its own business now that it has full access to its worktree; it does not need a tool from us. What belongs here is only what Rails alone knows or owns: how a run reports where it stands (`report_idle`), the run-scoped artifact store, and the workspace knowledge that outlives any single run. Never expose arbitrary SQL, Active Record lookup, filesystem traversal, or command execution through it.
