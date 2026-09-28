# Workflow Orchestrator

Queue a job against a workspace. When a slot frees, it gets its own git worktree and one live `claude`/`codex`/`opencode` session you can watch and talk to, which does the work end to end and leaves its changes for you to try, committing, pushing or merging only when you ask. Runs, sessions, checkpoints, and artifacts all stay scoped to their workspace.

Rails schedules; it does not orchestrate. It decides when a run starts, gives it a worktree, and reclaims that worktree afterwards. Everything in between belongs to the session. There is no planner, no step queue, and no pull-request publishing: when you ask, the session commits and pushes its branch or merges it into `main`, and opening and merging a PR is up to you.

This README is for **operators** (running the orchestrator and pointing it at repositories). If you are changing the orchestrator's own code, read [AGENTS.md](./AGENTS.md). It is the source of truth for structure, conventions, and testing.

## What the machine needs

| Tool | Needed for | Notes |
| --- | --- | --- |
| Ruby + Bundler, SQLite | Rails itself | `bin/setup` installs gems and prepares the database. |
| `git` | every run | Worktrees are made with `git worktree add` (`Orchestrator::GitWorktree`). |
| [herdr](https://herdr.dev), running | every run | Owns every pane and process. Rails talks to its socket at `~/.config/herdr/herdr.sock` (override with `HERDR_SOCKET_PATH`) through `Orchestrator::Runner::Herdr`. If herdr isn't up, the run fails at launch. |
| `claude`, `codex`, and/or `opencode` | whichever driver a run uses | Must be on the `PATH` of the **shell a herdr pane opens** (your login shell), and already signed in, because the session starts non-interactively and can't complete a login flow. Rails doesn't check for them before launching: a missing CLI shows up as a run that fails with "never became ready". Default models are in `Orchestrator::DefaultModels` (`opus`, `gpt-5.6-terra`, `9router/oc/deepseek-v4-flash-free`); override with `WORKFLOW_CLAUDE_MODEL` / `WORKFLOW_CODEX_MODEL` / `WORKFLOW_OPENCODE_MODEL` or per run in the UI. The opencode default assumes a provider you may not have configured. |
| `nvim` | optional | By default each run's herdr workspace opens with `nvim` in a split to the right of the agent. If `nvim` isn't on the Rails process's `PATH`, the default layout opens only the agent pane. A workspace can set its own layout instead (see "Workspace layouts" below). |
| `gh`, signed in | pushing, unless you use SSH or a GitHub App | `Orchestrator::Runner::ProcessEnv` uses `gh auth token` for the session's credentials and installs `gh auth git-credential` as git's credential helper. See [GitHub access](#4-github-access). |
| `curl` | GitHub App only | `Orchestrator::GitHubAppAuth` calls the GitHub API with it. |

## Running the orchestrator

```sh
bin/setup --skip-server
PORT=3000 bin/dev
```

`bin/dev` starts Puma and Solid Queue together. Before starting either one, it checks the bundle and pending migrations and exits with a recovery command if something is missing. **Always pass `PORT` explicitly when you want runs to work.** Without it, `bin/dev` gives Puma a random free port, but the Solid Queue process still thinks the app is on 3000. Solid Queue is what launches sessions, so it would point each session's MCP server at the wrong URL, and the session could never call `report_idle`. (`SessionArgs.rails_mcp_url` uses `WORKFLOW_RAILS_URL`, falling back to `http://127.0.0.1:$PORT`.) If you set `WORKFLOW_RAILS_URL`, keep it in step with `PORT`:

```sh
PORT=3300 WORKFLOW_RAILS_URL=http://127.0.0.1:3300 bin/dev
```

For the long-running, detached instance, use `bin/service start|stop|restart|status`. It wraps `bin/production`, defaults to port `3001`, and logs to `log/production_service.log`. AGENTS.md covers when you need a restart.

The health endpoint `/up` returns `{"status":"ok","service":"workflow-orchestrator"}` with an `X-Workflow-Service: workflow-orchestrator` header, so you can't mistake it for a target Rails app's own `/up`.

## Preparing a repository

Follow these steps once for each repository you want to run jobs against. Every rule below comes from the code named next to it.

### 1. Directory layout

A Workspace has a `root_path`: a plain directory that you own and that holds the repository's checkouts. The source checkout **must** be a direct child of it named `main` (`Workspace#source_root` is `<root_path>/main`). Each run's worktree is created as a sibling of that checkout:

```
~/Source/my-app/                  <- root_path (what you register)
├── main/                         <- source checkout, on branch main
├── add-cart-total-1a2b/          <- run worktree, branch workflow/add-cart-total-1a2b
└── fix-tax-rounding-9f3c/        <- run worktree, branch workflow/fix-tax-rounding-9f3c
```

Setting that up for a repo you already have on GitHub:

```sh
mkdir -p ~/Source/my-app
git clone git@github.com:you/my-app.git ~/Source/my-app/main
```

Worktree and branch names are a slug of the task plus a short run-id suffix (`GitWorktree.name_for`). Keep everything else out of `root_path`. Launching a run fails if its worktree path already exists.

### 2. Git requirements

Before creating a worktree, `GitWorktree.validate_source!` checks all of these, and fails the run if any one is untrue:

- `<root_path>/main` exists and is a git work tree.
- Its directory is named `main`, **and it has the `main` branch checked out**. A repo whose default branch is `master` or anything else needs a local `main` branch. The simplest fix is to rename the default branch.
- It has an `origin` remote. When asked to push, the session is told to use `git push -u origin workflow/<name>` (`Orchestrator::RunPrompt`), so `origin` must be a remote this machine can push to.

Each run branches from the source checkout's **current local `HEAD`**. Rails never fetches or pulls, so keep `<root_path>/main` up to date yourself (`git -C ~/Source/my-app/main pull`). Uncommitted changes in `main` are not carried into a run's worktree.

For the cleanup side, `Orchestrator::WorktreeJanitor` removes a worktree (never its branch) on **Close session** and on a ten-minute sweep (`WorktreeCleanupJob`, `config/recurring.yml`). It removes one only when all of these hold:

- the run's session is over;
- `git status --porcelain` is empty in the worktree;
- `HEAD` is either an ancestor of the local `main` branch (`git merge-base --is-ancestor HEAD main`) or contained in some remote-tracking branch (`git branch --remotes --contains HEAD`).

So removal depends on the local `main` ref and on remote-tracking refs. A plain `git push -u origin ...` updates `refs/remotes/origin/...`, which is enough. Anything else stays on disk indefinitely and is flagged as a **kept worktree** on the runs list and run screen, where **Remove worktree** removes it by hand. The janitor never touches a worktree named `main`.

The sweep covers **every** worktree of the source repository, not only the ones Rails created. A worktree you made by hand with no matching run is treated as an orphan and removed once it is clean and pushed or merged, and its branch is kept. Don't keep your own worktrees of a registered repo if you expect them to stay.

### 3. What a run starts with inside the repo

A worktree is a fresh checkout of committed files only. Anything untracked or gitignored in `main` (`.env`, `config/master.key`, `node_modules`, a local database) is **not** there. Rails runs no setup commands and never infers a language, package manager, or ports. The session works those out itself each run. That puts the burden on the repository:

- **`AGENTS.md` / `CLAUDE.md` in the target repo** are how you tell a session how to set up, build, and test. Sessions start in the worktree and read the repo's own instruction files the way they would if you ran the CLI there yourself. `claude` is deliberately launched without `--setting-sources` so it loads the repo's `CLAUDE.md` and `.claude/` settings. It does get `--strict-mcp-config`, so any `.mcp.json` in the repo is ignored in favour of the workflow MCP server (`SessionArgs.claude_args`). `codex` and `opencode` read `AGENTS.md`.
- **Tests.** The run prompt (`Orchestrator::RunPrompt`) does not tell the session to run tests. It tells the session to leave its changes uncommitted until asked, and asks for a `report_idle` summary that includes "how it was verified". If a repo needs particular verification, put the commands in its `AGENTS.md`/`CLAUDE.md`, or in the task text.
- **Environment variables.** A session can call the `record_workspace_env_var` MCP tool to save a workaround (for example a bundler path). The value is stored as a `WorkspaceEnvVar` on the workspace and set in every later session's pane environment (`Orchestrator::WorkspaceEnvVars`, merged first in `Runner::ProcessEnv.for_session`, so it can't override anything the orchestrator sets). Values are literal and must not contain `$` or a backtick, because they are never shell-expanded. They are stored in plaintext in the orchestrator's database, so don't use them for secrets. There is no UI for them. To inspect them or seed them yourself, use the console:

  ```sh
  bin/rails runner 'w = Workspace.find_by!(name: "my-app"); pp w.workspace_env_vars.pluck(:name, :value)'
  bin/rails runner 'Workspace.find_by!(name: "my-app").workspace_env_vars.create!(name: "FOO", value: "/abs/path", evidence_ref: "operator", recorded_by: "operator")'
  ```

  (With `bin/service`, prefix those commands with `RAILS_ENV=production`.)
- **Environment Rails removes.** `Runner::ProcessEnv` unsets the orchestrator's own Bundler activation (`BUNDLE_GEMFILE`, `RUBYOPT`, …), `RAILS_ENV`, and nested-Claude-Code markers, so the target repo resolves its own `Gemfile.lock` and picks its own Rails env.
- Every session runs with full access to its worktree (`--permission-mode bypassPermissions`, `-s danger-full-access`, `--auto`). The review gate is you trying the session's changes before you ask it to commit.

### 4. GitHub access

Rails itself opens no pull requests and makes no GitHub API calls about your repo. The only GitHub call it makes is to mint an App token, below. What needs credentials is the session's `git push`. The session's credentials are picked (`RunSessionRunner.session_spec`, then `Runner::ProcessEnv`) in this order:

1. **GitHub App configured** (`GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY`, or `github_app:` in credentials; see [GITHUB_APP_SETUP.md](./GITHUB_APP_SETUP.md)): Rails asks the runner for the worktree's `remote.origin.url`, finds the App installation whose account matches the repo's **owner**, and mints an installation token. The session gets it as `GH_TOKEN`, with `gh auth git-credential` as a git credential helper.
2. **No App, or minting fails** (App not installed on that owner, a non-GitHub `origin`, an API error): it falls back to `gh auth token` on the runner's machine, which is your own `gh` login.
3. **Neither is available**: the session gets no injected credentials and pushes with whatever your login shell already has.

What that means in practice:

- **You don't need a GitHub App at all** if you're happy for sessions to push as you. Being signed in to `gh` (`gh auth login`) is enough for an HTTPS `origin`.
- **With an SSH `origin`** (`git@github.com:...`), `git push` goes over SSH and never uses the token or credential helper. Pushing then depends only on your SSH key being usable from a herdr pane (for example through ssh-agent), with or without a GitHub App. `gh` inside the session still uses `GH_TOKEN`.
- **If you do use the App**, its installation must cover this repository with **Contents: Read & write**. **Pull requests: Read & write** is only needed if you'll ask sessions to run `gh pr create`. Rails matches the installation by owner only. If the owner has the App installed but this repo isn't among its selected repositories, a token is still minted and the push fails with 403. Add the repo under the installation's **Configure** page.
- Tokens are fixed when a session starts and cached for 55 minutes. A long-lived session can find its token expired. Also, the cache key is per App, not per installation: if you run repos under two different owners through one App, a session can be handed the other owner's cached token and fail to push until it expires.

### 5. Register the workspace

- **Web UI**: open the orchestrator (`http://127.0.0.1:<PORT>/`), choose **Add workspace**, and enter a **Name** (unique; it's what `queue_run` and the other MCP tools take as `workspace`) and the **Workspace root**. The root is `root_path`, the parent directory (`~/Source/my-app`), **not** `.../main`. Registration doesn't validate the checkout; that happens when the first run launches. You can edit the root later, except while the workspace has an active run. The name can't be changed.
- **Console**, the only other way:

  ```sh
  bin/rails runner 'Workspace.create!(name: "my-app", root_path: File.expand_path("~/Source/my-app"))'
  ```

  There is no MCP tool for creating workspaces. `list_workspaces` only reads them.

### 6. First run

From the workspace's runs page, choose a new run, give it a task, and pick a driver (and optionally a model). Or queue it over MCP (below). Within a few seconds `RunDispatchJob` claims it, and a herdr workspace named after the worktree opens with the agent on the left and `nvim` on the right, or with whatever tabs and panes that workspace's layout defines. If it fails, the run screen shows the launch error. The common ones map back to the steps above: "Source checkout must be on main", "has no origin remote", "Worktree path already exists", herdr unreachable, or a CLI that never became ready.

### Workspace layouts

Each workspace's new and edit forms have a **Layout** editor: the herdr tabs and panes its runs open with. Name each tab. Add panes, give each a command, and pick which earlier pane it splits off, to the right or below, and how much of the space that pane keeps. A live sketch of each tab shows the result. Until you change anything, the workspace uses the default layout (the agent with `nvim .` split beside it), and **Reset to default** goes back to it. The layout is stored as YAML (`workspaces.layout`), in this shape:

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

Have as many tabs as you like, each with as many splits as you like. The agent pane is the only one that is required, and it is always the first pane of the first tab, which is the tab a run opens on. Every other pane is split off an earlier pane in its own tab, `right` or `down`; `ratio` is the share the pane being split keeps. A `command` is typed into the pane's own shell in the run's worktree, and every pane gets the same environment as the agent (`GH_TOKEN`, `WORKFLOW_RUN_ID`, the workspace's recorded env vars). A pane with no command is a plain shell. The panes are only set up when the session starts. Rails never watches or restarts them, and Close session, or the agent pane going away, closes all of them. See `docs/workspace-layouts.md` for the design.

It worked when the session calls `report_idle` and the run screen shows its checkpoint. Ask it to commit and push, and `git -C ~/Source/my-app/main ls-remote origin 'workflow/*'` then lists the branch.

## How a run works

1. **Queue it.** Creating a run starts nothing. It waits for a slot. The cap is global across every workspace: `WORKFLOW_MAX_CONCURRENT_RUNS`, default 4.
2. **Dispatch.** `RunDispatchJob` claims the oldest queued run. `StartRunSessionJob` provisions its worktree and opens one interactive session in a herdr pane rooted there, with the task as its first prompt.
3. **Work.** The session owns the job. It explores, edits, and runs the repo's own commands, then leaves its changes uncommitted for you to try. Ask it to commit, push, or merge into `main` when you're happy. Watch it in your herdr client, or send it a message from the run screen.
4. **Report.** The session calls the `report_idle` MCP tool (`done`, `blocked`, or `failed`) each time it stops working. This does not end the run: the pane stays open and the slot stays held. Each report is a checkpoint covering the interval since the last one, written as a full Markdown report, and the run screen lists them in order.
5. **Decide.** Read the reports, then either send more work or **Close session**, which quits the CLI, closes the herdr workspace, and frees the slot. An unreviewed run keeps holding its slot, so it blocks the queue. PRs are yours to open from a pushed branch.
6. **Clean up.** `WorktreeJanitor` removes the worktree on Close session if its work is saved (see [Git requirements](#2-git-requirements)), and otherwise keeps it and flags it until you push, merge, or remove it.

If a session dies without reporting (pane closed, CLI crashed), `RunSessionReconcileJob` notices within about 30 seconds and frees the slot.

## MCP endpoints

- **`/mcp/run`** is what each session talks to, authenticated by a per-session bearer token that dies with the session. It has `report_idle`, `record_workspace_env_var`, and the shared tools below. Rails wires it into each CLI automatically, so you don't configure anything.
- **`/mcp/admin`** is unauthenticated (Puma binds `127.0.0.1` only) and lets your own MCP clients queue and inspect runs without the web UI. Its tools are `queue_run` (task, optional `workspace` name and `driver`), `list_runs`, `get_run`, `list_workspaces` (each workspace's name, source checkout path, active-run count, and which one is the default when `workspace` is omitted), and `ping_tool`. For example, to add it to Claude Code:

  ```sh
  claude mcp add --transport http workflow-admin http://127.0.0.1:3001/mcp/admin
  ```

See AGENTS.md's "MCP Boundary" for the design rules behind both.

## Telegram remote control

The optional Telegram bot lets you check on and steer your live run sessions from your phone. It answers only the Telegram user IDs configured below, and only in your private chat with the bot, never in a group.

Add these values to Rails credentials (or set equivalent environment variables):

```yaml
telegram:
  bot_token: "<BotFather token>"
  allowed_user_ids:
    - "<your numeric Telegram user id>"
```

The app polls Telegram every five seconds, so it only needs outbound internet access; it does not need a public URL. Telegram's [`getUpdates`](https://core.telegram.org/bots/api#getupdates) polling API doesn't work while a webhook is configured, so if this bot ever had one, clear it once:

```sh
bin/rails runner 'Telegram::Client.new.delete_webhook'
```

Commands:

| Command | What it does |
| --- | --- |
| `/panes` | Every live session: its run, workspace, what herdr says it is doing, and its last report. |
| `/idle` | Only the live sessions that aren't working: idle, finished, blocked at a prompt, or reported idle. |
| `/pane <run>` | Where that session stands. If it has reported (`report_idle`) and hasn't gone back to work since, you get that recap. Otherwise you get its live pane, and the message updates itself every few seconds for 3 minutes. If the session reports during that time, the message says so and the recap follows. |
| `/screen <run> [lines]` | The raw newest lines of the pane, once (default 40, up to 200). |
| `/report <run>` | That run's newest recap, rendered as Markdown. This also works after the session is closed. |
| `/send <run> <text>` | Types `<text>` into the session as live input, exactly like the run screen's message box. |

`<run>` is the run id's last four characters (the lists print `/pane_33bd` and `/screen_33bd`, which you can tap), a prefix of the worktree name, or the full run id. Every message the bot sends about a run starts with `run <id> ·`, and **replying to one of those messages sends your reply to that run**.

Session status comes from herdr and is refreshed every 30 seconds, so it can lag by up to that much.

Be aware of what this exposes. Anyone on the allow-list can type into sessions that have full access to their worktrees, which amounts to a shell on this machine. Pane text and checkpoints also pass through Telegram's servers, and bot chats aren't end-to-end encrypted, so anything a session prints can end up there.

## Verification

```sh
bundle exec rspec
bin/rubocop
git diff --check
```

`bin/ci` also runs dependency, importmap, and Brakeman audits.
