# Paneyard

## Keep coding while your agents take the next tasks

Paneyard is a local job queue for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://github.com/openai/codex) in [herdr](https://herdr.dev). Hand off a well-defined task from the repository you are already in. Paneyard gives it a separate branch, worktree and live agent session, then brings back a report when the work is ready for you.

Brief each task once, where its boundaries are clearest. Paneyard handles the waiting, isolation and session lifecycle—not the judgment about what the agent should do. You can watch every session, talk to it directly and decide exactly when its changes are committed, pushed or merged.

_Free and MIT licensed · Runs on your machine · macOS and Linux · Herdr 0.7.0+_

![Claude Code queues two jobs over Paneyard's MCP endpoint; each opens in its own herdr workspace, its diff grows in Hunk, and each is told to merge to main and closed](docs/images/demo.gif)

*A live take with real Claude Code (Sonnet), sped up where the agents work: recorded in Docker with `demo/bin/record`, see [docs/demo-recording-plan.md](./docs/demo-recording-plan.md).*

## Hand off the task. Keep control of the work.

- **Stay in your flow.** Queue work from one Herdr menu or ask the Claude or Codex session you are already using to hand it off.
- **Run several jobs safely side by side.** Every job gets its own branch, worktree and Herdr workspace; your checkout is never switched or reset.
- **Keep the conversation alive.** These are interactive sessions, not one-shot workers. Open one, inspect its work and change direction in the same conversation.
- **Review before anything moves.** Agents report and leave changes uncommitted. Commit, push and merge happen only when you ask for that specific action.
- **Recover without losing the work.** Close a session to free its slot, then reopen it on the same branch later. Dirty or unpushed worktrees are kept.

## One task, one accountable session

Choose a task worth handing off and give its session the context it needs. Paneyard takes care of where and when it runs, keeps the work isolated, and makes the result easy to pick up.

Your brief goes straight to the agent doing the work. When the task needs judgment, you continue that same conversation—with the agent, repository and working tree still in place.

|  | Paneyard | Opening agents by hand | Headless agent queue |
| --- | --- | --- | --- |
| Parallel work on isolated branches | Yes | Yes | Yes |
| Queue and concurrency limit | Yes | No | Yes |
| Live session you can watch and steer | Yes | Yes | No |
| Agent receives your brief directly | Yes | Yes | Yes |
| Changes wait for your commit, push or merge request | Yes | Up to you | Varies |
| Runs locally in the CLI you already use | Yes | Yes | Varies |

## A small deterministic core

One of the hardest parts of figuring out what an agent factory should be is deciding which parts are deterministic and belong in code, and which are agentic and belong to the agent.

Paneyard draws the line like this:

| Code owns | The agent owns |
| --- | --- |
| Queue order, admission and slot ownership | How to do the task |
| Worktree and herdr workspace lifecycle | What to read, change and test |
| Job and session state | When it is done, blocked or failed, and what to report |
| The rules for safe worktree cleanup | How to carry out a commit, push or merge when you ask |

If something must be true for Paneyard to stay correct, code owns it. If it requires judgment about the work, the agent owns it. Paneyard keeps the first category as small, explicit state in SQLite and deterministic code; none of those invariants depend on a model remembering or correctly interpreting an instruction.

An earlier version drew the line elsewhere. An LLM planner split tasks into steps, handed them to one-shot workers and tried to recover when they failed. Making that reliable kept adding machinery around the planner: step queues, a chaperone, acceptance criteria, recovery paths and capacity failover. Replacing that loop with one live interactive session per run removed most of that machinery; the rewrite cut the app from about 12.7k lines to 4.6k and the MCP surface from 30 tools to 9.

The Claude or Codex session you already work in can also queue jobs through Paneyard's MCP endpoint. Paneyard stays focused on running those jobs reliably and keeping each session available to you.

It installs as a herdr plugin and is used from one menu inside herdr: hand off a task from the repository you are in, read a job's report, close it, or change its layout. Underneath it is a Rails 8 app running on your own machine, which the plugin starts and looks after for you. Rails decides *which* task runs, *where*, and what happens to the worktree afterwards; the agent session decides everything else. There is no planner, no step queue and no pull-request automation.

> [!WARNING]
> **Read the [security model](#security-model) before you run this.** It has no authentication, and it hands AI agents unrestricted access to the repositories you register and to your user account.

Ready to try it? The complete walkthrough is below; the install starts with:

```sh
herdr plugin install nicholasjstock/paneyard
herdr plugin action invoke setup --plugin paneyard
```

## Contents

- [Hand off the task. Keep control of the work.](#hand-off-the-task-keep-control-of-the-work)
- [One task, one accountable session](#one-task-one-accountable-session)
- [A small deterministic core](#a-small-deterministic-core)
- [Security model](#security-model)
- [Requirements](#requirements)
- [Getting started](#getting-started)
  1. [Install the plugin](#1-install-the-plugin)
  2. [Connect your coding agents](#2-connect-your-coding-agents)
  3. [Bind one menu key](#3-bind-one-menu-key)
  4. [Queue a task](#4-queue-a-task)
  5. [Read reports, close and reopen jobs](#5-read-reports-close-and-reopen-jobs)
  6. [Queue jobs from your own agent](#6-queue-jobs-from-your-own-agent)
  - [Settings, updates and removal](#settings-updates-and-removal)
  - [Running without the plugin](#running-without-the-plugin)
- [How a job works](#how-a-job-works)
- [Workspace layouts](#workspace-layouts)
- [Configuration](#configuration)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Security model

This is a tool for one trusted person on their own machine. Treat anything that can reach it as having a shell on that machine. [SECURITY.md](./SECURITY.md) has the full threat model and how to report a vulnerability.

- **No authentication.** The `/mcp/admin` MCP endpoint is open to whoever can connect. There are no user accounts; the operator is whoever is at the keyboard.
- **Loopback only.** The plugin, `bin/service` and `bin/production` bind to `127.0.0.1` and `bin/dev` to `localhost`, so nothing else on your network can connect. In production the app also answers only loopback `Host` names (`localhost`, `127.0.0.1`, `[::1]`), which stops DNS-rebinding attacks from web pages you visit. `BINDING` and `PANEYARD_ALLOWED_HOSTS` widen this; if you set either, whatever sits in front of the app must provide the authentication it lacks.
- **Agents run with approvals bypassed.** Each session is launched with full access and no confirmation prompts: `claude --permission-mode bypassPermissions`, `codex -s danger-full-access`. It works in its own worktree but is not sandboxed: it can read and write anything your user account can, run any command, and use your network. The only review gate is you, reading its report and trying its changes before asking it to commit.
- **Registered repositories are fully exposed to their sessions**, including any secrets you keep in them. A session's panes are your own login shell, with whatever credentials it has (your SSH agent, your `gh` login).
- **It can edit itself.** If you register this repository as one of its own workspaces, a session can change the orchestrator's code, and the change reaches the running instance when it is next restarted. Nothing stops a session from merging into its base branch when asked to.
- **GitHub credentials.** Paneyard makes no GitHub calls and hands sessions no tokens. A session pushes, when asked to, with whatever your login shell can push with (your SSH key, your `gh` login), so it can do anything you can on those repositories.
- **Plaintext state.** Jobs and reports are stored unencrypted in SQLite: in the plugin's state directory (`~/.local/state/herdr/plugins/paneyard/storage`), or under `storage/` for `bin/service`.
- **The plugin is code herdr runs as you.** herdr does not sandbox plugins. Its startup hook starts Paneyard whenever herdr starts; review `herdr-plugin.toml` and `bin/herdr-plugin` before installing, as herdr's install preview suggests.

## Requirements

- **[herdr](https://herdr.dev) 0.7.0 or newer, running.** herdr owns every terminal pane and agent process, and Paneyard installs into it as a plugin.
- **macOS or Linux**, on Intel or ARM64. Windows is not supported.
- **`curl`, `tar`, and a SHA-256 utility** (`shasum` on macOS, `sha256sum` on Linux). The plugin downloads a verified, platform-specific Ruby and production gem bundle; it does not need a system Ruby, Bundler, compiler, or development headers.
- **git**, with each repository you want to queue tasks for checked out as described in [Preparing a repository](./docs/operating.md#preparing-a-repository).
- **At least one agent CLI, already signed in:** `claude` and/or `codex`, on the `PATH` of your login shell (the shell a herdr pane opens). Sessions start non-interactively and cannot complete a login flow, or Claude Code's folder-trust prompt: open `claude` once in a new repository's `main` checkout and trust it. Unless you pick one when queueing, a session uses its driver's default model: `opus` for `claude`, and whatever `codex` is itself configured with (see [Configuration](#configuration)).
- **Optional:** `gh` signed in (for sessions pushing over HTTPS).

## Getting started

### 1. Install the plugin

```sh
herdr plugin install nicholasjstock/paneyard
```

herdr shows what the plugin will run, then downloads the matching bundled Ruby and production gems. No compiler is used on your machine. Paneyard starts on its own the next time herdr starts, or the first time you use any of its actions. Its database, logs and generated secrets live in the plugin's state directory (`~/.local/state/herdr/plugins/paneyard`), and it picks a free local port for itself and keeps it.

### 2. Connect your coding agents

The installer prints this as its final step:

```sh
herdr plugin action invoke setup --plugin paneyard
```

Run it once. The setup pane starts Paneyard, detects installed Claude Code and Codex CLIs, shows what it found, and asks for approval before changing either client's user-level MCP configuration. It configures each approved client independently, reports registrations that are already current, and leaves missing clients alone. You can safely run it again after an update or port change.

Herdr plugin builds do not have a reliable interactive-input contract, so this explicit action is the safe equivalent of an installer prompt. If you skip it, Paneyard still works through its Herdr actions; [manual MCP commands](#6-queue-jobs-from-your-own-agent) remain available.

### 3. Bind one menu key

Plugins can't bind keys themselves. Add one Paneyard menu key to Herdr's `config.toml` (choose any unused key), then run `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+comma"
type = "plugin_action"
command = "paneyard.menu"
description = "paneyard menu"
```

The menu offers: hand off a task, jobs and reports (where a closed job can be reopened), this job's report, close this job, the job layout, and letting your agents queue jobs. Individual actions remain available through Herdr's action menu or the CLI: `herdr plugin action list --plugin paneyard`, then `herdr plugin action invoke <id> --plugin paneyard`.

| Action | What it does |
| --- | --- |
| `paneyard.menu` | Open the single Paneyard menu recommended for key binding. |
| `paneyard.queue` | Hand off a task from the repository and branch of the current pane. |
| `paneyard.runs` | The 40 newest jobs, newest first, a follow-up marked with its parent (`22da ↳7efb`). Pick one to read its newest report, jump to its herdr workspace, close it, or reopen it once closed. |
| `paneyard.report` | Inside a job's herdr workspace: that job's newest report. |
| `paneyard.close` | Inside a job's herdr workspace: close it (asks first). |
| `paneyard.layout` | Visually build and validate the current repository's tabs and panes in a Herdr popup, including from one of its job worktrees. |
| `paneyard.setup` | Detect Claude Code and Codex, then offer to connect them to Paneyard. |
| `paneyard.mcp-url` | Show the `/mcp/admin` URL as a notification. |
| `paneyard.restart`, `paneyard.stop` | Apply a settings change; stop Paneyard (any action starts it again). Running sessions are not affected by either. |

### 4. Queue a task

Any git checkout you already have will do, with any branch checked out, as long as it has an `origin` remote. Open a herdr pane anywhere in it, open the **Paneyard menu**, and choose **Hand off a task**. Paneyard resolves the checkout to a workspace, registering it through the same repository checks as the admin MCP tool when needed. Describe the task (Enter submits, Shift-Enter adds a line, Ctrl-C cancels), choose the **base branch** to start from (Enter for the branch your pane is on, or the workspace's default on a detached HEAD; or type another), pick a driver and model (Enter keeps the agent running in your pane, and the model it is on now, `/model` switches included; with no agent there, `claude` on its default model; or pick another from the list), and it is queued. When a slot frees, herdr creates the job's worktree from that branch, wherever your herdr config puts worktrees, and opens it as a herdr workspace with the agent in it. Your own checkout is never touched. [Preparing a repository](./docs/operating.md#preparing-a-repository) has every rule the launch checks, and how to tell a session to set up and test your repository.

### 5. Read reports, close and reopen jobs

When the agent stops, it posts a report. Open **Jobs and reports** from the Paneyard menu (or **This job's report** inside the job's workspace). Type into the agent's pane to give it more work, and ask it to commit, push or merge when you are happy; it merges back into the branch it started from. When you are done with it, choose **Close this job** to end its session and free its slot. Layouts are edited from the menu (or the admin MCP tool `update_workspace_layout`).

Closed the wrong one? Pick the job in **Jobs and reports** and press `o` to **reopen** it. It is queued again and gets a new session on its own branch when a slot is free: in its worktree if that was kept, or in one herdr makes again from the branch if it was removed. The agent resumes its conversation where it can, and otherwise starts fresh with the task and the job's newest report. A job whose branch is gone as well cannot be reopened.

A job that has to build on another job's work can be queued **after** it (`queue_run`'s `after`, from your own agent). It waits, holding no slot, until that job's work is merged into the branch both started from, then starts from there. **Jobs and reports** shows it as `queued/waiting`, or `queued/blocked` if the job it waits for failed or was stopped. Press `s` on its screen to start it without waiting.

A job handed off from another job's branch is a **follow-up** of it. **Jobs and reports** shows the parent's short id after the follow-up's own (`22da ↳7efb`), and a job's screen lists its follow-ups.

### 6. Queue jobs from your own agent

Paneyard's `/mcp/admin` endpoint lets an MCP client queue and inspect jobs. At the end of installation, Herdr prints the command for the interactive `paneyard.setup` action. It detects installed Claude Code and Codex CLIs, asks before changing either one, and registers the endpoint at user scope. Running it again recognizes an up-to-date entry and does not duplicate it. By hand:

```sh
claude mcp add --transport http -s user paneyard "$(cat ~/.local/state/herdr/plugins/paneyard/url)/mcp/admin"
codex mcp add paneyard --url "$(cat ~/.local/state/herdr/plugins/paneyard/url)/mcp/admin"
```

To teach Claude Code to hand off jobs well (finding the workspace, writing a self-contained brief, splitting work, queuing one job `after` another instead of merging in order), link the skill that ships with Paneyard. `paneyard.setup` prints this command with the plugin's own path:

```sh
mkdir -p ~/.claude/skills && ln -sfn <paneyard checkout>/skills/paneyard ~/.claude/skills/paneyard
```

[skills/paneyard/SKILL.md](./skills/paneyard/SKILL.md) is a plain skill file, so other agents that read skills can use it the same way.

The port stays the same across restarts; if it ever has to change (something else took it), Paneyard shows a notification, and `paneyard.setup` updates the registrations in one action. Then ask your agent to hand off a task, list jobs, or check on one. The endpoint is unauthenticated, like the rest of the app, so it only listens on loopback. [MCP endpoints](./docs/operating.md#mcp-endpoints) lists its tools.

### Settings, updates and removal

- **Settings** live in `$(herdr plugin config-dir paneyard)/.env`, written on first start with every option commented out: concurrency, default models, and a fixed port. Run `paneyard.restart` after editing it (the next action notices the edit and restarts too).
- **Updating:** `herdr plugin install nicholasjstock/paneyard` again (`--ref <tag-or-commit>` to pin a version). The next action or herdr start restarts Paneyard on the new code and migrates its database; state and settings are kept.
- **Removing:** `herdr plugin action invoke stop --plugin paneyard`, then `herdr plugin uninstall paneyard`. herdr leaves the state and config directories in place; delete them to remove your job history too.
- **Logs:** `~/.local/state/herdr/plugins/paneyard/log/paneyard.log`, and `herdr plugin log list --plugin paneyard` for the actions themselves.

### Running without the plugin

Paneyard is an ordinary Rails app, and the plugin only packages it. To run it from a clone instead (as its contributors do):

```sh
git clone https://github.com/nicholasjstock/paneyard.git && cd paneyard
bin/setup                    # install gems
bin/service start            # also: stop | restart | status; http://127.0.0.1:7263
```

`bin/service` keeps its state in the clone's `storage/` and logs to `log/production_service.log`; [Long-running: `bin/service`](./docs/operating.md#long-running-binservice) has the details, and [CONTRIBUTING.md](./CONTRIBUTING.md) covers `bin/dev` and the sandbox.

To move from `bin/service` to the plugin with your history, stop `bin/service`, run `paneyard.stop`, copy `storage/production*.sqlite3` from the clone into `~/.local/state/herdr/plugins/paneyard/storage/`, and invoke any action. (Two instances side by side are safe for your worktrees, since each only ever cleans up its own runs', but they share no queue and no concurrency cap.)

## How a job works

The code and the MCP tools call a job a *run* (`queue_run`, `list_runs`, `runId`).

1. **Queue.** A job waits for a slot. The cap is global across all workspaces: `PANEYARD_MAX_CONCURRENT_RUNS`, default 4.
2. **Dispatch.** When a slot frees, herdr creates the oldest queued job's worktree on a `paneyard/<name>` branch, from the current local tip of the job's **base branch** (the branch you handed it off from; the workspace's default when none was named), and opens it as a herdr workspace, where one interactive agent session starts with the task as its first prompt. Several jobs of one repository can start from different branches at once.
3. **Work.** The session explores, edits and runs the repository's own commands, then leaves its changes uncommitted. Commit, push and merge are separate requests; it does only the one you ask for, and a merge goes back into the job's own base branch.
4. **Report.** Each time it stops, the session calls the `report_idle` MCP tool (`done`, `blocked` or `failed`) with a Markdown report. The session stays open and keeps its slot; reports accumulate as checkpoints shown by the Herdr actions and MCP tools.
5. **Close.** **Close session** quits the agent, closes its herdr workspace and frees the slot. A job you haven't closed keeps holding its slot. A closed job can be **reopened**: it queues again for a new session on its own branch.
6. **Clean up.** herdr removes the worktree once its work is saved (clean, and in the job's base branch or pushed). Otherwise it is kept (closing the session says so) until you push or merge it, or remove it yourself. Only Paneyard's own job worktrees are ever removed, never yours.

If a session dies without reporting, the orchestrator notices within about 30 seconds and frees the slot. Pull requests are yours to open from a pushed branch; the orchestrator never opens, watches or merges them.

## Workspace layouts

Each job opens in its own herdr workspace. A workspace's **layout** decides which tabs and panes that herdr workspace has: the agent, plus anything you want running beside it, such as an editor, a dev server or a log tail. By default a job gets just the agent.

To change it from Herdr, invoke `paneyard.layout` in any pane belonging to the repository. Its interactive builder redraws a tree preview as you add tabs and panes, edit commands, choose split targets, directions and ratios, or delete leaf panes and tabs; `agent` is reserved for the agent's own pane, which cannot be edited or deleted. Save validates the complete result before changing anything; Reset restores the default. Raw YAML remains available under the builder's advanced `y` option:

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

Every pane opens in the job's worktree as your normal login shell; Paneyard sets no environment in any of them. A pane with no command is a plain shell. Panes are set up once, when the session starts: Paneyard never watches or restarts them, and **Close session** closes them all. [Workspace layouts](./docs/operating.md#workspace-layouts) in operating.md has the full rules.

## Configuration

Everything is optional except herdr and an agent CLI. With the plugin, put these in `$(herdr plugin config-dir paneyard)/.env`; the plugin sets `PORT` (unless you pin one there), `BINDING`, `PANEYARD_RAILS_URL` and `HERDR_SOCKET_PATH` itself. Running from a clone, they are environment variables.

| Setting | Default | Purpose |
| --- | --- | --- |
| `PORT` | chosen once and kept (plugin), random (`bin/dev`), `7263` (`bin/service`) | HTTP port. |
| `BINDING` | `localhost` (dev), `127.0.0.1` (`bin/service`) | Interface Rails listens on. Widening it exposes an unauthenticated app; see [SECURITY.md](./SECURITY.md). |
| `PANEYARD_ALLOWED_HOSTS` | unset | Extra `Host` names production answers to (comma-separated), for example behind a reverse proxy. |
| `PANEYARD_RAILS_URL` | `http://127.0.0.1:$PORT` | URL sessions use to reach the orchestrator's MCP endpoint. Keep it in step with `PORT`. |
| `PANEYARD_MAX_CONCURRENT_RUNS` | `4` | Global cap on live sessions. |
| `PANEYARD_CLAUDE_MODEL`, `PANEYARD_CODEX_MODEL` | `opus`; none (codex's own default) | Default model per driver; a model picked when queueing wins. |
| `HERDR_SOCKET_PATH` | the socket herdr gives the plugin, else `~/.config/herdr/herdr.sock` | herdr's socket. |
| `PANEYARD_RUBY` | bundled runtime | Development links only: fallback Ruby when `[[build]]` has not installed the bundle. |

Pane layouts are set per workspace ([above](#workspace-layouts)). Paneyard sets no environment variables in a session's panes; see [What a job starts with](./docs/operating.md#3-what-a-run-starts-with-inside-the-repo).

## Documentation

- [docs/herdr-plugin-plan.md](./docs/herdr-plugin-plan.md) — how the herdr plugin is put together, and why.
- [docs/operating.md](./docs/operating.md) — running the orchestrator day to day: preparing repositories, base branches, git and cleanup rules, workspace layouts, MCP endpoints, troubleshooting a failed launch.
- [docs/README.md](./docs/README.md) — index of the design records behind the current architecture.
- [AGENTS.md](./AGENTS.md) — the architecture and conventions guide for anyone (human or agent) changing this codebase.
- [CHANGELOG.md](./CHANGELOG.md) — what has changed.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for setting up to develop Paneyard, running it with `bin/dev` or in the sandbox, the tests and CI, the code layout, and the design rules a change has to follow; [AGENTS.md](./AGENTS.md) is the detailed architecture guide behind it. In short: `bin/setup`, make your change, and run `bin/verify` (specs, RuboCop, a production boot smoke test, an end-to-end run through the sandbox, and security audits) before opening a pull request.

## License

Released under the [MIT License](./LICENSE). Copyright (c) 2026 Nicholas Stock.
