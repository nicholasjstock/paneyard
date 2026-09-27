# Repository Guidelines

## Operating Context

This is not a typical multi-tenant web app under normal clone/test/deploy development. It is a single-operator local tool: one person runs it continuously on their own machine (`bin/service`, wrapping `bin/production`) and there is deliberately no authentication (`ApplicationController#current_operator`'s own comment: "No auth in v1 (single-user local tool)") -- the operator is always the person at the keyboard, or a Telegram user on the configured allow-list (`Telegram::Configuration`, `README.md`'s "Telegram admin chat" section).

**It edits its own source.** This repository is itself registered as one of its own `Workspace` rows -- a run launched from this instance's own UI can hand an autonomous agent write access to the orchestrator's own codebase, which that same running process then supervises and may need to restart itself for (`bin/service restart`, see below). There is no runtime sandbox protecting this repository from itself, and no mandatory PR-review gate either -- a session (or the operator) may commit and merge straight into `main`. Keep this in mind for anything touching process supervision, `config/queue.yml`/`config/recurring.yml`, or the git-worktree lifecycle: a bug here can affect the very process trying to fix it.

**It also edits other, unrelated repos side by side.** The same running instance manages arbitrary target projects as separate `Workspace` rows (each with its own `main` checkout plus sibling run worktrees, its own GitHub repo/owner) -- there is nothing workflow-orchestrator-specific baked into how a run operates; workspace-scoping is the whole point of the `Workspace` model (see below).

**Remote control is a real, load-bearing surface, not a side feature.** Beyond the local web UI, an operator can drive any workspace's admin chat from Telegram (`Telegram::UpdateProcessor`, `Orchestrator::WorkspaceAdminChatDriver`), and GitHub operations across every managed repo (regardless of which account owns it) authenticate through one GitHub App installation (`Orchestrator::GitHubAppAuth`, `GITHUB_APP_SETUP.md`) rather than per-repo credentials.

If you are a session spawned by this very system -- a run working in a worktree of this repo -- all of the above applies to you directly, not hypothetically.

## Project Structure & Module Organization
This repository is a Rails 8 application organized around `Workspace` as the top-level boundary. New work should start from a specific workspace, and related runs, sessions, events, and artifacts should stay nested under that workspace in code and UI flow. Core server code lives in `app/`: controllers in `app/controllers`, persistence models in `app/models`, background jobs in `app/jobs`, and orchestration logic in `app/services/orchestrator` and `app/services/mcp_tools`. Frontend code uses importmap + Stimulus under `app/javascript`, with views in `app/views` and static assets in `public/`. Database schema and migrations live in `db/`.

## Build, Test, and Development Commands
Run `bin/setup` to install gems, prepare the database, and clear stale logs/tmp files. Use `bin/dev` for local development; it starts both the Rails server and the Solid Queue worker process so recurring jobs fire. Use `bin/rails db:prepare` after schema changes, and `bin/rails console` for local inspection. `bin/ci` executes setup, RuboCop, `bundler-audit`, `bin/importmap audit`, and Brakeman.

### Restarting the long-running production instance

`bin/production` (real `storage/production.sqlite3`, real workspaces) is normally kept running continuously, not launched fresh per session. `config/queue.yml` (worker/thread pool shape) and `config/recurring.yml` (the static recurring-job schedule) are both read once at Solid Queue's boot and are **not** picked up by `WORKFLOW_HOT_RELOAD`'s code reloading -- a change to either requires restarting the Solid Queue process, and `bin/production` ties Puma and Solid Queue together as one unit (killing either child stops both).

Don't start `bin/production` directly and don't kill its pid by hand -- use `bin/service` instead, which daemonizes it (detached from any terminal, logs to `log/production_service.log`, tracks its pid in `tmp/pids/production.pid`):

```bash
bin/service start    # no-ops if already running
bin/service stop
bin/service restart  # apply a queue.yml/recurring.yml/credentials change
bin/service status
```

An agent session working in the `main` checkout should run `bin/service restart` directly after a config change that needs it, rather than asking the operator to manage a foreground terminal pane. A run session must not: it works in a worktree, so a restart would reload `main`'s code rather than its own, and would briefly take down the `/mcp/run` endpoint it reports through. Say in the report that a restart is needed once the change is merged.

## Coding Style & Naming Conventions
Follow the default Rails Omakase style configured in `.rubocop.yml`; run `bin/rubocop` to check formatting. Use two-space indentation in Ruby and keep class and module names `CamelCase` with file names in `snake_case`. Match existing Rails naming patterns such as `*_controller.rb`, `*_job.rb`, and service objects under `app/services/...`. Keep JavaScript controllers in `app/javascript/controllers` with Stimulus-style names like `hello_controller.js`.

## Workspace-First Design
Treat `Workspace` as the precursor to everything else. When adding routes, screens, jobs, or persistence, prefer shapes that scope data by workspace first, then by the nested resource, for example `/workspaces/:workspace_id/runs/:id`. Avoid introducing new top-level flows that bypass workspace selection unless the feature is truly global.

## Sessions, Not Orchestration

Rails does not decide what an agent does next. It decides **which job runs, where, and what happens to the branch afterwards**. Everything else belongs to one continuous interactive session.

A run is a queued job. `RunDispatchJob` claims the oldest queued run when a slot frees (global cap, `Orchestrator::RunConcurrency`, `WORKFLOW_MAX_CONCURRENT_RUNS`, default 4). `StartRunSessionJob` provisions a git worktree and opens **one** interactive `claude`/`codex`/`opencode` session in a herdr pane rooted in it, with the task submitted as live input. That session owns the job end to end: it explores, edits, and runs tests, then leaves its changes uncommitted for the operator to try. It commits, pushes, or merges into `main` only when asked. The operator can watch it and type into it — from their own herdr client, or from the run screen's message box.

There is no planner, no step queue, no per-step worker, no chaperone, no acceptance-criteria tree, and no GitHub-mediated question protocol. Do not reintroduce them: they existed to compensate for headless one-shot workers with no continuity and no operator in the loop, and a session has both. If a run needs to change direction, the way to do that is to talk to its session (`Orchestrator::RunSessionRunner.prompt!`).

A session calls the `report_idle` MCP tool with `done`, `blocked`, or `failed` every time it stops working. This reports, it does not end the run: the pane stays open, the process stays up, the concurrency slot stays held, and nothing is pushed. The operator reads the report and decides — send more work (`RunSessionRunner.prompt!`) or **Close session**, which is the only thing that kills the CLI and frees the slot (a `done` run then becomes `completed`). The summary is a full Markdown report — what changed and why, how it was verified, what is left — because the run screen shows the checkpoints and not the pane. A session therefore reports many times over a run, and each report is a checkpoint describing only the interval since the previous one; they accumulate as `RunCheckpoint` rows, so the newest is current state and the sequence is the run's history. `RunSessionReconcileJob` is the safety net for a session that genuinely died (pane closed, CLI quit or crashed) — an idle session is not an anomaly to it.

Rails does not do pull requests. When asked, the session pushes its own branch or merges it into `main`; opening, reviewing and merging a PR happens outside this app. There is no publishing, merge polling, or PR-comment resumption, and they should not come back.

Because the operator holds the slot until they close a session, an unreviewed run blocks the queue: `RunConcurrency::DEFAULT_LIMIT` is 4, overridable with `WORKFLOW_MAX_CONCURRENT_RUNS`.

Key implementation files: `app/services/orchestrator/{herdr,run_session_runner,session_args,session_env,run_prompt,run_concurrency,run_completion}.rb`, `app/jobs/{run_dispatch_job,start_run_session_job,run_session_reconcile_job}.rb`, `app/models/run_session.rb`.

### herdr owns the processes

`Orchestrator::Herdr` is a thin JSON-RPC client for the operator's already-running herdr server (Unix socket, newline-delimited JSON). herdr owns every pty and process; Rails only remembers which pane, which pid, and which CLI session id.

The per-driver flags in `Orchestrator::SessionArgs` were established by running these CLIs for real inside a pane, and several contradict what `--help` implies (codex's `--dangerously-bypass-approvals-and-sandbox` breaks the interactive command; opencode silently never receives input without `--mini`). Do not "simplify" a flag out of that file without re-verifying it live.

Accepted trade-off: a real interactive TUI produces human-rendered output, not structured JSON, so there is **no cost/usage/token accounting for a session**. That was only ever recoverable from `--print --output-format stream-json`, which is exactly the mode this design abandons. Missing cost data is not a bug.

### Worktrees are the durable artifact

Every run gets a sibling worktree of the workspace's `main` checkout (`Orchestrator::GitWorktree`) on a `workflow/<name>` branch. Two things reclaim them, and nothing else should: `Orchestrator::WorktreeJanitor` — straight away on **Close session** (`release!`), when `RunSessionReconcileJob` finds a run's herdr workspace was closed by hand (the same `release!`), and on its ten-minute sweep — and the run screen's **Remove worktree** button. There is no age-based retention: the janitor never touches `main` and removes a worktree only once its session is over and it is clean with HEAD already on `main` or a remote branch (removal keeps the branch). Anything else is kept indefinitely and flagged as a kept worktree (`Run#kept_worktree?`) on the runs list and run screen — uncommitted or unpushed work is exactly what an operator wants back. `--force` is reserved for the explicit per-run button.

### Full access, no separate review gate

A session runs with full access to its own worktree (`--permission-mode bypassPermissions`, `-s danger-full-access`, `--auto`). The per-step filesystem sandbox is gone with the planner that authorized it, and so are the protected-path patterns that outlived it as a line of prompt prose. There is no mandatory PR-review step either: when the operator asks, a session may merge its branch directly into `main` without waiting on a separate review.

## Testing Guidelines
The repository uses RSpec under `spec/`. Add service and job regression coverage for run/session state changes, and system coverage for UI behavior. Run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`.

Stub `Orchestrator::Herdr` in specs — never open a live socket, because herdr's mutating calls have real, visible effects in the operator's own session. Do not consume live model capacity to verify dispatch or arg building.

Use real git where git behavior is the thing under test (`spec/services/orchestrator/worktree_janitor_spec.rb` builds actual repos, worktrees, and a bare `origin`): the rules that matter — is this worktree dirty, is there anything to push — are only meaningful against real git. `spec/support/run_fixtures.rb` provides `create_workspace`/`create_run`/`create_run_and_session`.

## Commit & Pull Request Guidelines
Recent commit history favors short, imperative summaries such as `Flatten ops/ into the repo root` and `Port the TS orchestrator engine to Ruby`. Keep commits focused and descriptive. A run session commits only when the operator asks (see Sessions, Not Orchestration). If the operator opens a PR, it should include a concise problem statement, the implementation approach, any schema or job-queue impact, and manual verification steps. Link related issues when available and include screenshots only for UI changes.

## Security & Configuration Tips
Do not commit decrypted credentials, database dumps, or logs containing run data. Review changes to `config/credentials.yml.enc`, queue configuration, and any MCP tool implementation carefully, because they affect what a session can reach and how a run reports its result.

## MCP Boundary

A run session reaches Rails through `/mcp/run`, authenticated by that session's own bearer capability (`RunSession#capability_token_digest`) and dead the moment the session ends. A second, standing endpoint, `/mcp/admin`, carries no auth at all — consistent with this app's "no auth in v1" trust boundary everywhere else (Puma binds `127.0.0.1` only) — and exists for the operator's own external MCP clients, principally their everyday Claude Code session, to queue and inspect runs without opening the web UI.

Both draw from the same small tool set (`Orchestrator::RunMcpServer::TOOLS` / `Orchestrator::AdminMcpServer::TOOLS`): `queue_run`, `list_runs`, `get_run`, and `list_workspaces` are shared by both endpoints, because queuing a run or asking what's running is the same operation regardless of who's asking (`McpTools::WorkspaceResolution` is what lets the same tool code serve a caller with no run of its own — an explicit `workspace:` argument, else the calling run's own workspace, else the oldest registered one; `list_workspaces` is how a caller finds the name to pass). `report_idle` and `record_workspace_env_var` remain run-session-only, since only a live session has a result to report or a process that needs an env var. There is no MCP artifact store: files the operator attaches at launch are stored under the workspace's main checkout and handed to the session as a path in its prompt.

Keep the surface at that. Anything a real interactive CLI can already do for itself — read files, run commands, edit code, start a dev server — is its own business now that it has full access to its worktree; it does not need a tool from us. Never expose arbitrary SQL, Active Record lookup, filesystem traversal, or command execution through either endpoint.

The "workspace admin chat" feature (`WorkspaceAdminChatDriver`, `WorkspaceAdminChat`) that originally scoped `queue_run`/`list_runs`/`get_run` to its own capability token (`McpTools::AdminChatAuthorization`) never got as far as a mounted endpoint or a live `--mcp-config`, and is effectively dormant now that herdr's interactive panes cover the same remote-control need more directly. `McpTools::AdminChatAuthorization`, `ReadRunPromptTool`, `ReadSessionPaneTool`, and `SendToSessionTool` still exist for it and remain unreachable until (if ever) it's finished or removed.

There used to also be a durable, evidence-backed "project memory" store (`get_project_memory`/`record_project_memory_entry`/`record_project_setup`, `WorkspaceMemoryEntry`) prepended to every run's prompt. It was removed deliberately — if old commits or docs still reference it, that is not an oversight; recreate it only if it turns out to actually be missed.
