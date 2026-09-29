# Contributing

Thanks for your interest in Workflow Orchestrator. This guide covers what you need to make a change and get it merged. [AGENTS.md](./AGENTS.md) is the detailed architecture and conventions guide. It is written for AI coding agents working on this repository (the orchestrator is often used to develop itself), but it is the authoritative reference for humans too; this file summarises it and links into it.

Please read the README's [security model](./README.md#security-model) first. This is a single-operator local tool with no authentication by design. Changes that add multi-user features, hosted deployment or an auth layer are a much bigger conversation, so open an issue before starting one.

For security vulnerabilities, follow [SECURITY.md](./SECURITY.md) instead of opening a public issue.

## Setting up

You need the [requirements in the README](./README.md#requirements), except that herdr and the agent CLIs are **not** needed to run the test suite: the suite uses a fake herdr and a fake agent. The JavaScript system specs (`js: true`) drive headless Chrome through Selenium, so they need Google Chrome installed.

```sh
bin/setup                 # install gems, prepare the development database
bundle exec rspec         # run the specs
bin/sandbox start         # an isolated instance with a fake herdr and fake agent, to click through
```

Use `bin/sandbox` rather than `bin/dev` to try a change by hand. `bin/dev` runs the real recurring schedule against your real herdr socket and any configured Telegram bot. The sandbox runs on its own port, database and scratch repository and refuses everything outside itself; see [operating.md](./docs/operating.md#the-sandbox).

## Verifying a change

```sh
bin/verify
```

`bin/verify` is the one command that must pass before a change is merged (about a minute). It runs:

| Step | What it checks |
| --- | --- |
| `bundle exec rspec` | Unit, service, job, request, system and in-process integration specs. |
| `bin/rubocop` | Style (Rails Omakase, `.rubocop.yml`). |
| `git diff --check` | Whitespace errors. |
| `bin/preflight` | Boots this checkout as production would, on a scratch database and a free port: eager loading, routes, `config/queue.yml`, the recurring schedule, migrations, and Puma plus Solid Queue actually serving requests. |
| `bin/sandbox verify` | Boots a fresh isolated instance and drives a whole run lifecycle through it over real HTTP. |
| `bin/bundler-audit`, `bin/importmap audit`, `bin/brakeman` | Known-vulnerable gems and JavaScript pins, and Rails static security analysis. |

The test layers, and where a change belongs (details in AGENTS.md, ["Testing Guidelines"](./AGENTS.md#testing-guidelines)):

- **Boundary** (`spec/boundary_spec.rb`): fails if anything outside `Orchestrator::Runner` runs commands, shells out to git, signals processes, touches the filesystem or talks to herdr.
- **Unit, service, job and request specs** (`spec/services`, `spec/jobs`, `spec/requests`): one behaviour each, with `Orchestrator::Runner::Herdr` stubbed call by call. Never open a live herdr socket from a spec; `spec/spec_helper.rb` points `HERDR_SOCKET_PATH` at a socket that doesn't exist so a forgotten stub fails loudly.
- **Real git** where git behaviour is what's under test (see `spec/services/orchestrator/worktree_janitor_spec.rb`).
- **Fake herdr** (`lib/fake_herdr/`, tag an example `:fake_herdr`) and **fake Telegram** (`lib/fake_telegram/`, tag `:fake_telegram`): real sockets and processes, no model usage. If you teach `Orchestrator::Runner::Herdr` a new call, extend the fake and its spec together.
- **Lifecycle** (`spec/integration/run_lifecycle_spec.rb`): a run end to end in process. Changes to run or session state belong here as well as in a unit spec.
- **System specs** (`spec/system`): UI behaviour.

Don't consume live model capacity to test dispatch or argument building.

## Style

- Run `bin/rubocop` (Rails Omakase). Two-space indentation, `CamelCase` classes, `snake_case` files, Rails naming (`*_controller.rb`, `*_job.rb`, service objects under `app/services/...`).
- Frontend is importmap + Stimulus: controllers in `app/javascript/controllers`, named like `hello_controller.js`. There is no Node build.
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
