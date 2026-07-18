# Repository Guidelines

## Project Structure & Module Organization
This repository is a Rails 8 application organized around `Workspace` as the top-level boundary. New work should start from a specific workspace, and related runs, workers, questions, events, and orchestration artifacts should stay nested under that workspace in code and UI flow. Core server code lives in `app/`: controllers in `app/controllers`, persistence models in `app/models`, background jobs in `app/jobs`, and orchestration logic in `app/services/orchestrator` and `app/services/mcp_tools`. Frontend code uses importmap + Stimulus under `app/javascript`, with views in `app/views` and static assets in `public/`. Database schema and migrations live in `db/`. Operational notes and handoff material belong in root-level docs such as `HANDOFF.md`.

## Build, Test, and Development Commands
Run `bin/setup` to install gems, prepare the database, and clear stale logs/tmp files. Use `bin/dev` for local development; it starts both the Rails server and the Solid Queue worker process so recurring jobs fire. Use `bin/rails db:prepare` after schema changes, and `bin/rails console` for local inspection. Run `bin/ci` before opening a PR; it executes setup, RuboCop, `bundler-audit`, `bin/importmap audit`, and Brakeman.

## Coding Style & Naming Conventions
Follow the default Rails Omakase style configured in `.rubocop.yml`; run `bin/rubocop` to check formatting. Use two-space indentation in Ruby and keep class and module names `CamelCase` with file names in `snake_case`. Match existing Rails naming patterns such as `*_controller.rb`, `*_job.rb`, and service objects under `app/services/...`. Keep JavaScript controllers in `app/javascript/controllers` with Stimulus-style names like `hello_controller.js`.

## Workspace-First Design
Treat `Workspace` as the precursor to everything else. When adding routes, screens, jobs, or persistence, prefer shapes that scope data by workspace first, then by the nested resource, for example `/workspaces/:workspace_id/runs/:id`. Avoid introducing new top-level flows that bypass workspace selection unless the feature is truly global.

## Rails-Owned Orchestration
Rails owns workflow state, planning lifecycle, retries, and process dispatch. Do not introduce planner agent files or spawn planner OS processes. Planning requests are claimed by `Orchestrator::SpawnRequestedWorkers`, persisted as `PlannerDecision` records, and executed by `PlannerDecisionJob`.

The planning model is a bounded decision function, not an autonomous coordinator. `Orchestrator::PlannerBrief` builds the compact input, `Orchestrator::PlannerDecisionRunner` requests structured output with tools disabled, and `Orchestrator::Turn` validates and persists the decision before Rails dispatches work.

Workers are still autonomous executors. They report `[DONE]`, `[BLOCKED]`, or `[FAILED]` through `worker_turn`. When `[DONE]` arrives and a validated `followingSteps` queue exists, Rails promotes its head directly without spending another planner call. Other outcomes queue a new planner decision.

## Planner Context Protocol
A planner that lacks information returns `outcome: "needs_context"` with one `contextRequest` containing:

- `source`: `artifact`, `run_context`, `worker_log`, or `file`.
- `reference`: the exact artifact, entry key, worker nickname, or workspace-relative file.
- `question`: the specific uncertainty the context must resolve.
- `offset`: `null`/zero for the first window or a prior `next_offset`.
- `maxChars`: the planner-selected window size.

Rails resolves that request and starts a fresh model call with accumulated requested context. There is no fixed round or total-context cap. An identical request is rejected because it would return the same information and loop without progress. `PlannerDecision` records model calls, requested windows, returned bytes, tokens, and cost so tuning should be based on observed runs rather than arbitrary limits.

Planning defaults to the smaller model tier. When information is sufficient but reasoning complexity warrants escalation, the planner may return `outcome: "needs_stronger_model"`; Rails reruns with unchanged accumulated context on the stronger tier. Model attempts and promotions are persisted for inspection on the run screen.

Key implementation files are `app/jobs/planner_decision_job.rb`, `app/models/planner_decision.rb`, and `app/services/orchestrator/{planner_brief,planner_context_resolver,planner_decision_runner,spawn_requested_workers,turn}.rb`.

## Testing Guidelines
The repository uses RSpec under `spec/`. Add service and job regression coverage for orchestration state changes, and system coverage for UI behavior. Run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`. Stub `Orchestrator::PlannerDecisionRunner` in specs; do not consume live model capacity to verify routing or structured-output parsing.

## Commit & Pull Request Guidelines
Recent commit history favors short, imperative summaries such as `Flatten ops/ into the repo root` and `Port the TS orchestrator engine to Ruby`. Keep commits focused and descriptive. PRs should include a concise problem statement, the implementation approach, any schema or job-queue impact, and manual verification steps. Link related issues when available and include screenshots only for UI changes.

## Security & Configuration Tips
Do not commit decrypted credentials, database dumps, or logs containing run data. Review changes to `config/credentials.yml.enc`, queue configuration, and any MCP tool implementation carefully, because they affect worker execution and orchestration flow.

## Chaperone Boundary
Repeated failed diagnosis attempts with the same explicit lineage may trigger a strong-model chaperone. The chaperone uses the capability-scoped `/mcp/chaperone` endpoint, which exposes only curated run state, bounded artifact reads, and the `continue_small`, `promote`, or `stop` decision. Never expose arbitrary SQL, Active Record lookup, filesystem traversal, command execution, or general MCP tools through this endpoint.
