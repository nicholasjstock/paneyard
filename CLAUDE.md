# Claude Project Guide

Read [AGENTS.md](./AGENTS.md) before changing this repository. It is the shared source of truth for structure, commands, testing, and run behavior -- read its "Operating Context" section first: this is a single-operator local tool that edits its own source (this repo is one of its own registered `Workspace`s) alongside other, unrelated target repos, with no runtime auth and a real remote-control surface (Telegram, GitHub App). If you are a session spawned by this very system, that context applies to you directly, not just hypothetically.

The most important architectural rule is that **Rails schedules; it does not orchestrate**. A run is a queued job. Rails decides when it starts, gives it a git worktree, and handles the branch afterwards. One continuous interactive `claude`/`codex`/`opencode` session then owns the whole job — exploring, editing, testing, committing, pushing — in a herdr pane the operator can watch and type into.

Do not reintroduce a planner, a step queue, per-step workers, a chaperone, acceptance-criteria trees, or a GitHub-mediated question protocol. All of that existed to compensate for headless one-shot workers that had no continuity and no operator in the loop. A session has both. If a run needs to change direction, talk to it (`Orchestrator::RunSessionRunner.prompt!`) — that is also how a pull-request comment reaches it.

A run ends only when its session calls the `run_done` MCP tool. `RunSessionReconcileJob` catches the cases where that never happens; without it a run holds its concurrency slot forever, because a live interactive CLI and a finished one look identical from outside.

## herdr

herdr owns every pty and process. `Orchestrator::Herdr` is a thin JSON-RPC client for it; Rails only remembers which pane, which pid, and which CLI session id. The per-driver flags in `Orchestrator::SessionArgs` were established by running the CLIs live inside a pane and several contradict their own `--help` — do not simplify one away without re-verifying it the same way.

A session produces no structured JSON output, so there is no cost or token accounting for it. That is the accepted price of watching the real thing instead of a transcript of it, not a bug to fix.

## Worktrees

Every run gets a sibling worktree of the workspace's `main` checkout on a `workflow/<name>` branch. Exactly two things reclaim them: `RunPublication.cleanup_merged_run!` after a merge, and `Orchestrator::WorktreeJanitor` for runs that ended otherwise. The janitor never touches `main` and never removes a dirty worktree.

## MCP boundary

One endpoint, `/mcp/run`, scoped to a single session's bearer capability, exposing nine tools. Add a tool only for something Rails alone knows or owns — a session with full access to its worktree does not need us to proxy file reads or shell commands for it.

## Verification

Add RSpec service/job coverage for run and session state changes, then run `bundle exec rspec`, `bin/rubocop`, and `git diff --check`. Stub `Orchestrator::Herdr` — never open a live socket in a spec, since its mutating calls have visible effects in the operator's own session. Use real git where git behavior is what is under test.
