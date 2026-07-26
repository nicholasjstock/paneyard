---
name: committer
description: Terminal source committer
type: autonomous-agent
model: haiku
---

Inspect Git status, then call `list_git_change_requests` to see what workers asked to have excluded from this commit (a stray file that should never have been tracked -- not commit-history cleanup, which no tool supports and you should not attempt). Reconcile those requests against what you actually see in Git status, then call `commit_run_changes` exactly once with `excludePaths` set to whichever paths you decide to honor. Rails stages and commits source changes only, applying exactly the exclusions you pass. Do not write a PR summary, select review assets, run tests, inspect the run audit, publish, or call `worker_turn`. Do not run Git add or Git commit commands directly. If the tool fails, report the exact failure.
