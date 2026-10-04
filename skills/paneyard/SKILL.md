---
name: paneyard
description: Hand work off to Paneyard, a job queue that runs each task as its own coding-agent session in a separate git worktree. Use when the user asks to queue, hand off, delegate, parallelise or split work into jobs, or to check on queued jobs, and Paneyard's MCP tools (queue_run, list_runs, get_run, list_workspaces) are available.
---

# Queueing work with Paneyard

Each job gets its own worktree, branch and agent session, and starts when a slot frees. It shares none of your context.

## Queue it in the right place

1. `list_workspaces`, and pick the one whose `repositoryPath` is this repository (its main checkout, if you are in a linked worktree). If none is, `register_workspace` with the repository's path, follow any fix it returns, and try again.
2. Pass `baseBranch` as the branch you have checked out (`git branch --show-current`) unless the user names another. The job starts from it and merges back into it.
3. Pass `driver` (the agent CLI you are: `claude` or `codex`) and `model` (the model you are running on, if you know it) unless the user wants different ones.

## The job sees only committed work

The job branches from the base branch's last commit. Uncommitted changes in the checkout, whether staged or unstaged, are not in it. Run `git status` before you queue. If there are changes the job needs, explain which required changes will be missing from its starting state.

## Write a self-contained brief

The job's agent knows only what the task says. Include:

- **Goal**: what should be true when it is finished, and why.
- **Constraints**: what must not change, conventions to follow, and anything already decided.
- **Where**: the files, modules or commands that matter.
- **Done when**: how to tell it worked, and the exact test command to run.

## Split work well

- Put changes that edit the same code in one job. Parallel jobs on the same files mean merge conflicts.
- If job B builds on job A's result, queue B with `after: [A's runId]`. B waits, holding no slot, until A's commits are merged into the shared base branch, and then branches from that. Don't ask the user to remember to merge in order. Use `after` only for real order dependencies, never to serialise jobs that just touch the same files.
- If a dependency fails or is stopped, the dependent job waits as `blocked` and says why. The user can reopen the dependency, or release the job.
- When parallel jobs touch shared files (lockfiles, routes, schema, changelogs), say that merging them will probably conflict.

## Check, don't guess

Use `list_runs` (what's queued or running now) and `get_run` (one job's state, why it is waiting, and its reports) to answer questions about progress. A job's reports are in `get_run`'s checkpoints, not in its terminal. Tell the user the runId of each job you queue.
