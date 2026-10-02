# Contributing

Thanks for your interest in Paneyard. This guide covers what you need to make a change and get it merged. [AGENTS.md](./AGENTS.md) is the detailed architecture and conventions guide. It is written for AI coding agents working on this repository (the orchestrator is often used to develop itself), but it is the authoritative reference for humans too; this file summarises it and links into it.

Please read the README's [security model](./README.md#security-model) first. This is a single-operator local tool with no authentication by design. Changes that add multi-user features, hosted deployment or an auth layer are a much bigger conversation, so open an issue before starting one.

For security vulnerabilities, follow [SECURITY.md](./SECURITY.md) instead of opening a public issue.

## Setting up

You need the [requirements in the README](./README.md#requirements) and a clone of this repository (the README's [Running without the plugin](./README.md#running-without-the-plugin)), except that herdr and the agent CLIs are **not** needed to run the test suite: the suite uses a fake herdr and a fake agent. The JavaScript system specs (`js: true`) drive headless Chrome through Selenium, so they need Google Chrome installed.

```sh
bin/setup                 # install gems, prepare the development database (--reset to recreate it)
bundle exec rspec         # run the specs
bin/sandbox start         # an isolated instance with a fake herdr and fake agent, to click through
```

`bin/setup` does not start a server. Development and test use their own SQLite databases under `storage/`, separate from the `storage/production.sqlite3` that `bin/service` uses. Run `bin/rails db:prepare` after a schema change, and `bin/rails console` to poke at the development data.

## Trying a change in the sandbox

Use `bin/sandbox` rather than `bin/dev` to try a change by hand:

```sh
bin/sandbox start     # prints the sandbox's URL and its /mcp/admin URL
bin/sandbox stop      # or: bin/sandbox reset, to delete it too
```

The sandbox is a complete, isolated instance of this checkout on a free loopback port, with its own database under `tmp/sandbox/`, a **fake herdr** and a **fake agent**: no real panes open, no model usage is spent, and nothing outside the sandbox is touched. It seeds a scratch repository as its only workspace. Open the URL, choose **Queue a task**, and include a directive such as `[fake-agent: done]` (or `blocked`, `failed`, `dirty`, `crash`, `manual`, `working`) in the task to choose what the fake agent does. You get the whole lifecycle — dispatch, a real worktree, a report, **Close session**, cleanup — without herdr or an agent CLI.

To drive it from Claude Code, register the `mcp admin` URL that `bin/sandbox start` printed, under a name that won't clash with your real instance's:

```sh
claude mcp add --transport http paneyard-sandbox http://127.0.0.1:<port>/mcp/admin
```

Without `-s user` this registers it for the current project only. The sandbox picks a new port each time it starts, so update the URL after a restart (`claude mcp remove paneyard-sandbox`, then add it again).

`bin/dev`, by contrast, runs the real recurring schedule against your real herdr socket and any configured Telegram bot. The sandbox refuses everything outside itself; [The sandbox](./docs/operating.md#the-sandbox) in operating.md covers its guards, `bin/sandbox status` and `verify`, and its opt-ins for real herdr (`--real-herdr`) and Telegram (`--telegram`).

## Running it in development

`bin/dev` runs the app in the foreground in development mode:

```sh
PORT=3000 bin/dev
```

It starts Puma and the Solid Queue worker together (the worker is what launches sessions), listening on `localhost` only. Before starting either, it checks the bundle and pending migrations and exits with a recovery command if something is missing. Without `PORT` it picks a free port and prints it. Sessions reach the app's MCP endpoint at `PANEYARD_RAILS_URL`, falling back to `http://127.0.0.1:$PORT`; if you set it, keep it in step with `PORT`. An MCP client registered against `/mcp/admin` needs the port `bin/dev` printed, not `bin/service`'s 7263. More in [operating.md](./docs/operating.md#development-bindev).

`bin/dev` is not isolated: it runs the full recurring schedule (dispatch, reconcile, Telegram polling if configured, the worktree janitor) against whatever herdr socket your shell has. A run session working on this repository must use `bin/sandbox` instead.

## Working on the herdr plugin

The plugin (`herdr-plugin.toml`, `bin/herdr-plugin`, `lib/paneyard_plugin/`) packages this app; [docs/herdr-plugin-plan.md](./docs/herdr-plugin-plan.md) has the design. Its Ruby is standard library only and runs without Bundler or Rails. Specs are under `spec/lib/paneyard_plugin/`; the daemon spec starts real processes standing in for `bin/production`.

To try it in your own herdr, link your checkout:

```sh
herdr plugin link .                        # no build step: it uses the bundle bin/setup installed
herdr plugin action list --plugin paneyard
herdr plugin action invoke runs --plugin paneyard
herdr plugin log list --plugin paneyard    # each action's stdout/stderr
herdr plugin action invoke stop --plugin paneyard && herdr plugin unlink paneyard
```

A linked checkout runs your working tree's code as of the daemon's last start (run the plugin's `restart` action to pick up a change, or iterate with `bin/dev` or `bin/sandbox`), but its state is the real plugin state directory, `~/.local/state/herdr/plugins/paneyard`, and its sessions open in your real herdr. If you also run `bin/service`, don't register the same repositories in both (see the README's "one Paneyard per machine"). To exercise the daemon without herdr, point it at scratch directories and a herdr socket that does not exist:

```sh
HERDR_PLUGIN_STATE_DIR=tmp/plugin/state HERDR_PLUGIN_CONFIG_DIR=tmp/plugin/config \
  HERDR_SOCKET_PATH=/tmp/no-herdr.sock bin/herdr-plugin start   # also: status, stop, queue-ui, runs-ui
```

`herdr plugin install` runs `bin/herdr-plugin build`, which writes `.bundle/config` (gems in `vendor/bundle`, without the development and test groups). Never run it in a development checkout; try it on a copy.

## Code layout

It is a Rails 8 app organised around `Workspace` as the top-level boundary: runs, sessions and their reports are nested under a workspace in code and in the UI. See AGENTS.md's ["Project Structure"](./AGENTS.md#project-structure--module-organization) for more.

| Path | What lives there |
| --- | --- |
| `app/controllers` | The JSON health endpoint. |
| `app/models` | Persistence: `Workspace`, `Run`, `RunSession`, `RunCheckpoint`, … |
| `app/jobs` | Solid Queue jobs: dispatch, starting a session, reconcile, worktree cleanup, Telegram polling. |
| `app/services/orchestrator` | Orchestration logic: run and session state, base branches, prompts, concurrency, layouts, and the two MCP endpoints (mounted in `config/routes.rb`). |
| `app/services/orchestrator/runner` | Everything that touches the machine: herdr, agent CLIs, git worktrees, processes (see [the runner boundary](#design-rules)). |
| `app/services/mcp_tools` | The MCP tools behind `/mcp/run` and `/mcp/admin`. |
| `app/services/remote_control` | Telegram remote control and its adapter interface. |
| `db/` | Schema and migrations. |
| `lib/fake_herdr`, `lib/fake_telegram`, `script/fake_agent` | Test doubles that speak the real protocols. |
| `lib/paneyard_sandbox`, `bin/sandbox`, `bin/preflight` | The isolated sandbox instance and the production boot smoke test. |
| `herdr-plugin.toml`, `bin/herdr-plugin`, `lib/paneyard_plugin` | The herdr plugin: its manifest, entry point, daemon and popups. |
| `demo/` | The Docker-recorded demo behind the README GIF; see [docs/demo-recording-plan.md](./docs/demo-recording-plan.md). |

## Verifying a change

```sh
bin/verify
```

`bin/verify` is the one command that must pass before a change is merged (about a minute). `bin/verify --prod-copy` does the same, but has `bin/preflight` migrate a read-only copy of the main checkout's `storage/production.sqlite3` rather than a scratch database. It runs:

| Step | What it checks |
| --- | --- |
| `bundle exec rspec` | Unit, service, job, request, system and in-process integration specs. |
| `bin/rubocop` | Style (Rails Omakase, `.rubocop.yml`). |
| `git diff --check` | Whitespace errors. |
| `bin/preflight` | Boots this checkout as production would, on a scratch database and a free port: eager loading, routes, `config/queue.yml`, the recurring schedule, migrations, and Puma plus Solid Queue actually serving requests. |
| `bin/sandbox verify` | Boots a fresh isolated instance and drives a whole run lifecycle through it over real HTTP. |
| `bin/bundler-audit`, `bin/brakeman` | Known-vulnerable gems and Rails static security analysis. |

The test layers, and where a change belongs (details in AGENTS.md, ["Testing Guidelines"](./AGENTS.md#testing-guidelines)):

- **Boundary** (`spec/boundary_spec.rb`): fails if anything outside `Orchestrator::Runner` runs commands, shells out to git, signals processes, touches the filesystem or talks to herdr.
- **Unit, service, job and request specs** (`spec/services`, `spec/jobs`, `spec/requests`): one behaviour each, with `Orchestrator::Runner::Herdr` stubbed call by call. Never open a live herdr socket from a spec; `spec/spec_helper.rb` points `HERDR_SOCKET_PATH` at a socket that doesn't exist so a forgotten stub fails loudly.
- **Real git** where git behaviour is what's under test (see `spec/services/orchestrator/worktree_janitor_spec.rb`).
- **Fake herdr** (`lib/fake_herdr/`, tag an example `:fake_herdr`) and **fake Telegram** (`lib/fake_telegram/`, tag `:fake_telegram`): real sockets and processes, no model usage. If you teach `Orchestrator::Runner::Herdr` a new call, extend the fake and its spec together.
- **Lifecycle** (`spec/integration/run_lifecycle_spec.rb`): a run end to end in process. Changes to run or session state belong here as well as in a unit spec.
- **System specs** (`spec/system`): UI behaviour.
- **Live agent specs** (tagged `live_agent`): drive the real CLIs with real model usage. They are excluded unless you set `LIVE_AGENT_SPECS=1`.

Don't consume live model capacity to test dispatch or argument building.

### CI

[`.github/workflows/ci.yml`](./.github/workflows/ci.yml) runs `bin/verify` on every push and on pull requests from forks, on both `ubuntu-latest` and `macos-latest` (the app has only been used on macOS; Linux keeps it honest). Nothing in CI reaches a real herdr, a model, Telegram or GitHub's API, and no secrets are passed in. It does not run `bin/verify --prod-copy`, `bin/preflight`'s credentials check (it needs `config/master.key`, so it is skipped and a throwaway `SECRET_KEY_BASE` used), or the live agent specs. On failure it uploads the logs as an artifact.

## Style

- Run `bin/rubocop` (Rails Omakase). Two-space indentation, `CamelCase` classes, `snake_case` files, Rails naming (`*_controller.rb`, `*_job.rb`, service objects under `app/services/...`).
- Match the comment density and idiom of the surrounding code. Comments here tend to explain *why*, including what was verified live against herdr or an agent CLI.

## Design rules

These are deliberate, and a change that breaks one will be asked to change. The reasoning is in AGENTS.md.

- **Sessions, not orchestration.** Rails decides which job runs, where, and what happens to its worktree afterwards. Everything else belongs to the one interactive agent session. Don't add a planner, step queue, per-step workers, acceptance criteria, PR publishing or merge polling; these existed once and were removed on purpose. Steering a run means talking to its session (`Orchestrator::RunSessionRunner.prompt!`). See ["Sessions, Not Orchestration"](./AGENTS.md#sessions-not-orchestration).
- **The runner boundary.** Everything that must happen on the machine hosting herdr, the agent CLIs and the git checkouts lives under `app/services/orchestrator/runner/`, and the rest of the app reaches it only through `Orchestrator::Runner.for(workspace)`. Only plain data crosses (strings, numbers, booleans, hashes and arrays of them); the runner never reads the database. If the orchestrator needs something new from the machine, add a runner method. `spec/boundary_spec.rb` enforces this. See ["Orchestrator and runner"](./AGENTS.md#orchestrator-and-runner).
- **Workspace-first.** Scope routes, screens, jobs and persistence by workspace first, for example `/workspaces/:workspace_id/runs/:id`. Avoid new top-level flows that bypass workspace selection unless the feature is truly global. See ["Workspace-First Design"](./AGENTS.md#workspace-first-design).
- **A small MCP surface.** Don't add MCP tools for things an agent CLI can already do itself (files, commands, git), and never expose SQL, record lookup, filesystem traversal or command execution. See ["MCP Boundary"](./AGENTS.md#mcp-boundary).
- **Sandbox guards.** A new way for the app to reach outside itself belongs in the runner, with a guard in `Orchestrator::Sandbox` and `spec/services/orchestrator/sandbox_spec.rb`.
- **Verified CLI flags.** The per-driver flags in `Orchestrator::Runner::SessionArgs` were established by running each CLI live; several contradict its `--help`. Don't simplify them without re-verifying live.

## Commits and pull requests

- Keep commits focused, with short, imperative summaries, for example `Flatten ops/ into the repo root` or `Retry the unsent-prompt Enter with backoff before giving up`.
- A pull request should state the problem, the approach, any schema or job-queue impact (migrations, `config/queue.yml`, `config/recurring.yml`), and how you verified it, including whether `bin/verify` passed. The [pull request template](./.github/pull_request_template.md) asks for exactly that. Link related issues, and include screenshots for UI changes.
- Say if the change needs a running instance restarted to take effect (anything in `config/queue.yml`, `config/recurring.yml`, credentials, `bin/production`/`bin/service`, or an initializer).
- Add an entry under "Unreleased" in [CHANGELOG.md](./CHANGELOG.md) for user-visible changes.
- Never commit decrypted credentials, `config/master.key`, database files or logs containing run data.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](./LICENSE).
