# Claude Project Guide

Read [AGENTS.md](./AGENTS.md) before changing this repository. It is the shared source of truth for structure, commands, testing, and run behavior -- read its "Operating Context" section first: this is a single-operator local tool that edits its own source (this repo is one of its own registered `Workspace`s) alongside other, unrelated target repos, with no runtime auth and a real remote-control surface (Telegram, GitHub App). If you are a session spawned by this very system, that context applies to you directly, not just hypothetically.

The most important architectural rule is that **Rails schedules; it does not orchestrate**. A run is a queued job. Rails decides when it starts, gives it a git worktree, and handles the branch afterwards. One continuous interactive `claude`/`codex`/`opencode` session then owns the whole job — exploring, editing, testing, committing, pushing — in a herdr pane the operator can watch and type into.

Do not reintroduce a planner, a step queue, per-step workers, a chaperone, acceptance-criteria trees, or a GitHub-mediated question protocol. All of that existed to compensate for headless one-shot workers that had no continuity and no operator in the loop. A session has both. If a run needs to change direction, talk to it (`Orchestrator::RunSessionRunner.prompt!`) — that is also how a pull-request comment reaches it.

A session reports going idle with the `report_idle` MCP tool; it does not end the run. Rails cannot infer idleness, because a live interactive CLI looks identical whether the agent finished or is waiting for input. Reporting leaves the pane open, the process up and the concurrency slot held, and publishes nothing: the operator reads the pane and decides what happens next. Each report is a checkpoint covering the interval since the previous one, kept as `RunCheckpoint` history rather than overwritten, so the newest is current state and the sequence is the run's narrative.

Only the operator ends a session, from the run screen: **Open pull request** (`PublishRunJob`) or **Close session** (kills the CLI, closes the herdr workspace, frees the slot). Never make a session's report open a pull request or tear down its own pane. `RunSessionReconcileJob` remains the safety net for a session that genuinely died; an idle session is not an anomaly to it.

## herdr

herdr owns every pty and process. `Orchestrator::Herdr` is a thin JSON-RPC client for it; Rails only remembers which pane, which pid, and which CLI session id. The per-driver flags in `Orchestrator::SessionArgs` were established by running the CLIs live inside a pane and several contradict their own `--help` — do not simplify one away without re-verifying it the same way.

A session produces no structured JSON output, so there is no cost or token accounting for it. That is the accepted price of watching the real thing instead of a transcript of it, not a bug to fix.

## Worktrees

Every run gets a sibling worktree of the workspace's `main` checkout on a `workflow/<name>` branch. Exactly two things reclaim them: `RunPublication.cleanup_merged_run!` after a merge, and `Orchestrator::WorktreeJanitor` — on **Close session** and on its sweep — for everything else. The janitor never touches `main` and never removes a worktree whose work is not both committed and pushed or merged; those are kept indefinitely and flagged in the UI as kept worktrees.

## MCP boundary

One endpoint, `/mcp/run`, scoped to a single session's bearer capability, exposing eight tools. Add a tool only for something Rails alone knows or owns — a session with full access to its worktree does not need us to proxy file reads or shell commands for it.

## Verification

Add RSpec service/job coverage for run and session state changes, then run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`. Stub `Orchestrator::Herdr` — never open a live socket in a spec, since its mutating calls have visible effects in the operator's own session. Use real git where git behavior is what is under test.
