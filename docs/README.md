# Documentation

## Guides

- [operating.md](./operating.md) — running the orchestrator: `bin/dev` and `bin/service`, preparing a repository, git and worktree-cleanup rules, GitHub access, workspace layouts and env vars, MCP endpoints, the sandbox.
- [telegram.md](./telegram.md) — Telegram remote control, and how to add another chat platform.
- [../CONTRIBUTING.md](../CONTRIBUTING.md) and [../AGENTS.md](../AGENTS.md) — changing the orchestrator itself.

## Design records

These were written while a feature was being designed and built. They explain *why* things are the way they are, including live experiments against herdr and alternatives that were rejected. They are kept for that reasoning, not as current reference: class names, file paths and "open" items in them may have moved on since. Where one disagrees with the guides above or with AGENTS.md, the guides and the code win.

- [workspace-layouts.md](./workspace-layouts.md) — per-workspace herdr tab and pane layouts (implemented).
- [remote-control.md](./remote-control.md) — replacing the old workspace "admin chat" with direct remote control of sessions over Telegram (partly implemented; its update notes at the top say what shipped).
- [demo-recording-plan.md](./demo-recording-plan.md) — plan for a reproducible, recorded demo (Docker, real herdr, live Claude Code, ffmpeg) for the launch README and a conference talk (partly built: `demo/`).

## Images

Screenshots for the README belong in `images/`. `images/demo.gif` is made by `demo/bin/record rehearse` (or `take`); see [demo-recording-plan.md](./demo-recording-plan.md).
