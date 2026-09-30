# Paneyard

Paneyard is a local, single-operator queue and supervisor for interactive AI coding-agent sessions ([Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex](https://github.com/openai/codex) and [opencode](https://opencode.ai)). You queue a task against one of your repositories; when a slot frees, the task gets its own git worktree and one live agent session in a [herdr](https://herdr.dev) pane, which you can watch and type into. The session does the work and leaves it uncommitted. Nothing is committed, pushed or merged until you ask for that particular step.

![Claude Code queues two jobs over Paneyard's MCP endpoint; each opens in its own herdr workspace, its diff grows in Hunk, and each is told to merge to main and closed](docs/images/demo.gif)

*A scripted rehearsal of the flow (the agents are a stand-in that uses no model): recorded in Docker with `demo/bin/record`, see [docs/demo-recording-plan.md](./docs/demo-recording-plan.md).*

It is a Rails 8 app that runs on your own machine. Rails decides *which* task runs, *where*, and what happens to the worktree afterwards; the agent session decides everything else. There is no planner, no step queue and no pull-request automation.

> [!WARNING]
> **Read the [security model](#security-model) before you run this.** It has no authentication, and it hands AI agents unrestricted access to the repositories you register and to your user account.

## Contents

- [Security model](#security-model)
- [Requirements](#requirements)
- [Getting started](#getting-started)
  1. [Install](#1-install)
  2. [Run it day to day](#2-run-it-day-to-day)
  3. [Register a workspace](#3-register-a-workspace)
  4. [Queue a run](#4-queue-a-run)
  5. [Queue runs from your own agent](#5-queue-runs-from-your-own-agent)
- [How a run works](#how-a-run-works)
- [Workspace layouts](#workspace-layouts)
- [Configuration](#configuration)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Security model

This is a tool for one trusted person on their own machine. Treat anything that can reach it as having a shell on that machine. [SECURITY.md](./SECURITY.md) has the full threat model and how to report a vulnerability.

- **No authentication.** Every web page, every form, and the `/mcp/admin` MCP endpoint are open to whoever can connect. There are no user accounts; the operator is whoever is at the keyboard.
- **Loopback only.** `bin/service` / `bin/production` bind to `127.0.0.1` and `bin/dev` to `localhost`, so nothing else on your network can connect. In production the app also answers only loopback `Host` names (`localhost`, `127.0.0.1`, `[::1]`), which stops DNS-rebinding attacks from web pages you visit. `BINDING` and `PANEYARD_ALLOWED_HOSTS` widen this; if you set either, whatever sits in front of the app must provide the authentication it lacks.
- **Agents run with approvals bypassed.** Each session is launched with full access and no confirmation prompts: `claude --permission-mode bypassPermissions`, `codex -s danger-full-access`, `opencode --auto`. It works in its own worktree but is not sandboxed: it can read and write anything your user account can, run any command, and use your network. The only review gate is you, reading its report and trying its changes before asking it to commit.
- **Registered repositories are fully exposed to their sessions**, including any secrets you keep in them, and a session's environment includes a GitHub token when one is available (below).
- **It can edit itself.** If you register this repository as one of its own workspaces, a session can change the orchestrator's code, and the running instance hot-reloads application code (`PANEYARD_HOT_RELOAD`). Nothing stops a session from merging into `main` when asked to.
- **Telegram remote control** (optional, off unless configured) lets the Telegram user IDs on an allow-list list sessions, read their panes and reports, and type into them from a private chat. That is equivalent to shell access. Pane text and reports also pass through Telegram's servers, and bot chats are not end-to-end encrypted.
- **GitHub credentials.** Rails itself makes no GitHub calls except, if you configure a [GitHub App](./GITHUB_APP_SETUP.md), minting an installation token. The session receives that token (or, without an App, the output of your own `gh auth token`) as `GH_TOKEN`, and can do anything that token allows on the repositories it covers. Scope the App to the repositories you register.
- **Plaintext state.** Runs, reports and recorded workspace environment variables are stored unencrypted in SQLite under `storage/`.

## Requirements

- **macOS.** This is where it is developed and tested. Linux is untested; nothing in the code is knowingly macOS-only, but expect rough edges. Windows is not supported.
- **Ruby** at the version in [`.ruby-version`](./.ruby-version) (currently 4.0.1), with Bundler, and **SQLite 3**.
- **git**, with each target repository checked out as described in [Preparing a repository](./docs/operating.md#preparing-a-repository).
- **[herdr](https://herdr.dev), running.** Required. herdr owns every terminal pane and agent process; Rails talks to its socket at `~/.config/herdr/herdr.sock` (override with `HERDR_SOCKET_PATH`). Without it a run fails at launch.
- **At least one agent CLI, already signed in:** `claude`, `codex` and/or `opencode`, on the `PATH` of your login shell (the shell a herdr pane opens). Sessions start non-interactively and cannot complete a login flow. Unless you choose otherwise, a session uses a sensible default for its driver (`Orchestrator::DefaultModels`; for some drivers that means the CLI's own configured model). Override it per driver with `PANEYARD_CLAUDE_MODEL`, `PANEYARD_CODEX_MODEL` or `PANEYARD_OPENCODE_MODEL`, or pick a model per run in the UI.
- **Optional:** `nvim` (the default pane layout opens it beside the agent), `gh` signed in (for pushing over HTTPS without a GitHub App), `curl` (only for a GitHub App).

## Getting started

### 1. Install

```sh
git clone <this repository's URL> paneyard
cd paneyard
bin/setup
```

`bin/setup` installs gems. It does not start anything, and you don't need to set up a database: `bin/service` does that when it starts (next step).

### 2. Run it day to day

Paneyard is meant to stay up all day. `bin/service` runs it in production mode, detached from your terminal, on port 7263 by default, logging to `log/production_service.log`. Its database is `storage/production.sqlite3`, created on first start and migrated on every start, so a restart after pulling an update applies any new migrations.

```sh
bin/rails credentials:edit   # once: see the note below
bin/service start            # also: stop | restart | status
```

Then open <http://127.0.0.1:7263>. `start` waits for the app to answer and fails after two minutes, naming the log. After changing credentials or other boot-time configuration, run `bin/service restart`; [Long-running: `bin/service`](./docs/operating.md#long-running-binservice) has the details.

> [!NOTE]
> Production mode needs a `secret_key_base`, which lives in Rails' encrypted credentials. A fresh clone has no `config/master.key`, so the committed `config/credentials.yml.enc` cannot be decrypted by you. Move it aside (`mv config/credentials.yml.enc config/credentials.yml.enc.orig`), then run `bin/rails credentials:edit`, which creates a new key and credentials file containing a `secret_key_base`. That file is also where optional Telegram and GitHub App settings go. Alternatively, export `SECRET_KEY_BASE` (for example from `bin/rails secret`) before `bin/service start`.

There is also `bin/dev`, which runs the app in the foreground in development mode, and `bin/sandbox`, an isolated instance with a fake herdr and fake agent. Both are for working on Paneyard itself; see [CONTRIBUTING.md](./CONTRIBUTING.md#running-it-in-development).

### 3. Register a workspace

A **workspace** is a directory that holds a repository's `main` checkout; run worktrees are created beside it:

```sh
mkdir -p ~/code/my-app
git clone git@github.com:you/my-app.git ~/code/my-app/main   # must be on branch main, with an origin remote
```

Open Paneyard's URL, choose **Add workspace**, and enter a name and the **workspace root** (`~/code/my-app`; giving `.../main` also works). Registration checks that layout and lists anything to fix before it saves. You can also register it from your own agent with the `register_workspace` tool over `/mcp/admin` ([step 5](#5-queue-runs-from-your-own-agent)). [Preparing a repository](./docs/operating.md#preparing-a-repository) has every rule the launch checks, and how to tell a session to set up and test your repository.

### 4. Queue a run

On the workspace's runs page, choose **Queue a task**, describe the task, pick a driver (`claude`, `codex` or `opencode`) and optionally a model, then **Queue**. Within a few seconds a herdr workspace named after the run's worktree opens with the agent in it. When the agent stops, it posts a report to the run screen. Read it, send it more instructions from the message box if needed, ask it to commit, push or merge when you are happy, and choose **Close session** to free the slot.

### 5. Queue runs from your own agent

Optionally, Paneyard's `/mcp/admin` endpoint lets an MCP client, such as your everyday Claude Code session, queue and inspect runs without opening the web UI. Register it once, at user scope so it is available from every project:

```sh
claude mcp add --transport http -s user paneyard-admin http://127.0.0.1:7263/mcp/admin
```

Use the port your instance listens on (7263 for `bin/service`). Then ask your agent to queue a task in a workspace, list runs, or check on one. The endpoint is unauthenticated, like the rest of the app, so keep it on loopback. [MCP endpoints](./docs/operating.md#mcp-endpoints) lists its tools.

## How a run works

1. **Queue.** A run waits for a slot. The cap is global across all workspaces: `PANEYARD_MAX_CONCURRENT_RUNS`, default 4.
2. **Dispatch.** When a slot frees, the oldest queued run gets a git worktree on a `paneyard/<name>` branch (from the current local `HEAD` of `main`) and one interactive agent session in a herdr pane rooted there, with the task as its first prompt.
3. **Work.** The session explores, edits and runs the repository's own commands, then leaves its changes uncommitted. Commit, push and merge are separate requests; it does only the one you ask for.
4. **Report.** Each time it stops, the session calls the `report_idle` MCP tool (`done`, `blocked` or `failed`) with a Markdown report. The session stays open and keeps its slot; reports accumulate as checkpoints on the run screen.
5. **Close.** **Close session** quits the agent, closes its herdr workspace and frees the slot. A run you haven't closed keeps holding its slot.
6. **Clean up.** The worktree is removed automatically once its work is saved (clean, and merged into `main` or pushed). Otherwise it is kept and flagged until you push, merge, or choose **Remove worktree**.

If a session dies without reporting, the orchestrator notices within about 30 seconds and frees the slot. Pull requests are yours to open from a pushed branch; the orchestrator never opens, watches or merges them.

## Workspace layouts

Each run opens in its own herdr workspace. A workspace's **layout** decides which tabs and panes that herdr workspace has: the agent, plus anything you want running beside it, such as an editor, a dev server or a log tail. By default a run gets the agent with `nvim .` split to its right, or just the agent when `nvim` isn't installed.

To change it, edit the workspace (or set it when you add one) and use its **Layout** editor. Name each tab, add panes, give each a command, and choose which earlier pane it splits off, to the right or below, and how much space that pane keeps. A live sketch shows the result, and **Reset to default** goes back to the default. The layout is saved as YAML:

```yaml
tabs:
  - name: main
    panes:
      - agent                       # required: the first pane of the first tab
      - name: editor
        command: nvim .
        split: { of: agent, direction: right, ratio: 0.5 }
  - name: logs
    panes:
      - name: dev-log
        command: tail -f log/development.log
```

Every pane opens in the run's worktree with the same environment as the agent. A pane with no command is a plain shell. Panes are set up once, when the session starts: Paneyard never watches or restarts them, and **Close session** closes them all. [Workspace layouts](./docs/operating.md#workspace-layouts) in operating.md has the full rules.

## Configuration

Everything is optional except herdr and an agent CLI.

| Setting | Default | Purpose |
| --- | --- | --- |
| `PORT` | random (`bin/dev`), `7263` (`bin/service`) | HTTP port. |
| `BINDING` | `localhost` (dev), `127.0.0.1` (`bin/service`) | Interface Rails listens on. Widening it exposes an unauthenticated app; see [SECURITY.md](./SECURITY.md). |
| `PANEYARD_ALLOWED_HOSTS` | unset | Extra `Host` names production answers to (comma-separated), for example behind a reverse proxy. |
| `PANEYARD_RAILS_URL` | `http://127.0.0.1:$PORT` | URL sessions use to reach the orchestrator's MCP endpoint. Keep it in step with `PORT`. |
| `PANEYARD_MAX_CONCURRENT_RUNS` | `4` | Global cap on live sessions. |
| `PANEYARD_CLAUDE_MODEL`, `PANEYARD_CODEX_MODEL`, `PANEYARD_OPENCODE_MODEL` | per driver | Default model per driver; a model picked per run wins. |
| `HERDR_SOCKET_PATH` | `~/.config/herdr/herdr.sock` | herdr's socket. |
| `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_INSTALLATION_ID` | unset | GitHub App for session push credentials; see [GITHUB_APP_SETUP.md](./GITHUB_APP_SETUP.md). Also settable in credentials. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USER_IDS` | unset | Telegram remote control; see [docs/telegram.md](./docs/telegram.md). Also settable in credentials. |

Pane layouts are set per workspace ([above](#workspace-layouts)). So are environment variables, which sessions record for later runs; see [What a run starts with](./docs/operating.md#3-what-a-run-starts-with-inside-the-repo).

## Documentation

- [docs/operating.md](./docs/operating.md) — running the orchestrator day to day: preparing repositories, git and cleanup rules, GitHub access, workspace layouts and env vars, MCP endpoints, troubleshooting a failed launch.
- [docs/telegram.md](./docs/telegram.md) — Telegram remote control, and adding another chat platform.
- [GITHUB_APP_SETUP.md](./GITHUB_APP_SETUP.md) — optional GitHub App for session push credentials.
- [docs/README.md](./docs/README.md) — index of the design records behind the current architecture.
- [AGENTS.md](./AGENTS.md) — the architecture and conventions guide for anyone (human or agent) changing this codebase.
- [CHANGELOG.md](./CHANGELOG.md) — what has changed.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for setting up to develop Paneyard, running it with `bin/dev` or in the sandbox, the tests and CI, the code layout, and the design rules a change has to follow; [AGENTS.md](./AGENTS.md) is the detailed architecture guide behind it. In short: `bin/setup`, make your change, and run `bin/verify` (specs, RuboCop, a production boot smoke test, an end-to-end run through the sandbox, and security audits) before opening a pull request.

## License

Released under the [MIT License](./LICENSE). Copyright (c) 2026 Nicholas Stock.
