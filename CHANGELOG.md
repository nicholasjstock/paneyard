# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project has no tagged releases yet.

## [Unreleased]

The first public version. It includes:

### herdr plugin

- `herdr plugin install nicholasjstock/paneyard` installs Paneyard as a herdr plugin: its build installs gems into the managed checkout, and a daemon it owns runs `bin/production` with the databases, logs, a generated `secret_key_base` and a port chosen once and kept in herdr's plugin state directory. No `bin/setup`, `bin/service` or credentials to manage.
- Actions and popups for queueing a task for the repository the focused pane is in (registering it as a workspace when needed), listing runs, reading a run's report, jumping to its herdr workspace, closing its session, opening the web UI, and registering `/mcp/admin` with Claude Code.
- Settings from `$(herdr plugin config-dir paneyard)/.env`, written as a commented sample on first start.
- The queue popup defaults to the agent running in the focused pane, and the model it is on now (read from the CLI's session log, so `/model` switches count), and offers the driver's models to pick another (`list_models` on `/mcp/admin`; `queue_run` takes `model`).
- `close_session` on `/mcp/admin`, `PANEYARD_RUNTIME_DIR`, and each run's herdr workspace id in `list_runs`/`get_run`.

### Repositories, base branches and herdr worktrees

- A workspace is any existing git checkout plus a default base branch (`repository_path`, `default_base_branch`), registered directly (`register_workspace` takes `path`, and optionally `name` and `defaultBaseBranch`). No `<root>/main` layout, no need to have the default branch checked out; the default is detected from the repository (origin's HEAD, `init.defaultBranch`, `main`/`master`).
- Each run records its own `base_branch` (`queue_run`'s `baseBranch`, the new-run form's **Base branch**; default the workspace's), validated when queued. Runs of one workspace can start from different branches at once, and each merges back into its own.
- herdr creates and removes run worktrees (`worktree.create` / `worktree.remove`), wherever its config puts them, and the worktree's herdr workspace is the run's session workspace.
- Cleanup judges a worktree against its run's base branch, and only ever touches Paneyard's own runs' worktrees, never other worktrees of the repository or the checkout itself.
- Existing `<root>/main` workspaces migrate to `repository_path = <root>/main`, `default_base_branch = main`; existing runs to `base_branch = main`.
- Launch attachments are stored beside a run's runtime files instead of in the repository.

### Removed

- Session environment: no pane gets env from Paneyard. claude's MCP capability is in its config file, codex's in a `-c` header override. With it went workspace environment variables (`record_workspace_env_var`), GitHub App token minting (`GITHUB_APP_*`), and the opencode driver, whose MCP config could only travel through env.

### Runs and sessions

- Workspaces: register a repository's parent directory, whose `main` checkout every run branches from. Runs, sessions, reports and worktrees are scoped to their workspace.
- A global run queue with a concurrency cap (`PANEYARD_MAX_CONCURRENT_RUNS`, default 4), dispatched oldest first.
- One git worktree per run, on a `paneyard/<name>` branch created from the current local `main`.
- One live, interactive agent session per run, in a herdr pane rooted in its worktree, with `claude` (Claude Code) or `codex` as the driver and a per-driver default model (`PANEYARD_*_MODEL`) or a model picked per run.
- Sessions leave changes uncommitted; commit, push and merge into `main` each happen only when the operator asks for that step.
- Reports: a session calls `report_idle` (`done`, `blocked`, `failed`) with a Markdown summary each time it stops, and reports accumulate as checkpoints on the run screen.
- A message box on the run screen that types into the live session, and **Close session** to end it and free its slot.
- Attachments added at launch are handed to the session as file paths.
- Reconciliation that notices within about 30 seconds when a session dies without reporting, and keeps the agent pane's last screen when a launch fails.

### Worktree cleanup

- A worktree janitor that removes a run's worktree (keeping its branch) once its session is over and its work is clean and merged or pushed, on Close session and on a ten-minute sweep.
- Worktrees with unsaved work are kept and flagged, with a **Remove worktree** button.

### Configuration

- Per-workspace herdr layouts (tabs and split panes with commands), edited visually, defaulting to the agent alone.

### Integrations

- `/mcp/run`, a per-session authenticated MCP endpoint wired into every session.
- `/mcp/admin`, an unauthenticated loopback MCP endpoint for the operator's own MCP clients: `queue_run`, `list_runs`, `get_run`, `list_workspaces`, `register_workspace`.
- `register_workspace` on `/mcp/admin`: registers a workspace from your own agent, given the repository's path (or a directory or linked worktree in it). It checks everything first, creates nothing if anything is wrong, and returns every problem with how to fix it. The web UI's Add workspace form runs the same checks.
- `queue_run` over `/mcp/admin` now requires `workspace` instead of falling back to the oldest workspace, and `/mcp/admin` has server instructions for the flow: find the workspace for this repository, register it if missing, then queue. From inside a run it still defaults to the run's own workspace.
- Telegram remote control: list sessions, read panes and reports, and type into sessions from an allow-listed private chat, behind a platform-neutral adapter interface. Configured with `TELEGRAM_BOT_TOKEN`/`TELEGRAM_ALLOWED_USER_IDS` in the plugin's `.env` (or `bin/service`'s environment); Rails credentials are no longer read.

### Security

- Loopback-only by default: Puma binds `127.0.0.1`, and production answers only loopback `Host` names (DNS-rebinding protection, `PANEYARD_ALLOWED_HOSTS` to extend). See `SECURITY.md`.

### Operations and development

- `bin/dev` for development and `bin/service` for a daemonized long-running instance, whose `restart` refuses to replace a working instance with code that fails a production boot check (`bin/preflight`).
- `bin/sandbox`: an isolated instance with a fake herdr and fake agent that spends no model usage, with opt-in real herdr and Telegram.
- `bin/verify`: specs, RuboCop, boot smoke test, an end-to-end sandbox run, and security audits in one command.
- Released under the MIT License.
