# Finalization refactor: reporter, curator, committer

## Goal

Replace the overloaded terminal `committer` role with three bounded jobs:

1. **Run reporter**: audits persisted run history and writes the PR narrative.
2. **Evidence curator**: selects real, reviewer-useful local files for upload.
3. **Committer**: commits source changes only.

Rails remains responsible for pushing branches, creating draft GitHub releases, uploading selected assets, creating PRs, and cleanup after approval.

## Current problems

- The committer is asked to audit state, select evidence, write a summary, and commit. These concerns blur together.
- Historical workflow artifact names are being presented as if they were downloadable reviewer assets.
- Some artifacts no longer exist locally after worktree cleanup.
- Draft release support exists in commit `7c136c7`, but no role is consistently instructed to call `select_review_assets`.
- `get_run_audit` is committer-only in commit `e3cd559`; it should move to the reporter role instead.

## Desired lifecycle

```text
run completed
  -> reporter request
  -> curator request
  -> committer request
  -> Rails commits/pushes source branch
  -> Rails creates draft evidence release and uploads curator selections
  -> Rails creates PR with reporter narrative and successful asset links
  -> approval
  -> Rails deletes draft release/assets/tag, merges PR, removes worktree
```

The reporter and curator may run sequentially to keep the existing one-worker-per-run dispatch model. The committer must only be queued after both are complete.

## Role contracts

### Reporter

- Read-only.
- Must call a reporter-only persisted audit tool (rename/generalize `get_run_audit`).
- Writes `run-summary.md` only.
- Does not run tests, inspect arbitrary logs, select files, call Git, or publish.
- Summary sections:
  - Outcome
  - Source files changed
  - Chronological human-readable audit trail
  - Failures/boundaries and recovery
  - Verified acceptance evidence
  - Unresolved limitations
- Never list historical artifact filenames merely because they existed in run state.

### Evidence curator

- Read-only for repository source; may inspect candidate generated files.
- Calls `select_review_assets` only for real files that exist locally and would help a reviewer.
- Does not write the PR narrative, run tests, or commit.
- Default is no selection.
- Must explicitly report either selected assets or `No review assets selected` in a small curator artifact/state result.
- Never select source files, `.git`, prompts, logs, environment snapshots, MCP configs, credentials, or generic worker runtime output.

### Committer

- Reads Git status only.
- Calls `commit_run_changes` exactly once.
- Does not audit the run, write a summary, select evidence, run tests, or invoke GitHub.

## Data model

Keep `RunReviewAsset` introduced in `7c136c7`:

- `run_id`
- `workspace_path`
- `label`
- `github_url`

Add columns if useful for lifecycle visibility:

- `runs.review_release_tag`
- `runs.review_release_url`
- `runs.review_assets_uploaded_at`

Consider a `RunFinalization` record only if request state becomes hard to express with `SpawnRequest`; otherwise use distinct request roles/scopes:

- reporter / `run-summary.md`
- evidence_curator / `review-assets.md`
- committer / `commit-<worktree>.md`

## MCP changes

1. Move `get_run_audit` authorization from `committer` to `reporter` (or rename it `get_finalization_audit`).
2. Restrict `select_review_assets` to `evidence_curator`.
3. Keep `commit_run_changes` restricted to `committer`.
4. Expose only the role-appropriate tools through `WorkerMcpServer`; do not expose run-wide audit history to ordinary implementation/verifier/infrastructure workers.
5. Validate curator paths strictly:
   - workspace-relative,
   - existing regular files,
   - under the run worktree,
   - reject source paths and sensitive/runtime patterns,
   - enforce reasonable asset count/size limits.

## Publication changes

`Orchestrator::RunPublication.publish!` should:

1. Push the committed source branch.
2. If `review_assets` is nonempty, create a draft release tagged `workflow-evidence-<run-id>` and targeted at the pushed branch SHA.
3. Upload each persisted selected file.
4. Persist release metadata and only successful asset URLs.
5. Create the PR body from:
   - fixed run metadata,
   - reporter `run-summary.md`,
   - a `## Review evidence` section containing only successfully uploaded links.
6. If asset upload fails, fail publication clearly; do not claim the assets exist.

`remove_evidence!` should delete the draft release with `--cleanup-tag` only when a release was actually created, then mark cleanup complete.

## UI

Update the run screen to show separate finalization phases:

- Writing PR audit
- Curating review evidence
- Committing source changes
- Uploading review evidence
- Awaiting approval

Show uploaded evidence links and release status. Do not show local raw artifact paths as reviewer evidence.

## Tests

Add focused coverage for:

- Reporter/curator/committer requests are queued in order.
- Each role is rejected when calling another role's MCP tool.
- Curator path validation rejects source files, logs, prompts, env/MCP files, and files outside the worktree.
- `select_review_assets` persists only validated selections.
- Publication creates draft release/uploads before PR creation and places only returned URLs in the PR body.
- Upload failure does not create a misleading PR body.
- Approval cleanup deletes the draft release/tag before merge.
- PR summary with no selection says no review assets were uploaded and contains no historical artifact filenames.

Run at minimum:

```sh
asdf exec bundle exec rspec spec/jobs/tick_run_job_spec.rb spec/services/orchestrator/run_publication_spec.rb
asdf exec bundle exec rubocop
git diff --check
```

## Existing test-run cleanup

- PRs #10 through #14 have been closed.
- The reused run `run-20260722-191333-6819` is stopped.
- Its worktree may contain local untracked runtime output; do not treat it as review evidence.
- Its run records include earlier committer retries; do not use those as the desired lifecycle model.
