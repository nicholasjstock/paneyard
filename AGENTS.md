# Repository Guidelines

## Operating Context

This is not a typical multi-tenant web app under normal clone/test/deploy development. It is a single-operator local tool: one person runs it continuously on their own machine (`bin/service`, wrapping `bin/production`) and there is deliberately no authentication (`ApplicationController#current_operator`'s own comment: "No auth in v1 (single-user local tool)") -- the operator is always the person at the keyboard, or a Telegram user on the configured allow-list (`Telegram::Configuration`, `README.md`'s "Telegram remote control" section).

**It edits its own source.** This repository is itself registered as one of its own `Workspace` rows -- a run launched from this instance's own UI can hand an autonomous agent write access to the orchestrator's own codebase, which that same running process then supervises and may need to restart itself for (`bin/service restart`, see below). There is no runtime sandbox protecting this repository from itself, and no mandatory PR-review gate either -- a session (or the operator) may commit and merge straight into `main`. Keep this in mind for anything touching process supervision, `config/queue.yml`/`config/recurring.yml`, or the git-worktree lifecycle: a bug here can affect the very process trying to fix it.

**It also edits other, unrelated repos side by side.** The same running instance manages arbitrary target projects as separate `Workspace` rows (each with its own `main` checkout plus sibling run worktrees, its own GitHub repo/owner) -- there is nothing workflow-orchestrator-specific baked into how a run operates; workspace-scoping is the whole point of the `Workspace` model (see below).

**Remote control is a real, load-bearing surface, not a side feature.** Beyond the local web UI, an operator can list live sessions, read their panes and checkpoints, and type into them from Telegram (`Telegram::UpdateProcessor`, straight onto `RunSessionRunner.snapshot`/`prompt!` -- no agent in between), and GitHub operations across every managed repo (regardless of which account owns it) authenticate through one GitHub App installation (`Orchestrator::GitHubAppAuth`, `GITHUB_APP_SETUP.md`) rather than per-repo credentials.

If you are a session spawned by this very system -- a run working in a worktree of this repo -- all of the above applies to you directly, not hypothetically.

## Project Structure & Module Organization
This repository is a Rails 8 application organized around `Workspace` as the top-level boundary. New work should start from a specific workspace, and related runs, sessions, events, and artifacts should stay nested under that workspace in code and UI flow. Core server code lives in `app/`: controllers in `app/controllers`, persistence models in `app/models`, background jobs in `app/jobs`, and orchestration logic in `app/services/orchestrator` and `app/services/mcp_tools`. Frontend code uses importmap + Stimulus under `app/javascript`, with views in `app/views` and static assets in `public/`. Database schema and migrations live in `db/`.

## Build, Test, and Development Commands
Run `bin/setup` to install gems, prepare the database, and clear stale logs/tmp files. Use `bin/dev` for local development; it starts both the Rails server and the Solid Queue worker process so recurring jobs fire. `bin/dev` is **not** isolated -- it runs the full recurring schedule (Telegram polling, the worktree janitor) against whatever herdr socket the shell has -- so a run session must use `bin/sandbox` instead (see "Testing Guidelines"). Use `bin/rails db:prepare` after schema changes, and `bin/rails console` for local inspection. `bin/ci` executes setup, RuboCop, `bundler-audit`, `bin/importmap audit`, and Brakeman.

### Restarting the long-running production instance

`bin/production` (real `storage/production.sqlite3`, real workspaces) is normally kept running continuously, not launched fresh per session. `config/queue.yml` (worker/thread pool shape) and `config/recurring.yml` (the static recurring-job schedule) are both read once at Solid Queue's boot and are **not** picked up by `WORKFLOW_HOT_RELOAD`'s code reloading -- a change to either requires restarting the Solid Queue process, and `bin/production` ties Puma and Solid Queue together as one unit (killing either child stops both).

Don't start `bin/production` directly and don't kill its pid by hand -- use `bin/service` instead, which daemonizes it (detached from any terminal, logs to `log/production_service.log`, tracks its pid in `tmp/pids/production.pid`):

```bash
bin/service start    # no-ops if already running; waits for /up to answer
bin/service stop
bin/service restart  # apply a queue.yml/recurring.yml/credentials change
bin/service status
```

`restart` runs `bin/preflight --prod-copy` first (see "Testing Guidelines") and **leaves the running instance alone if it fails** -- a change that cannot boot, migrate, or parse its schedule never takes the working instance down. `bin/service restart --skip-preflight` is the escape hatch. `start` fails if `/up` has not answered within two minutes, with the log path.

An agent session working in the `main` checkout should run `bin/service restart` directly after a config change that needs it, rather than asking the operator to manage a foreground terminal pane. A run session must not: it works in a worktree, so a restart would reload `main`'s code rather than its own, and would briefly take down the `/mcp/run` endpoint it reports through. Say in the report that a restart is needed once the change is merged.

## Coding Style & Naming Conventions
Follow the default Rails Omakase style configured in `.rubocop.yml`; run `bin/rubocop` to check formatting. Use two-space indentation in Ruby and keep class and module names `CamelCase` with file names in `snake_case`. Match existing Rails naming patterns such as `*_controller.rb`, `*_job.rb`, and service objects under `app/services/...`. Keep JavaScript controllers in `app/javascript/controllers` with Stimulus-style names like `hello_controller.js`.

## Workspace-First Design
Treat `Workspace` as the precursor to everything else. When adding routes, screens, jobs, or persistence, prefer shapes that scope data by workspace first, then by the nested resource, for example `/workspaces/:workspace_id/runs/:id`. Avoid introducing new top-level flows that bypass workspace selection unless the feature is truly global.

## Sessions, Not Orchestration

Rails does not decide what an agent does next. It decides **which job runs, where, and what happens to the branch afterwards**. Everything else belongs to one continuous interactive session.

A run is a queued job. `RunDispatchJob` claims the oldest queued run when a slot frees (global cap, `Orchestrator::RunConcurrency`, `WORKFLOW_MAX_CONCURRENT_RUNS`, default 4). `StartRunSessionJob` provisions a git worktree and opens **one** interactive `claude`/`codex`/`opencode` session in a herdr pane rooted in it, with the task submitted as live input. That session owns the job end to end: it explores, edits, and runs tests, then leaves its changes uncommitted for the operator to try. It commits, pushes, or merges into `main` only when asked. The operator can watch it and type into it — from their own herdr client, or from the run screen's message box.

There is no planner, no step queue, no per-step worker, no chaperone, no acceptance-criteria tree, and no GitHub-mediated question protocol. Do not reintroduce them: they existed to compensate for headless one-shot workers with no continuity and no operator in the loop, and a session has both. If a run needs to change direction, the way to do that is to talk to its session (`Orchestrator::RunSessionRunner.prompt!`).

A session calls the `report_idle` MCP tool with `done`, `blocked`, or `failed` every time it stops working. This reports, it does not end the run: the pane stays open, the process stays up, the concurrency slot stays held, and nothing is pushed. The operator reads the report and decides — send more work (`RunSessionRunner.prompt!`) or **Close session**, which is the only thing that kills the CLI and frees the slot (a `done` run then becomes `completed`). The summary is a full Markdown report — what changed and why, how it was verified, what is left — because the run screen shows the checkpoints and not the pane. A session therefore reports many times over a run, and each report is a checkpoint describing only the interval since the previous one; they accumulate as `RunCheckpoint` rows, so the newest is current state and the sequence is the run's history. `RunSessionReconcileJob` is the safety net for a session that genuinely died (pane closed, CLI quit or crashed) — an idle session is not an anomaly to it. Nor is a session still `starting`: `RunSessionRunner.start!` owns it until it is running or its own rescue has failed it (with the agent pane's last screen kept in the session result), and reconciling it mid-launch once removed the worktree the CLI was about to start in.

Rails does not do pull requests. When asked, the session pushes its own branch or merges it into `main`; opening, reviewing and merging a PR happens outside this app. There is no publishing, merge polling, or PR-comment resumption, and they should not come back.

Because the operator holds the slot until they close a session, an unreviewed run blocks the queue: `RunConcurrency::DEFAULT_LIMIT` is 4, overridable with `WORKFLOW_MAX_CONCURRENT_RUNS`.

Key implementation files: `app/services/orchestrator/{runner,run_session_runner,run_prompt,run_concurrency,run_completion}.rb`, `app/services/orchestrator/runner/{local,session_launcher,herdr,session_args}.rb`, `app/jobs/{run_dispatch_job,start_run_session_job,run_session_reconcile_job}.rb`, `app/models/run_session.rb`.

### Orchestrator and runner

The app is split into two halves, so that the orchestrator can eventually run on a different machine from the one that runs the sessions. Today both halves are in one process on one machine, and nothing about how a run behaves depends on the split.

- **The orchestrator** is everything that is not under `app/services/orchestrator/runner/`: the database, the UI, both MCP endpoints, Telegram, the queue and concurrency, run and session state, which worktree belongs to which run and whether its session is over, prompt composition, workspace layouts (parsing and validation), workspace env vars, default models, and minting GitHub App tokens.
- **The runner** (`Orchestrator::Runner`, `app/services/orchestrator/runner{.rb,/}`) is everything that has to happen on the machine that hosts herdr, the agent CLIs, the git checkouts and the worktrees: herdr calls, launching and driving a session (`Runner::SessionLauncher`, `SessionLayout`, `SessionArgs`), the session's runtime files and its process environment (`Runner::ProcessEnv`: sanitizing this process's env, the codex key, the `gh auth token` fallback), git (`Runner::Worktrees`: provisioning, "is this worktree registered, dirty, saved elsewhere", removal), process signals, launch attachments (`Runner::Attachments`), and discovering which models the installed CLIs offer (`Runner::ModelDiscovery`).

The orchestrator reaches the runner only through `Orchestrator::Runner.for(workspace)`, which returns a runner object. Today that is always the single in-process `Runner::Local`; it takes the workspace so that a workspace can later name its own runner. `Runner::Local`'s public methods *are* the interface, and a remote runner would implement the same ones:

- worktrees: `provision_worktree`, `worktree_registered?`, `release_worktree`, `remove_worktree`, `reclaim_worktrees(source_root:, keep:)`, `origin_url`
- sessions: `open_session(spec)` then `launch_agent(spec, pane_id:, mcp_config_path:)` (two calls, so the panes are recorded before the launch and a failed or abandoned launch can still be read and closed), `agent_state`, `send_prompt`, `snapshot`, `process_alive?`, `terminate`, `close_workspace`, `notify`
- the machine: `available_models`, `store_attachment`, `attachments`, `attachments_dir`

Only plain data crosses: strings, integers, booleans, and hashes and arrays of them. No Active Record object goes in, and the runner never reads the database; for example, the janitor passes `keep:`, the worktrees whose runs are still working, instead of letting git code look runs up. A session's `spec` (`RunSessionRunner.session_spec`) carries everything a launch needs, already resolved by the orchestrator (the model, its own `/mcp` URL, the layout as data, the env layers, any GitHub App token). Paths such as a workspace's `source_root`, a run's `target_root` and a session's `prompt_path` belong to the runner's machine: the orchestrator stores them and hands them back, and never stats or opens them itself. Errors cross as `Runner::Error`, `Runner::Unreachable` (herdr never answered, which says nothing about the pane) and `Runner::LaunchError`; herdr's and git's own error classes stay inside.

`spec/boundary_spec.rb` fails if anything under `app/` outside the runner references herdr or a runner internal, runs a command, shells out to git, signals a process, or touches the filesystem. Two orchestrator files are allow-listed for commands of their own: `github_app_auth.rb` (curl to the GitHub API) and `sandbox.rb` (`ps`, a sandbox guard the runner consults). When the orchestrator needs something new from the machine, add a method to the runner and call that; don't reach around it.

### herdr owns the processes

`Orchestrator::Runner::Herdr` is a thin JSON-RPC client for the operator's already-running herdr server (Unix socket, newline-delimited JSON). herdr owns every pty and process; Rails only remembers which pane, which pid, and which CLI session id.

The per-driver flags in `Orchestrator::Runner::SessionArgs` were established by running these CLIs for real inside a pane, and several contradict what `--help` implies (codex's `--dangerously-bypass-approvals-and-sandbox` breaks the interactive command; opencode silently never receives input without `--mini`). Do not "simplify" a flag out of that file without re-verifying it live.

A run's herdr workspace is built from its `Workspace`'s **layout** (`workspaces.layout`, YAML; `Orchestrator::WorkspaceLayout` parses it and hands it to the runner as data, `Orchestrator::Runner::SessionLayout` builds it; nil means the default: agent plus an `nvim .` split, which the runner drops when its machine has no nvim). The agent pane is obligatory and always the first tab's root. It is the only pane Rails records (`herdr_pane_id`), so `RunSessionReconcileJob` keys off it alone, and a crashed log tail can't look like a dead session. Every other pane is set up once at session start and then forgotten, with no supervision. `workspace.close` takes all of them down, and `mark_pane_lost!` closes the workspace so none outlive the agent. Every pane gets the agent's full env, passed on each creating call because herdr panes inherit nothing. Never pass `focus: true` to a herdr pane or tab for a run: it was confirmed live to pull the whole workspace into the operator's view.

Accepted trade-off: a real interactive TUI produces human-rendered output, not structured JSON, so there is **no cost/usage/token accounting for a session**. That was only ever recoverable from `--print --output-format stream-json`, which is exactly the mode this design abandons. Missing cost data is not a bug.

### Worktrees are the durable artifact

Every run gets a sibling worktree of the workspace's `main` checkout (`Orchestrator::GitWorktree`, with the git in `Orchestrator::Runner::Worktrees`) on a `workflow/<name>` branch. Two things reclaim them, and nothing else should: `Orchestrator::WorktreeJanitor` — straight away on **Close session** (`release!`), when `RunSessionReconcileJob` finds a run's herdr workspace was closed by hand (the same `release!`), and on its ten-minute sweep — and the run screen's **Remove worktree** button. There is no age-based retention: the janitor never touches `main` and removes a worktree only once its session is over and it is clean with HEAD already on `main` or a remote branch (removal keeps the branch). Anything else is kept indefinitely and flagged as a kept worktree (`Run#kept_worktree?`) on the runs list and run screen — uncommitted or unpushed work is exactly what an operator wants back. `--force` is reserved for the explicit per-run button.

### Full access, no separate review gate

A session runs with full access to its own worktree (`--permission-mode bypassPermissions`, `-s danger-full-access`, `--auto`). The per-step filesystem sandbox is gone with the planner that authorized it, and so are the protected-path patterns that outlived it as a line of prompt prose. There is no mandatory PR-review step either: when the operator asks, a session may merge its branch directly into `main` without waiting on a separate review.

## Testing Guidelines
The repository uses RSpec under `spec/`. Add service and job regression coverage for run/session state changes, and system coverage for UI behavior. Run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`.

Stub `Orchestrator::Runner::Herdr` in specs — never open a live socket, because herdr's mutating calls have real, visible effects in the operator's own session. Do not consume live model capacity to verify dispatch or arg building.

Specs cannot reach herdr by accident: `spec/spec_helper.rb` points `HERDR_SOCKET_PATH` at a socket that does not exist (a run session's shell otherwise has the operator's real one), so a call a spec forgot to stub fails with `Herdr::Unreachable`.

Use real git where git behavior is the thing under test (`spec/services/orchestrator/worktree_janitor_spec.rb` builds actual repos, worktrees, and a bare `origin`): the rules that matter — is this worktree dirty, is there anything to push — are only meaningful against real git. `spec/support/run_fixtures.rb` provides `create_workspace`/`create_run`/`create_run_and_session`.

### Verifying a change from its worktree, before it is merged

The production instance only runs `main`, so it cannot tell you whether a worktree's change works. Verify it where it was made, at the level of fidelity it needs, with one command:

```bash
bin/verify               # rspec, rubocop, git diff --check, bin/preflight, bin/sandbox verify (~1 min)
bin/verify --prod-copy   # same, with bin/preflight migrating a copy of the production database
```

The layers, and what belongs in each:

- **Boundary** (`spec/boundary_spec.rb`): nothing outside `Orchestrator::Runner` reaches the runner's machine directly.
- **Unit/service/job/request specs** (`spec/services`, `spec/jobs`, `spec/requests`; the runner's own under `spec/services/orchestrator/runner/`): one behaviour each, `Orchestrator::Runner::Herdr` stubbed call by call.
- **Fake herdr** (`lib/fake_herdr/`): `FakeHerdr::Server` speaks herdr's newline-delimited JSON-RPC on a Unix socket, with the response shapes `Orchestrator::Runner::Herdr` documents, and `agent.start` spawns a real process (`script/fake_agent`, `FakeHerdr::Agent`) in its own process group, so session pids, `Runner::Local#terminate`, and "the CLI exited" are real. The agent never runs a model: it reports through `/mcp/run` with the capability it was launched with, as a `[fake-agent: done|blocked|failed|dirty|crash|manual]` directive in the task says (default `done`). Tag an example `:fake_herdr` (`spec/support/fake_herdr.rb`) to get one; `spec/lib/fake_herdr/server_spec.rb` pins it to the real client's expectations -- extend both together when `Orchestrator::Runner::Herdr` learns a new call.
- **Lifecycle** (`spec/integration/run_lifecycle_spec.rb`): a run end to end in process -- `queue_run` over `/mcp/admin`, dispatch, a real worktree, `RunSessionRunner.start!` against the fake herdr, `report_idle` over `/mcp/run`, the message box, reconcile, Close session, the janitor -- plus crash, closed-by-hand and failed-launch paths. Changes to run/session state belong here as well as in a unit spec.
- **System specs** (`spec/system`): UI behaviour.
- **Boot smoke, `bin/preflight [--prod-copy]`**: boots this checkout as production would, on a scratch database and a free port, and fails on what otherwise only breaks after `bin/service restart`: eager loading, routes, `config/queue.yml` and the `production:` schedule in `config/recurring.yml` (including a schedule that silently lost `RunDispatchJob`/`RunSessionReconcileJob`), credentials (only where `config/master.key` exists, i.e. in `main`), migrations, and Puma plus Solid Queue actually starting and serving `/`, `/up` and `/mcp/admin`. `--prod-copy` first takes a read-only sqlite backup of the main checkout's `storage/production.sqlite3` into `tmp/preflight/` and migrates that; the copy boots with a fresh queue and no recurring jobs.
- **Isolated instance, `bin/sandbox`**: this checkout's `bin/production` (real Puma, real Solid Queue, real recurring schedule) on a free loopback port, with its own sqlite files, pid and log under `tmp/sandbox/`, beside a fake herdr. `bin/sandbox start` prints its URL (UI, `/mcp/admin`) and seeds a scratch repo as its only workspace; queue runs into it from the UI or `/mcp/admin` and drive them with fake-agent directives; `bin/sandbox stop`/`reset`. `bin/sandbox verify` boots a fresh one under `tmp/sandbox-verify/` and drives a run lifecycle through it from outside -- `/mcp/admin`, the fake agent reporting over real HTTP, the run screen's own forms, and the recurring reconcile noticing a crash.
- **The real thing, opt-in: `bin/sandbox start --real-herdr --telegram`** (either flag alone works). `--real-herdr` opens the sandbox's runs in the operator's own herdr, labelled `[sandbox] ...`, running the real CLI (real model usage) on throwaway tasks in the scratch repo, with their MCP reports going to the sandbox. `--telegram` makes the sandbox poll and answer Telegram for real as a **second bot** (`SANDBOX_TELEGRAM_BOT_TOKEN`/`SANDBOX_TELEGRAM_ALLOWED_USER_IDS`, from the environment or `~/.config/workflow-orchestrator/sandbox.env`; `bin/sandbox` prints which bot it is). Never give it production's bot: `getUpdates` hands each message to one poller, so two instances sharing a bot split the operator's messages. These are for the operator to try a change by hand; a run session should not start a real-herdr sandbox without being asked, since it spends model capacity and puts workspaces on the operator's screen. `bin/preflight` never enables either.

A sandbox or preflight instance runs with `WORKFLOW_SANDBOX=1`, and `Orchestrator::Sandbox` then refuses everything that reaches outside it, whatever its database holds: only its own fake herdr socket (never an inherited `HERDR_SOCKET_PATH`), no Telegram bot token (a second poller would take the operator's messages), no GitHub token for sessions, no workspace, worktree provisioning or removal outside its root, and no signal to a pid that is not a fake agent (with `--real-herdr`: that its own sessions did not record). The two opt-ins above lift exactly the herdr and Telegram guards and nothing else. `WORKFLOW_STORAGE_DIR` moves the production database files (`config/database.yml`). None of it touches `storage/production*.sqlite3` (other than `--prod-copy`'s read), `tmp/pids/production.pid`, or the production port. If you add a new way for the app to reach outside itself, it belongs in the runner (see "Orchestrator and runner"); add its sandbox guard to `Orchestrator::Sandbox` and `spec/services/orchestrator/sandbox_spec.rb`.

A run session working on this repo should run `bin/verify` before reporting `done`, say in its report which layers it ran and whether they passed, and say whether the change needs `bin/service restart` once merged (anything in `config/queue.yml`, `config/recurring.yml`, credentials, `bin/production`/`bin/service`, or an initializer).

## Commit & Pull Request Guidelines
Recent commit history favors short, imperative summaries such as `Flatten ops/ into the repo root` and `Port the TS orchestrator engine to Ruby`. Keep commits focused and descriptive. A run session commits only when the operator asks (see Sessions, Not Orchestration). If the operator opens a PR, it should include a concise problem statement, the implementation approach, any schema or job-queue impact, and manual verification steps. Link related issues when available and include screenshots only for UI changes.

## Security & Configuration Tips
Do not commit decrypted credentials, database dumps, or logs containing run data. Review changes to `config/credentials.yml.enc`, queue configuration, and any MCP tool implementation carefully, because they affect what a session can reach and how a run reports its result.

## MCP Boundary

A run session reaches Rails through `/mcp/run`, authenticated by that session's own bearer capability (`RunSession#capability_token_digest`) and dead the moment the session ends. A second, standing endpoint, `/mcp/admin`, carries no auth at all — consistent with this app's "no auth in v1" trust boundary everywhere else (Puma binds `127.0.0.1` only) — and exists for the operator's own external MCP clients, principally their everyday Claude Code session, to queue and inspect runs without opening the web UI.

Both draw from the same small tool set (`Orchestrator::RunMcpServer::TOOLS` / `Orchestrator::AdminMcpServer::TOOLS`): `queue_run`, `list_runs`, `get_run`, and `list_workspaces` are shared by both endpoints, because queuing a run or asking what's running is the same operation regardless of who's asking (`McpTools::WorkspaceResolution` is what lets the same tool code serve a caller with no run of its own — an explicit `workspace:` argument, else the calling run's own workspace, else the oldest registered one; `list_workspaces` is how a caller finds the name to pass). `report_idle` and `record_workspace_env_var` remain run-session-only, since only a live session has a result to report or a process that needs an env var. There is no MCP artifact store: files the operator attaches at launch are stored under the workspace's main checkout and handed to the session as a path in its prompt.

Keep the surface at that. Anything a real interactive CLI can already do for itself — read files, run commands, edit code, start a dev server — is its own business now that it has full access to its worktree; it does not need a tool from us. Never expose arbitrary SQL, Active Record lookup, filesystem traversal, or command execution through either endpoint.

There used to be a "workspace admin chat" -- its own one-shot agent turns run from a workspace root, fronted by the web UI and Telegram -- with admin-chat-scoped MCP tools (`read_session_pane`, `send_to_session`, `read_run_prompt`) that were never mounted. It was removed deliberately: it predated the one-session-per-run model and could never actually steer a session. Telegram now acts on sessions directly (see "Operating Context"). Do not bring back an agent layer in front of sessions; the session is the intelligence.

There used to also be a durable, evidence-backed "project memory" store (`get_project_memory`/`record_project_memory_entry`/`record_project_setup`, `WorkspaceMemoryEntry`) prepended to every run's prompt. It was removed deliberately — if old commits or docs still reference it, that is not an oversight; recreate it only if it turns out to actually be missed.
