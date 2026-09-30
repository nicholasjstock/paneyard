# Operating the orchestrator

This guide is for **operators**: people running Paneyard and pointing it at their repositories. Start with the [README](../README.md) (and its security model) if you haven't. If you are changing the orchestrator's own code, read [AGENTS.md](../AGENTS.md) and [CONTRIBUTING.md](../CONTRIBUTING.md) instead.

Every rule below names the code it comes from, so you can check it.

- [Running it](#running-it)
- [Preparing a repository](#preparing-a-repository)
  1. [Directory layout](#1-directory-layout)
  2. [Git requirements](#2-git-requirements)
  3. [What a run starts with inside the repo](#3-what-a-run-starts-with-inside-the-repo)
  4. [GitHub access](#4-github-access)
  5. [Register the workspace](#5-register-the-workspace)
  6. [First run](#6-first-run)
- [Workspace layouts](#workspace-layouts)
- [How a run works](#how-a-run-works)
- [MCP endpoints](#mcp-endpoints)
- [Remote control](#remote-control)
- [The sandbox](#the-sandbox)

## Running it

### Development: `bin/dev`

```sh
bin/setup
PORT=3000 bin/dev
```

`bin/dev` starts Puma and Solid Queue together. Before starting either one, it checks the bundle and pending migrations and exits with a recovery command if something is missing. Without `PORT` it picks a random free port, and gives both processes the same one: Solid Queue is what launches sessions, and it points each session's MCP server at `SessionArgs.rails_mcp_url` (`PANEYARD_RAILS_URL`, falling back to `http://127.0.0.1:$PORT`). If you set `PANEYARD_RAILS_URL`, keep it in step with `PORT`:

```sh
PORT=3300 PANEYARD_RAILS_URL=http://127.0.0.1:3300 bin/dev
```

`bin/dev` is not isolated: it runs the full recurring schedule (dispatch, reconcile, Telegram polling if configured, the worktree janitor) against your real herdr. To try things without that, use [the sandbox](#the-sandbox).

### Long-running: `bin/service`

For the instance you keep running, use `bin/service start|stop|restart|status`. It daemonizes `bin/production` (Puma plus Solid Queue in production mode, against `storage/production.sqlite3`), defaults to port `3001`, tracks its pid in `tmp/pids/production.pid`, and logs to `log/production_service.log`. `start` waits for `/up` to answer and fails after two minutes, naming the log.

```sh
bin/service start
```

- **Loopback only.** `bin/production` binds to `127.0.0.1` (`BINDING`), and production answers only loopback `Host` names (`lib/paneyard_allowed_hosts.rb`). Read [SECURITY.md](../SECURITY.md) before widening either with `BINDING` or `PANEYARD_ALLOWED_HOSTS`: the app has no authentication.
- **Credentials.** Production needs a `secret_key_base` from Rails credentials (`config/credentials.yml.enc` plus your own `config/master.key`) or the `SECRET_KEY_BASE` environment variable. See the note in the README's [Quickstart](../README.md#3-start-the-orchestrator).
- **Restarting.** Application code is hot-reloaded (`PANEYARD_HOT_RELOAD=1`), but `config/queue.yml`, `config/recurring.yml`, credentials and initializers are read once at boot. After changing any of them, run `bin/service restart`. It first runs `bin/preflight --prod-copy` (the new code booted on a scratch port against a copy of the production database) and leaves the running instance alone if that fails. `bin/service restart --skip-preflight` skips the check.
- **Console commands** against this instance need `RAILS_ENV=production`, for example `RAILS_ENV=production bin/rails runner '...'`.

The health endpoint `/up` returns `{"status":"ok","service":"paneyard"}` with an `X-Paneyard-Service: paneyard` header, so you can't mistake it for a target Rails app's own `/up`.

## Preparing a repository

Follow these steps once for each repository you want to run jobs against.

### 1. Directory layout

A workspace has a `root_path`: a plain directory that you own and that holds the repository's checkouts. The source checkout **must** be a direct child of it named `main` (`Workspace#source_root` is `<root_path>/main`). Each run's worktree is created as a sibling of that checkout:

```
~/code/my-app/                    <- root_path (what you register)
├── main/                         <- source checkout, on branch main
├── add-cart-total-1a2b/          <- run worktree, branch paneyard/add-cart-total-1a2b
└── fix-tax-rounding-9f3c/        <- run worktree, branch paneyard/fix-tax-rounding-9f3c
```

Setting that up for a repository you already have on GitHub:

```sh
mkdir -p ~/code/my-app
git clone git@github.com:you/my-app.git ~/code/my-app/main
```

Worktree and branch names are a slug of the task plus a short run-id suffix (`GitWorktree.name_for`). Keep everything else out of `root_path`. Launching a run fails if its worktree path already exists.

### 2. Git requirements

Before creating a worktree, `GitWorktree.validate_source!` checks all of these, and fails the run if any one is untrue:

- `<root_path>/main` exists and is a git work tree.
- Its directory is named `main`, **and it has the `main` branch checked out**. A repository whose default branch is `master` or anything else needs a local `main` branch. The simplest fix is to rename the default branch.
- It has an `origin` remote. If you ask a session to push, it pushes `paneyard/<name>` to `origin`, so `origin` must be a remote this machine can push to. It pushes only when asked to push, not when asked to commit (`Orchestrator::RunPrompt`).

Each run branches from the source checkout's **current local `HEAD`**. The orchestrator never fetches or pulls, so keep `<root_path>/main` up to date yourself (`git -C ~/code/my-app/main pull`). Uncommitted changes in `main` are not carried into a run's worktree.

For the cleanup side, `Orchestrator::WorktreeJanitor` removes a worktree (never its branch) on **Close session**, when you close a run's herdr workspace by hand, and on a ten-minute sweep (`WorktreeCleanupJob`, `config/recurring.yml`). It removes one only when all of these hold:

- the run's session is over;
- `git status --porcelain` is empty in the worktree;
- `HEAD` is either an ancestor of the local `main` branch (`git merge-base --is-ancestor HEAD main`) or contained in some remote-tracking branch (`git branch --remotes --contains HEAD`).

So removal depends on the local `main` ref and on remote-tracking refs. A plain `git push -u origin ...` updates `refs/remotes/origin/...`, which is enough. Anything else stays on disk indefinitely and is flagged as a **kept worktree** on the runs list and run screen, where **Remove worktree** removes it by hand. The janitor never touches a worktree named `main`.

> [!IMPORTANT]
> The sweep covers **every** worktree of the source repository, not only the ones the orchestrator created. A worktree you made by hand with no matching run is treated as an orphan and removed once it is clean and pushed or merged (its branch is kept). Don't keep your own worktrees of a registered repository if you expect them to stay.

### 3. What a run starts with inside the repo

A worktree is a fresh checkout of committed files only. Anything untracked or gitignored in `main` (`.env`, `config/master.key`, `node_modules`, a local database) is **not** there. The orchestrator runs no setup commands and never infers a language, package manager, or ports. The session works those out itself each run. That puts the burden on the repository:

- **`AGENTS.md` / `CLAUDE.md` in the target repository** are how you tell a session how to set up, build, and test. Sessions start in the worktree and read the repository's own instruction files the way they would if you ran the CLI there yourself. `claude` is deliberately launched without `--setting-sources`, so it loads the repository's `CLAUDE.md` and `.claude/` settings. It does get `--strict-mcp-config`, so any `.mcp.json` in the repository is ignored in favour of the orchestrator's MCP server (`Runner::SessionArgs`). `codex` and `opencode` read `AGENTS.md`.
- **Tests.** The run prompt (`Orchestrator::RunPrompt`) does not tell the session to run tests. It tells the session to leave its changes uncommitted until asked, and asks for a `report_idle` summary that includes how the change was verified. If a repository needs particular verification, put the commands in its `AGENTS.md`/`CLAUDE.md`, or in the task text.
- **Environment variables.** A session can call the `record_workspace_env_var` MCP tool to save a workaround (for example a bundler path). The value is stored as a `WorkspaceEnvVar` on the workspace and set in every later session's pane environment (`Orchestrator::WorkspaceEnvVars`, merged first in `Runner::ProcessEnv.for_session`, so it can't override anything the orchestrator sets). Values are literal and must not contain `$` or a backtick, because they are never shell-expanded. They are stored in plaintext in the orchestrator's database, so don't use them for secrets. There is no UI for them. To inspect them or seed them yourself, use the console:

  ```sh
  bin/rails runner 'w = Workspace.find_by!(name: "my-app"); pp w.workspace_env_vars.pluck(:name, :value)'
  bin/rails runner 'Workspace.find_by!(name: "my-app").workspace_env_vars.create!(name: "FOO", value: "/abs/path", evidence_ref: "operator", recorded_by: "operator")'
  ```

  (Against `bin/service`, prefix those commands with `RAILS_ENV=production`.)
- **Environment the orchestrator removes.** `Runner::ProcessEnv` unsets the orchestrator's own Bundler activation (`BUNDLE_GEMFILE`, `RUBYOPT`, …), `RAILS_ENV`, and nested-Claude-Code markers, so the target repository resolves its own `Gemfile.lock` and picks its own Rails env.
- **Permissions.** Every session runs with full access and approvals bypassed (`--permission-mode bypassPermissions`, `-s danger-full-access`, `--auto`). The review gate is you trying the session's changes before you ask it to commit.

### 4. GitHub access

The orchestrator opens no pull requests and makes no GitHub API calls about your repository. The only GitHub call it makes is to mint a GitHub App token, below. What needs credentials is the session's `git push`. The session's credentials are chosen (`RunSessionRunner.session_spec`, then `Runner::ProcessEnv`) in this order:

1. **GitHub App configured** (`GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY`, or `github_app:` in credentials; see [GITHUB_APP_SETUP.md](../GITHUB_APP_SETUP.md)): the orchestrator reads the worktree's `remote.origin.url`, finds the App installation whose account matches the repository's **owner**, and mints an installation token. The session gets it as `GH_TOKEN`, with `gh auth git-credential` as a git credential helper.
2. **No App, or minting fails** (App not installed on that owner, a non-GitHub `origin`, an API error): it falls back to `gh auth token`, which is your own `gh` login.
3. **Neither is available**: the session gets no injected credentials and pushes with whatever your login shell already has.

What that means in practice:

- **You don't need a GitHub App at all** if you're happy for sessions to push as you. Being signed in to `gh` (`gh auth login`) is enough for an HTTPS `origin`.
- **With an SSH `origin`** (`git@github.com:...`), `git push` goes over SSH and never uses the token or credential helper. Pushing then depends only on your SSH key being usable from a herdr pane (for example through ssh-agent), with or without a GitHub App. `gh` inside the session still uses `GH_TOKEN`.
- **If you do use the App**, its installation must cover this repository with **Contents: Read & write**. **Pull requests: Read & write** is only needed if you'll ask sessions to run `gh pr create`. The installation is matched by owner only: if the owner has the App installed but this repository isn't among its selected repositories, a token is still minted and the push fails with 403. Add the repository under the installation's **Configure** page.
- Tokens are fixed when a session starts and cached for 55 minutes, so a long-lived session can find its token expired. Also, the cache key is per App, not per installation: if you run repositories under two different owners through one App, a session can be handed the other owner's cached token and fail to push until it expires.

### 5. Register the workspace

Every way in takes a **name** (unique; it's what `queue_run` and the other MCP tools take as `workspace`) and a **root**: `root_path`, the parent directory (`~/code/my-app`). The web UI and the MCP tool also accept the `main` checkout itself, a directory inside it, or a run's worktree, and register the root above it. The name can't be changed later. You can change the root, except while the workspace has an active run.

The web UI and the MCP tool check the layout before saving, with the same rules a launch enforces in [step 2](#2-git-requirements) (`Orchestrator::WorkspaceRegistration`, which asks the runner's `check_workspace_root`): the root is an absolute path (`~` is expanded) to an existing directory, `<root>/main` is a git checkout of its own with `main` checked out and an `origin` remote, and no other workspace has the name or the root. If anything is wrong, nothing is saved and every problem is listed with how to fix it, including the usual mistakes: giving a plain clone with no `main/` child (the `mkdir` and `git clone` commands for the right layout), and a checkout on `master` (how to switch to or rename it to `main`). The check only looks; it never clones, moves or renames anything. The saved root is the expanded path.

- **Web UI**: open the orchestrator, choose **Add workspace**, and enter a **Name** and the **Workspace root**. Editing a workspace's root runs the same check; editing only its layout does not.
- **MCP**, from your own agent over [`/mcp/admin`](#mcp-endpoints): the `register_workspace` tool, with `name` and `rootPath`. For example, in a Claude Code session with `paneyard-admin` registered, ask:

  > Register ~/code/my-app as a Paneyard workspace called my-app.

  which calls

  ```json
  { "name": "register_workspace", "arguments": { "name": "my-app", "rootPath": "~/code/my-app" } }
  ```

  On success it returns the workspace as `list_workspaces` shows it, plus `rootPath` and `originUrl`. Otherwise it returns an error result whose `problems` list every problem (`code` and `message`), and your agent can run the fixes it suggests and call it again. The tool is on `/mcp/admin` only; a run session can't register workspaces.
- **Console**, which skips the check:

  ```sh
  bin/rails runner 'Workspace.create!(name: "my-app", root_path: File.expand_path("~/code/my-app"))'
  ```

### 6. First run

From the workspace's runs page, choose **Queue a task**, give it a task, and pick a driver (and optionally a model). Or queue it over MCP (below). Within a few seconds `RunDispatchJob` claims it, and a herdr workspace named after the worktree opens with the agent on the left and `nvim` on the right, or with whatever tabs and panes that workspace's layout defines.

It worked when the session calls `report_idle` and the run screen shows its checkpoint. Ask it to commit and push, and `git -C ~/code/my-app/main ls-remote origin 'paneyard/*'` then lists the branch.

If the launch fails, the run screen shows the error. The common ones map back to the steps above:

| Error | Cause |
| --- | --- |
| "Source checkout must be on main" | `<root_path>/main` has another branch checked out ([step 2](#2-git-requirements)). |
| "has no origin remote" | Add an `origin` remote ([step 2](#2-git-requirements)). |
| "Worktree path already exists" | Something else is at the worktree's path under `root_path` ([step 1](#1-directory-layout)). |
| herdr unreachable | herdr isn't running, or `HERDR_SOCKET_PATH` points at the wrong socket. |
| "never became ready" | The agent CLI is missing from your login shell's `PATH`, isn't signed in, or rejected the model. The run screen keeps the agent pane's last screen. |

## Workspace layouts

Each workspace's new and edit forms have a **Layout** editor: the herdr tabs and panes its runs open with. Name each tab. Add panes, give each a command, and pick which earlier pane it splits off, to the right or below, and how much of the space that pane keeps. A live sketch of each tab shows the result. Until you change anything, the workspace uses the default layout (the agent with `nvim .` split beside it, or only the agent when `nvim` isn't on the orchestrator's `PATH`), and **Reset to default** goes back to it. The layout is stored as YAML (`workspaces.layout`), in this shape:

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
      - name: test-log
        command: tail -f log/test.log
        split: { of: dev-log, direction: down }
```

Have as many tabs as you like, each with as many splits as you like. The agent pane is the only one that is required, and it is always the first pane of the first tab, which is the tab a run opens on. Every other pane is split off an earlier pane in its own tab, `right` or `down`; `ratio` is the share the pane being split keeps. A `command` is typed into the pane's own shell in the run's worktree, and every pane gets the same environment as the agent (`GH_TOKEN`, `PANEYARD_RUN_ID`, the workspace's recorded env vars). A pane with no command is a plain shell. The panes are only set up when the session starts. The orchestrator never watches or restarts them, and Close session, or the agent pane going away, closes all of them. See [workspace-layouts.md](./workspace-layouts.md) for the design.

## How a run works

1. **Queue it.** Creating a run starts nothing. It waits for a slot. The cap is global across every workspace: `PANEYARD_MAX_CONCURRENT_RUNS`, default 4.
2. **Dispatch.** `RunDispatchJob` claims the oldest queued run. `StartRunSessionJob` provisions its worktree and opens one interactive session in a herdr pane rooted there, with the task as its first prompt.
3. **Work.** The session owns the job. It explores, edits, and runs the repository's own commands, then leaves its changes uncommitted for you to try. Ask it to commit, push, or merge into `main` when you're happy; each is a separate request, and it does only the one you ask for. Watch it in your herdr client, or send it a message from the run screen.
4. **Report.** The session calls the `report_idle` MCP tool (`done`, `blocked`, or `failed`) each time it stops working. This does not end the run: the pane stays open and the slot stays held. Each report is a checkpoint covering the interval since the last one, written as a full Markdown report, and the run screen lists them in order.
5. **Decide.** Read the reports, then either send more work or **Close session**, which quits the CLI, closes the herdr workspace, and frees the slot. An unreviewed run keeps holding its slot, so it blocks the queue. Pull requests are yours to open from a pushed branch.
6. **Clean up.** `WorktreeJanitor` removes the worktree on Close session if its work is saved (see [Git requirements](#2-git-requirements)), and otherwise keeps it and flags it until you push, merge, or remove it.

If a session dies without reporting (pane closed, CLI crashed), `RunSessionReconcileJob` notices within about 30 seconds and frees the slot.

There is no cost or token accounting for sessions: they are real interactive terminal UIs, not structured-output batch jobs.

## MCP endpoints

- **`/mcp/run`** is what each session talks to, authenticated by a per-session bearer token that dies with the session. It has `report_idle`, `record_workspace_env_var`, and the shared tools below. The orchestrator wires it into each CLI automatically, so you don't configure anything.
- **`/mcp/admin`** is **unauthenticated** and lets your own MCP clients queue and inspect runs without the web UI. Keep it on loopback (see [SECURITY.md](../SECURITY.md)). Its tools are `queue_run` (task, `workspace` name, optional `driver`), `list_runs`, `get_run`, `list_workspaces` (each workspace's name, source checkout path, active-run count, and which one `list_runs` and `get_run` default to when `workspace` is omitted), `register_workspace` (`name`, `rootPath`; checks the layout first and creates nothing if it is wrong, see [step 5](#5-register-the-workspace)), and `ping_tool`. For example, to add it to Claude Code for every project (`-s user`; without it, the server is registered only for the project you run the command in):

  ```sh
  claude mcp add --transport http -s user paneyard-admin http://127.0.0.1:3001/mcp/admin
  ```

  From here `queue_run` always needs `workspace`: it never falls back to a default, so a job can't land in an unrelated workspace because the repository you are in isn't registered. The endpoint's server instructions, which Claude Code reads, spell out the flow: `list_workspaces`, match `sourceRoot` against the repository, `register_workspace` if nothing matches, then `queue_run`. So in a repository that isn't registered, "queue a job to …" registers it first, from the `main` checkout the agent was opened in. A plain clone (`.git` at the top) doesn't pass the layout check, and the fix `register_workspace` returns clones it into `<new root>/main`. Runs then work from that clone, not the directory you opened.

See AGENTS.md's "MCP Boundary" for the design rules behind both.

## Remote control

The optional Telegram bot lets you check on and steer live sessions from your phone. See [telegram.md](./telegram.md).

## The sandbox

`bin/sandbox` runs this checkout's code as a complete, isolated instance, useful both for trying the orchestrator out and for testing changes to it:

```sh
bin/sandbox start [--real-herdr] [--telegram]   # boot tmp/sandbox, seed a scratch workspace, print its URL
bin/sandbox status
bin/sandbox stop
bin/sandbox reset                               # stop and delete tmp/sandbox
bin/sandbox verify [--keep]                     # boot a fresh instance and drive a run through it end to end
```

It runs real Puma and Solid Queue with the real recurring schedule on a free `127.0.0.1` port, with its own SQLite files, pid and log under `tmp/sandbox/`, beside a **fake herdr** whose "agents" are scripted processes that never call a model. Put a `[fake-agent: done|blocked|failed|dirty|crash|manual|working]` directive in a task to choose what the fake agent does (default `done`). While `PANEYARD_SANDBOX=1`, `Orchestrator::Sandbox` refuses your real herdr socket, remote-control credentials, GitHub tokens, and any worktree or process outside the sandbox. It never touches `storage/production*.sqlite3`, `tmp/pids/production.pid` or the production port.

Two opt-ins bring real integrations back, one at a time:

- `--real-herdr` opens the sandbox's runs in your own herdr (workspaces labelled `[sandbox] ...`) running the real agent CLI, which **spends real model usage**, on throwaway tasks in the scratch repository.
- `--telegram` makes the sandbox poll and answer Telegram as a **second bot**. Give it its own token and your user id in `SANDBOX_TELEGRAM_BOT_TOKEN` / `SANDBOX_TELEGRAM_ALLOWED_USER_IDS` (in the environment or `~/.config/paneyard/sandbox.env`). Never reuse your main instance's bot: Telegram hands each message to one poller, so two instances sharing a bot split your messages.
