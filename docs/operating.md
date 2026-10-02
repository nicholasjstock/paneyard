# Operating the orchestrator

This guide is for **operators**: people running Paneyard and pointing it at their repositories. Start with the [README](../README.md) (and its security model) if you haven't. If you are changing the orchestrator's own code, read [AGENTS.md](../AGENTS.md) and [CONTRIBUTING.md](../CONTRIBUTING.md) instead.

Every rule below names the code it comes from, so you can check it.

- [Running it](#running-it)
- [Preparing a repository](#preparing-a-repository)
  1. [The repository and its worktrees](#1-the-repository-and-its-worktrees)
  2. [Branches and git requirements](#2-branches-and-git-requirements)
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

### As a herdr plugin

`herdr plugin install nicholasjstock/paneyard` (README, [Getting started](../README.md#getting-started)) is the usual way. The plugin (`herdr-plugin.toml`, `bin/herdr-plugin`, `lib/paneyard_plugin/`) runs the same `bin/production` that `bin/service` does, as a daemon it owns, so everything else in this guide applies unchanged. [docs/herdr-plugin-plan.md](./herdr-plugin-plan.md) has the design.

- **When it runs.** herdr's startup hook starts it when the herdr server starts, and every action starts it if it is not running (herdr does not run startup hooks on install). It keeps running when herdr stops; `paneyard.stop` stops it. Starting is idempotent and locked, so two callers never start two servers.
- **Where its state is.** Under `~/.local/state/herdr/plugins/paneyard` (`HERDR_PLUGIN_STATE_DIR`): `storage/` (the databases, `PANEYARD_STORAGE_DIR`), `run_sessions/` (each session's MCP config and prompt, `PANEYARD_RUNTIME_DIR`), `log/paneyard.log` (rotated at 10 MB), `secret_key_base` (generated on first start), `port` and `url`, and `daemon.json` (pid, port, herdr socket). The managed checkout holds the code, bundled Ruby (`.paneyard/runtime`) and its production gems (`vendor/bundle`).
- **Settings.** `$(herdr plugin config-dir paneyard)/.env`, dotenv format, every key passed to the app as an environment variable. Keys the plugin sets itself (`RAILS_ENV`, `BINDING`, `PIDFILE`, `HERDR_SOCKET_PATH`, `PANEYARD_STORAGE_DIR`, `PANEYARD_RUNTIME_DIR`, `PANEYARD_RAILS_URL`, the sandbox switches) are ignored there. `PORT` pins the port. `PANEYARD_RUBY` is only a fallback for a development checkout linked without running the plugin build. A change applies on `paneyard.restart`, or on the next action, which notices the file changed.
- **Port.** Chosen the first time and kept, so an MCP registration keeps working. If something else holds it at a later start, a new one is chosen and a herdr notification says so; re-register with `paneyard.setup`.
- **Which herdr.** It uses the socket herdr hands the plugin, and stays with the herdr server that started it. A startup hook from another herdr server (a named session) leaves it running where it is, since its sessions live there; `paneyard.restart` from the other server moves it deliberately, after which reconcile treats the first server's live sessions as lost.
- **Restarts and upgrades.** `paneyard.restart` is the plugin's `bin/service restart`, minus the preflight. Reinstalling (`herdr plugin install` again, optionally `--ref`) replaces the code; the next action or herdr start restarts the daemon because the version or lockfile changed, and `bin/production` migrates on start. Sessions keep running through a restart: herdr owns them.
- **Troubleshooting.** `bin/herdr-plugin status` in the plugin's directory (`herdr plugin list --plugin paneyard` shows it) prints the URL, socket and paths. A failed runtime download or checksum leaves its error in the install output; reinstall after checking GitHub connectivity. A popup that closes straight away, or an action that fails, leaves its error in `herdr plugin log list --plugin paneyard`; a daemon that will not boot leaves it at the end of `log/paneyard.log`.
- **One instance per machine.** Do not run the plugin and `bin/service` against the same repositories: each one's janitor treats worktrees the other created as orphans and removes the clean ones. See the README's [Running without the plugin](../README.md#running-without-the-plugin) for moving data from one to the other.

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

For the instance you keep running, use `bin/service start|stop|restart|status`. It daemonizes `bin/production` (Puma plus Solid Queue in production mode, against `storage/production.sqlite3`), defaults to port `7263`, tracks its pid in `tmp/pids/production.pid`, and logs to `log/production_service.log`. `start` waits for `/up` to answer and fails after two minutes, naming the log.

```sh
bin/service start
```

- **Upgrading from port 3001.** The default used to be `3001`. To keep it, start the service with `PORT=3001 bin/service start` (and `restart`). Otherwise, re-register your MCP client against the new port (`claude mcp remove paneyard-admin -s user`, then the `claude mcp add` in [MCP endpoints](#mcp-endpoints)), and point any `tailscale serve` config at `7263`.
- **Upgrading to repository workspaces.** The migration turns every `<root>/main` workspace into that repository with `main` as its default base branch, and every existing run into one from `main`. Nothing on disk moves. Old runs' worktrees beside `main` keep working: herdr can open and remove any linked worktree of the repository.
- **Loopback only.** `bin/production` binds to `127.0.0.1` (`BINDING`), and production answers only loopback `Host` names (`lib/paneyard_allowed_hosts.rb`). Read [SECURITY.md](../SECURITY.md) before widening either with `BINDING` or `PANEYARD_ALLOWED_HOSTS`: the app has no authentication.
- **Credentials.** Production needs a `secret_key_base` from Rails credentials (`config/credentials.yml.enc` plus your own `config/master.key`) or the `SECRET_KEY_BASE` environment variable. `bin/rails credentials:edit` creates both (README, [Running without the plugin](../README.md#running-without-the-plugin)). The herdr plugin generates its own instead.
- **Restarting.** The running instance does not reload code. Every change, application code and migrations included as well as `config/queue.yml`, `config/recurring.yml`, credentials and initializers, takes effect on `bin/service restart`. It first runs `bin/preflight --prod-copy` (the new code booted on a scratch port against a copy of the production database) and leaves the running instance alone if that fails. `bin/service restart --skip-preflight` skips the check.
- **Console commands** against this instance need `RAILS_ENV=production`, for example `RAILS_ENV=production bin/rails runner '...'`.

The health endpoint `/up` returns `{"status":"ok","service":"paneyard"}` with an `X-Paneyard-Service: paneyard` header, so you can't mistake it for a target Rails app's own `/up`.

## Preparing a repository

Follow these steps once for each repository you want to run jobs against.

### 1. The repository and its worktrees

A workspace is an existing git checkout you already work in (`Workspace#repository_path`), plus the branch runs start from by default (`default_base_branch`). Any directory name, any parent directory, and any branch checked out: runs never work in your checkout, and Paneyard never switches, resets, stashes or deletes it.

Each run gets its own **linked worktree** of the repository, on a branch `paneyard/<name>`, made by herdr (`worktree.create`) wherever your herdr config puts worktrees (by default `~/.herdr/worktrees/<repository>/<branch>`). Paneyard never chooses that location. herdr opens the worktree as the run's herdr workspace, and the session's layout is built in it. Worktree and branch names are a slug of the task plus a short run-id suffix (`GitWorktree.name_for`). The first run in a repository may also open a herdr workspace for the repository itself: that is herdr grouping a repository's worktrees, and Paneyard leaves it alone.

```
~/code/my-app/                                    <- the repository you register, on whatever branch
~/.herdr/worktrees/my-app/paneyard-add-cart-1a2b  <- a run from main
~/.herdr/worktrees/my-app/paneyard-fix-tax-9f3c   <- a run from feature/payments
```

### 2. Branches and git requirements

Each run has a **base branch**: the workspace's default unless the run names another when it is queued (`base_branch` on the run, `baseBranch` on `queue_run`, or the branch in the plugin's queue popup). The plugin names the branch your pane is on unless you type another, and `/mcp/admin`'s instructions tell an agent to pass the branch it has checked out, so in practice a run starts from whatever you are working on. It is fixed on the run when it is queued, so changing the workspace's default later doesn't move it, and two runs of one workspace can start from different branches at the same time. The run's branch starts from the base branch's current **local** tip (`git worktree add -b paneyard/<name> <path> <base>`, done by herdr), whatever your checkout has checked out, and the run merges back into that same branch when asked to merge (`Orchestrator::RunPrompt`):

```
feature/payments -> paneyard/fix-tax-9f3c -> merged back into feature/payments
main             -> paneyard/add-cart-1a2b -> merged back into main
```

The rules, checked when a workspace is registered and again when a run is queued (`Runner::Worktrees.base_branch_problem`), so a bad branch is an error then rather than a failed launch later:

- The base branch must exist **locally**. A branch that only exists on `origin` is not used directly; the error gives the command to create it locally (`git branch <name> origin/<name>`, which checks nothing out).
- The repository needs an `origin` remote. If you ask a session to push, it pushes `paneyard/<name>` to `origin`, so it must be a remote this machine can push to. It pushes only when asked to push, not when asked to commit.
- The orchestrator never fetches or pulls, so keep your base branches up to date yourself. Uncommitted changes in your checkout are not carried into a run.

To merge, a session merges into the base branch where it is checked out (if that checkout is clean), or, when it is checked out nowhere, fast-forwards it with `git fetch . paneyard/<name>:<base>`. It never switches your checkout to do it, and reports `blocked` when neither works.

For the cleanup side, `Orchestrator::WorktreeJanitor` removes a run's worktree (never its branch) on **Close session**, when you close a run's herdr workspace by hand, and on a ten-minute sweep (`WorktreeCleanupJob`, `config/recurring.yml`). It considers **only worktrees that belong to its own runs**, and removes one only when all of these hold:

- the run's session is over;
- `git status --porcelain` is empty in the worktree;
- `HEAD` is either an ancestor of the run's own base branch (`git merge-base --is-ancestor HEAD refs/heads/<base>`) or contained in some remote-tracking branch (`git branch --remotes --contains HEAD`).

Removal goes through herdr (`worktree.remove`, which needs the worktree's herdr workspace open, so the janitor reopens it first when it was closed). Anything else stays on disk indefinitely as a **kept worktree**; closing the session says it was kept. Worktrees you make yourself, and your repository's own checkout, are never touched.

### 3. What a run starts with inside the repo

A worktree is a fresh checkout of committed files only. Anything untracked or gitignored in your checkout (`.env`, `config/master.key`, `node_modules`, a local database) is **not** there. The orchestrator runs no setup commands and never infers a language, package manager, or ports. The session works those out itself each run. That puts the burden on the repository:

- **`AGENTS.md` / `CLAUDE.md` in the target repository** are how you tell a session how to set up, build, and test. Sessions start in the worktree and read the repository's own instruction files the way they would if you ran the CLI there yourself. `claude` is deliberately launched without `--setting-sources`, so it loads the repository's `CLAUDE.md` and `.claude/` settings. It does get `--strict-mcp-config`, so any `.mcp.json` in the repository is ignored in favour of the orchestrator's MCP server (`Runner::SessionArgs`). `codex` reads `AGENTS.md`.
- **Tests.** The run prompt (`Orchestrator::RunPrompt`) does not tell the session to run tests. It tells the session to leave its changes uncommitted until asked, and asks for a `report_idle` summary that includes how the change was verified. If a repository needs particular verification, put the commands in its `AGENTS.md`/`CLAUDE.md`, or in the task text.
- **Environment.** Paneyard gives a session's panes no environment of its own: each pane is your normal login shell, exactly as any herdr pane is (herdr's `worktree.create` takes no environment, and a pane inherits nothing from Paneyard's process). What a session needs from Paneyard -- its `/mcp/run` capability -- is in its CLI's own config: claude's `--mcp-config` file, codex's `-c` header override. Anything a repository needs set belongs in its own tooling (`.envrc`, `mise.toml`, its `AGENTS.md`).
- **Permissions.** Every session runs with full access and approvals bypassed (`--permission-mode bypassPermissions`, `-s danger-full-access`). The review gate is you trying the session's changes before you ask it to commit.

### 4. GitHub access

The orchestrator opens no pull requests and makes no GitHub calls. What needs credentials is a session's `git push`, and it uses whatever your login shell has: an SSH key through ssh-agent for an SSH `origin`, or your `gh` login (`gh auth login`, with gh as git's credential helper) for an HTTPS one. A session pushes as you.

### 5. Register the workspace

Registering takes the repository's **path** -- the checkout, any directory in it, or a linked worktree of it, from which its main checkout is worked out -- and optionally a **name** (default: the checkout's directory name, made unique) and a **default base branch** (default: the repository's own default branch: `origin/HEAD`, then `init.defaultBranch`, then `main` or `master`, whichever exists locally; never just whatever happens to be checked out). None of these can be changed after registering; only the workspace's [layout](#workspace-layouts) can.

Registration checks everything first (`Orchestrator::WorkspaceRegistration`, which asks the runner's `check_repository`): the path exists and is in a git checkout, the default base branch exists locally, the repository has an `origin`, and no other workspace has the name or the repository. If anything is wrong, nothing is saved and every problem is listed with how to fix it. The check only looks; it never clones, fetches, switches or renames anything.

- **The herdr plugin**: the **queue** action registers the repository the focused pane is in, the first time you queue a task there.
- **MCP**, from your own agent over [`/mcp/admin`](#mcp-endpoints): the `register_workspace` tool. For example, in a Claude Code session with Paneyard registered, ask "register this repository with Paneyard", which calls

  ```json
  { "name": "register_workspace", "arguments": { "path": "~/code/my-app" } }
  ```

  or, to choose the branch runs start from, `{ "path": "~/code/my-app", "defaultBaseBranch": "develop" }`. On success it returns the workspace as `list_workspaces` shows it, plus `originUrl`. Otherwise it returns an error result whose `problems` list every problem (`code` and `message`), and your agent can run the fixes it suggests and call it again. The tool is on `/mcp/admin` only; a run session can't register workspaces.
- **Console**, which skips the check:

  ```sh
  bin/rails runner 'Workspace.create!(name: "my-app", repository_path: File.expand_path("~/code/my-app"), default_base_branch: "main")'
  ```

### 6. First run

Queue it from herdr with the plugin's **queue** action in a pane of the repository: give it a task, a base branch (the pane's branch by default), and a driver and model (by default the agent running in that pane, on the model it is using now). Or queue it over MCP (below). Within a few seconds `RunDispatchJob` claims it, and herdr opens a workspace for the run's new worktree with the agent in it, plus whatever tabs and panes that workspace's layout defines.

It worked when the session calls `report_idle` and the report action shows its checkpoint. Ask it to commit and push, and `git -C ~/code/my-app ls-remote origin 'paneyard/*'` then lists the branch.

If the launch fails, the runs action shows the error. The common ones:

| Error | Cause |
| --- | --- |
| "Base branch `x`: there is no local branch `x`" | The base branch was deleted or renamed after the run was queued ([step 2](#2-branches-and-git-requirements)). |
| "herdr could not create the worktree" | herdr refused `worktree.create`, for example because something already exists at the path it chose for the branch. |
| herdr unreachable | herdr isn't running, or `HERDR_SOCKET_PATH` points at the wrong socket. |
| "never became ready" | The agent CLI is missing from your login shell's `PATH`, isn't signed in, or rejected the model. Paneyard keeps the agent pane's last screen in the run record. |
| "claude stopped at its folder-trust prompt" | Open `claude` once in the repository and trust it; its worktrees count as the same project. |

## Workspace layouts

The plugin's `paneyard.layout` action opens the primary **Layout** editor inside Herdr: an interactive builder for the tabs and panes its runs open with. It redraws a tree preview while you add or edit panes, choose the earlier pane each splits from, set right/down and an optional ratio, delete leaf panes, or reset to the default. Raw YAML is available as an advanced option. Until you change anything, the workspace uses the default layout: the agent alone. The layout is stored as YAML (`workspaces.layout`), in this shape:

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

Have as many tabs as you like, each with as many splits as you like. The agent pane is the only one that is required, and it is always the first pane of the first tab, which is the tab a run opens on. Every other pane is split off an earlier pane in its own tab, `right` or `down`; `ratio` is the share the pane being split keeps. A `command` is typed into the pane's own shell in the run's worktree; every pane is your normal login shell, with no environment of Paneyard's. A pane with no command is a plain shell. The panes are only set up when the session starts. The orchestrator never watches or restarts them, and Close session, or the agent pane going away, closes all of them. See [workspace-layouts.md](./workspace-layouts.md) for the design.

## How a run works

1. **Queue it.** Creating a run starts nothing. It waits for a slot. The cap is global across every workspace: `PANEYARD_MAX_CONCURRENT_RUNS`, default 4.
2. **Dispatch.** `RunDispatchJob` claims the oldest queued run. `StartRunSessionJob` has herdr create its worktree from the run's base branch and open it as a herdr workspace, and starts one interactive session in it, with the task as its first prompt.
3. **Work.** The session owns the job. It explores, edits, and runs the repository's own commands, then leaves its changes uncommitted for you to try. Ask it to commit, push, or merge back into its base branch when you're happy; each is a separate request, and it does only the one you ask for. Watch and steer it in your herdr client.
4. **Report.** The session calls the `report_idle` MCP tool (`done`, `blocked`, or `failed`) each time it stops working. This does not end the run: the pane stays open and the slot stays held. Each report is a checkpoint covering the interval since the last one, written as a full Markdown report, and the runs/report actions list them in order.
5. **Decide.** Read the reports, then either send more work or **Close session**, which quits the CLI, closes the herdr workspace, and frees the slot. An unreviewed run keeps holding its slot, so it blocks the queue. Pull requests are yours to open from a pushed branch.
6. **Clean up.** `WorktreeJanitor` has herdr remove the worktree on Close session if its work is saved (in its base branch, or pushed; see [Branches and git requirements](#2-branches-and-git-requirements)), and otherwise keeps it until you push, merge, or remove it.
7. **Reopen, if need be.** A closed run is not necessarily final. **Reopen session** (`o` on a run's screen in the plugin's runs popup, or `reopen_session`) queues it again, ahead of runs queued after it first was, and `StartRunSessionJob` gives it a new session on its own branch when a slot is free (`Orchestrator::SessionReopen`): in its worktree if that was kept, or in one herdr makes again on the existing branch, as it is, if it was removed. The new session resumes the previous one's CLI conversation (`claude --resume`, `codex resume`) when the worktree is back at the same path, which it normally is since herdr names it after the branch; otherwise, or if the resumed CLI does not come up, it starts a fresh conversation in the same pane, with the task and the newest report. Either way it is told to report where the run stands and wait. A run whose branch has been deleted as well cannot be reopened.

If a session dies without reporting (pane closed, CLI crashed), `RunSessionReconcileJob` notices within about 30 seconds and frees the slot.

There is no cost or token accounting for sessions: they are real interactive terminal UIs, not structured-output batch jobs.

## MCP endpoints

- **`/mcp/run`** is what each session talks to, authenticated by a per-session bearer token that dies with the session. It has `report_idle` and the shared tools below. The orchestrator wires it into each CLI automatically, so you don't configure anything.
- **`/mcp/admin`** is **unauthenticated** and lets your own MCP clients queue and inspect runs. Keep it on loopback (see [SECURITY.md](../SECURITY.md)). Its tools are `queue_run` (task, `workspace` name, optional `baseBranch`, `driver` and `model`), `list_models` (`driver`: the model ids that driver's CLI offers, and the default), `list_runs`, `get_run`, `list_workspaces` (each workspace's name, repository path, default base branch, layout, active-run count, and which one `list_runs` and `get_run` default to when `workspace` is omitted), `register_workspace` (`path`, optional `name` and `defaultBaseBranch`; checks everything first and creates nothing if anything is wrong, see [step 5](#5-register-the-workspace)), `update_workspace_layout` (`workspace`, complete layout YAML; empty resets it to the default), `close_session` (`runId`, `workspace`; the herdr plugin's close action uses it), `reopen_session` (`runId`, `workspace`; queues a closed run again for a new session, see [How a run works](#how-a-run-works)), and `ping`. `list_runs` and `get_run` give a follow-up -- a run whose base branch is another run's branch -- that run as `parentRunId`, and `get_run` lists a run's `followUpRunIds` and says whether it is `reopenable` (and if not, `reopenProblem`). The plugin's `paneyard.layout` action builds and validates the layout inside a Herdr popup. Its `paneyard.setup` action detects Claude Code and Codex, asks before changing their user configuration, and registers the plugin's own URL. Manual equivalents are:

  ```sh
  claude mcp add --transport http -s user paneyard http://127.0.0.1:7263/mcp/admin
  codex mcp add paneyard --url http://127.0.0.1:7263/mcp/admin
  ```

  From here `queue_run` always needs `workspace`: it never falls back to a default, so a job can't land in an unrelated workspace because the repository you are in isn't registered. The endpoint's server instructions, which Claude Code reads, spell out the flow: `list_workspaces`, match `repositoryPath` against the repository (its main checkout, from a linked worktree), `register_workspace` if nothing matches, then `queue_run`. So in a repository that isn't registered, "queue a job to …" registers it first, and "queue a job from this branch" passes the branch the agent is on as `baseBranch`.

See AGENTS.md's "MCP Boundary" for the design rules behind both.

## Remote control

The optional Telegram bot lets you check on and steer live sessions from your phone. It is experimental and largely untested outside the test suite. See [telegram.md](./telegram.md).

## The sandbox

`bin/sandbox` runs this checkout's code as a complete, isolated instance, useful both for trying the orchestrator out and for testing changes to it:

```sh
bin/sandbox start [--real-herdr] [--telegram]   # boot tmp/sandbox, seed a scratch workspace, print its URL
bin/sandbox status
bin/sandbox stop
bin/sandbox reset                               # stop and delete tmp/sandbox
bin/sandbox verify [--keep]                     # boot a fresh instance and drive a run through it end to end
```

It runs real Puma and Solid Queue with the real recurring schedule on a free `127.0.0.1` port, with its own SQLite files, pid and log under `tmp/sandbox/`, beside a **fake herdr** whose "agents" are scripted processes that never call a model. Put a `[fake-agent: done|blocked|failed|dirty|crash|manual|working]` directive in a task to choose what the fake agent does (default `done`). While `PANEYARD_SANDBOX=1`, `Orchestrator::Sandbox` refuses your real herdr socket, remote-control credentials, and any repository or process outside the sandbox. Its scratch repository has a second branch, `feature/sandbox`, to queue a run from something other than `main`. It never touches `storage/production*.sqlite3`, `tmp/pids/production.pid` or the production port.

Two opt-ins bring real integrations back, one at a time:

- `--real-herdr` opens the sandbox's runs in your own herdr (workspaces labelled `[sandbox] ...`) running the real agent CLI, which **spends real model usage**, on throwaway tasks in the scratch repository.
- `--telegram` makes the sandbox poll and answer Telegram as a **second bot**. Give it its own token and your user id in `SANDBOX_TELEGRAM_BOT_TOKEN` / `SANDBOX_TELEGRAM_ALLOWED_USER_IDS` (in the environment or `~/.config/paneyard/sandbox.env`). Never reuse your main instance's bot: Telegram hands each message to one poller, so two instances sharing a bot split your messages.
