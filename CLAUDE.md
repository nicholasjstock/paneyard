# Claude Project Guide

Read [AGENTS.md](./AGENTS.md) before changing this repository. It is the shared source of truth for structure, commands, testing, and run behavior -- read its "Operating Context" section first: this is a single-operator local tool that edits its own source (this repo is one of its own registered `Workspace`s) alongside other, unrelated target repos, with no runtime auth and a real remote-control surface (Telegram, GitHub App). If you are a session spawned by this very system, that context applies to you directly, not just hypothetically.

The most important architectural rule is that **Rails schedules; it does not orchestrate**. A run is a queued job. Rails decides when it starts, gives it a git worktree, and reclaims that worktree afterwards. One continuous interactive `claude`/`codex`/`opencode` session then owns the whole job — exploring, editing, testing — in a herdr pane the operator can watch and type into.

Do not reintroduce a planner, a step queue, per-step workers, a chaperone, acceptance-criteria trees, or a GitHub-mediated question protocol. All of that existed to compensate for headless one-shot workers that had no continuity and no operator in the loop. A session has both. If a run needs to change direction, talk to it (`Orchestrator::RunSessionRunner.prompt!`).

A session reports going idle with the `report_idle` MCP tool; it does not end the run. Rails cannot infer idleness, because a live interactive CLI looks identical whether the agent finished or is waiting for input. Reporting leaves the pane open, the process up and the concurrency slot held, and pushes nothing. Each report is a checkpoint covering the interval since the previous one, kept as `RunCheckpoint` history rather than overwritten, so the newest is current state and the sequence is the run's narrative. Its summary is a full Markdown report, not a status line: the run screen shows the checkpoints and not the pane, so they are how the operator learns what a run did.

Only the operator ends a session, with **Close session** on the run screen (kills the CLI, closes the herdr workspace, frees the slot). Never make a session's report tear down its own pane. `RunSessionReconcileJob` remains the safety net for a session that genuinely died; an idle session is not an anomaly to it.

A session leaves its changes uncommitted so the operator can try them first; it commits, pushes its `workflow/<name>` branch, or merges straight into `main` only when the operator asks. Rails does not do pull requests: opening, reviewing and merging a PR is the operator's business, outside this app. Do not reintroduce publishing, merge polling, or PR-comment resumption.

## herdr

herdr owns every pty and process. `Orchestrator::Herdr` is a thin JSON-RPC client for it; Rails only remembers which pane, which pid, and which CLI session id. The per-driver flags in `Orchestrator::SessionArgs` were established by running the CLIs live inside a pane and several contradict their own `--help` — do not simplify one away without re-verifying it the same way.

A session produces no structured JSON output, so there is no cost or token accounting for it. That is the accepted price of watching the real thing instead of a transcript of it, not a bug to fix.

## Worktrees

Every run gets a sibling worktree of the workspace's `main` checkout on a `workflow/<name>` branch. Two things reclaim them: `Orchestrator::WorktreeJanitor` — on **Close session**, when `RunSessionReconcileJob` finds a run's herdr workspace was closed by hand, and on its sweep — and the run screen's **Remove worktree** button. The janitor never touches `main` and never removes a worktree whose work is not both committed and pushed or merged; those are kept indefinitely and flagged in the UI as kept worktrees.

## MCP boundary

`/mcp/run`, scoped to a single session's bearer capability, is what a run session talks to. `/mcp/admin` is a second, unauthenticated endpoint for external MCP clients (an operator's own everyday Claude Code session, principally) to queue and inspect runs without the web UI — see AGENTS.md's "MCP Boundary" for the full shape and which tools each endpoint carries. Add a tool only for something Rails alone knows or owns — a session with full access to its worktree does not need us to proxy file reads or shell commands for it.

## Verification

Add RSpec service/job coverage for run and session state changes, then run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`. Stub `Orchestrator::Herdr` — never open a live socket in a spec, since its mutating calls have visible effects in the operator's own session. Use real git where git behavior is what is under test.
