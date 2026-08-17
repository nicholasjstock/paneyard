# Workflow Orchestrator

Queue a job against a workspace. When a slot frees, it gets its own git worktree and one live `claude`/`codex`/`opencode` session you can watch and talk to, which does the work end to end and opens a pull request. Runs, sessions, events, artifacts, and operator chat all stay scoped to their workspace.

## Local setup

```sh
bin/setup --skip-server
bin/dev
```

`bin/dev` starts Puma and Solid Queue together. Before starting either process it checks the bundle, pending migrations, and the configured `PORT` (default `3000`). It exits with a recovery command instead of starting a partially functional orchestrator.

If startup reports incomplete dependencies or an unprepared database, run:

```sh
bin/setup --skip-server
```

If the port is occupied, stop the owning service or choose an explicit orchestrator port:

```sh
PORT=3300 WORKFLOW_RAILS_URL=http://127.0.0.1:3300 bin/dev
```

For the detached production-like service, use `bin/service start`; it defaults to port `3001` and also accepts an explicit `PORT` override.

The health endpoint returns `{"status":"ok","service":"workflow-orchestrator"}` and the `X-Workflow-Service: workflow-orchestrator` header, so it cannot be mistaken for a target Rails application merely because both expose `/up`.

## Verification

```sh
bundle exec rspec
bin/rubocop
git diff --check
```

`bin/ci` additionally runs dependency, importmap, and Brakeman audits.

## How a run works

1. **Queue it.** Creating a run starts nothing; it waits for a slot. The cap is global across every workspace — `WORKFLOW_MAX_CONCURRENT_RUNS`, default 2.
2. **Dispatch.** `RunDispatchJob` claims the oldest queued run, provisions a sibling git worktree of the workspace's `main` checkout on a `workflow/<name>` branch, and opens one interactive session in a [herdr](https://herdr.dev) pane rooted there, with the task as its first prompt.
3. **Work.** The session owns the job: it explores, edits, runs the repo's own commands, commits, and pushes. It runs with full access to its worktree — the safety net is your review of the resulting PR. Watch it in your herdr client, or send it a message from the run screen.
4. **Finish.** The session calls the `run_done` MCP tool. On `done`, Rails pushes the branch if it hasn't been pushed and opens a pull request using the `run-summary.md` the session wrote as the body.
5. **Merge.** When you merge the PR, Rails removes the worktree and fast-forwards `main`. A run that ended any other way has its worktree reclaimed later by `WorktreeCleanupJob`, which never removes one with uncommitted changes.

A comment on the pull request is delivered straight into the run's session — reopening a closed one on the same worktree if needed — so review feedback continues the run rather than starting a new one.

Rails never infers a workspace's language, package manager, dependency layout, ports, or health endpoints. The first run in a new workspace is a discovery run that records those for every later run to inherit.

## Requirements

Beyond the Rails app itself, this expects [herdr](https://herdr.dev) running with its socket at `~/.config/herdr/herdr.sock` (override with `HERDR_SOCKET_PATH`), the `gh` CLI, and whichever of `claude`, `codex`, or `opencode` you point runs at.

## Telegram admin chat

The optional Telegram bot fronts the existing workspace admin chats. It is restricted to the Telegram user IDs configured below; it does not accept messages from anyone else.

Add these values to Rails credentials (or set equivalent environment variables):

```yaml
telegram:
  bot_token: "<BotFather token>"
  allowed_user_ids:
    - "<your numeric Telegram user id>"
```

The app polls Telegram every five seconds, so it only needs outbound internet access; it does not need a public URL. If this bot previously had a webhook, clear it once so Telegram resumes making updates available to polling:

```sh
bin/rails runner 'Telegram::Client.new.delete_webhook'
```

In Telegram, send `/workspaces`, select a workspace, and then chat normally. `/stop` cancels that workspace's current admin-chat turn. Telegram's [`getUpdates`](https://core.telegram.org/bots/api#getupdates) polling API cannot be used while a webhook is configured.
