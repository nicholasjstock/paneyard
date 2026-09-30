# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project has no tagged releases yet.

## [Unreleased]

The first public version. It includes:

### Runs and sessions

- Workspaces: register a repository's parent directory, whose `main` checkout every run branches from. Runs, sessions, reports and worktrees are scoped to their workspace.
- A global run queue with a concurrency cap (`PANEYARD_MAX_CONCURRENT_RUNS`, default 4), dispatched oldest first.
- One git worktree per run, on a `paneyard/<name>` branch created from the current local `main`.
- One live, interactive agent session per run, in a herdr pane rooted in its worktree, with `claude` (Claude Code), `codex` or `opencode` as the driver and a per-driver default model (`PANEYARD_*_MODEL`) or a model picked per run.
- Sessions leave changes uncommitted; commit, push and merge into `main` each happen only when the operator asks for that step.
- Reports: a session calls `report_idle` (`done`, `blocked`, `failed`) with a Markdown summary each time it stops, and reports accumulate as checkpoints on the run screen.
- A message box on the run screen that types into the live session, and **Close session** to end it and free its slot.
- Attachments added at launch are handed to the session as file paths.
- Reconciliation that notices within about 30 seconds when a session dies without reporting, and keeps the agent pane's last screen when a launch fails.

### Worktree cleanup

- A worktree janitor that removes a run's worktree (keeping its branch) once its session is over and its work is clean and merged or pushed, on Close session and on a ten-minute sweep.
- Worktrees with unsaved work are kept and flagged, with a **Remove worktree** button.

### Configuration

- Per-workspace herdr layouts (tabs and split panes with commands), edited visually, defaulting to the agent beside `nvim`.
- Per-workspace environment variables that sessions can record for later runs (`record_workspace_env_var`).
- Optional GitHub App authentication for session pushes, falling back to the operator's `gh` login.

### Integrations

- `/mcp/run`, a per-session authenticated MCP endpoint wired into every session.
- `/mcp/admin`, an unauthenticated loopback MCP endpoint for the operator's own MCP clients: `queue_run`, `list_runs`, `get_run`, `list_workspaces`.
- Telegram remote control: list sessions, read panes and reports, and type into sessions from an allow-listed private chat, behind a platform-neutral adapter interface.

### Security

- Loopback-only by default: Puma binds `127.0.0.1`, and production answers only loopback `Host` names (DNS-rebinding protection, `PANEYARD_ALLOWED_HOSTS` to extend). See `SECURITY.md`.

### Operations and development

- `bin/dev` for development and `bin/service` for a daemonized long-running instance, whose `restart` refuses to replace a working instance with code that fails a production boot check (`bin/preflight`).
- `bin/sandbox`: an isolated instance with a fake herdr and fake agent that spends no model usage, with opt-in real herdr and Telegram.
- `bin/verify`: specs, RuboCop, boot smoke test, an end-to-end sandbox run, and security audits in one command.
- Released under the MIT License.
