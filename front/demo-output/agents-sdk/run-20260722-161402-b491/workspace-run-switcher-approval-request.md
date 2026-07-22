# Workspace/run switcher approval request

Run: `run-20260722-161402-b491`
Worker: `worker-2`
Scope: `workspace-run-switcher-approval-request.md`
Mode: diagnosis; evidence gathering only

## Evidence outcome

**blocked**

The assigned evidence boundary is confirmed, but implementation cannot proceed. The smallest required UI source file is the protected shared layout `app/views/layouts/application.html.erb`; the run context and referenced blocker record no answered operator approval for this protected path. No repository files were changed and no application fix was attempted.

The next step requires an answered operator approval reference for `app/views/layouts/application.html.erb`, or an explicit decision to keep this branch blocked.

## Evidence citations

The following citations are copied verbatim from `workspace-run-switcher-approval-blocker.md`:

> Exact protected implementation target: `app/views/layouts/application.html.erb`.

> The target path is protected under this workspace's declared source-protected policy. No operator approval exists for the protected path. Implementation is therefore on hold and awaits an answered operator approval reference. This artifact records the boundary only; it does not authorize or implement the change.

> The global shell is `app/views/layouts/application.html.erb`. It renders the brand, a Workspaces link, and—only when `current_workspace` exists—the workspace-scoped Runs, Workers, Questions, and Events links:

> `app/views/layouts/application.html.erb` — add the dropdown to the existing `current_workspace` navigation shell; use nested run links and preserve the selected workspace.

> Confirmed boundary: the shared layout owns navigation rendering; `ApplicationController#require_workspace` establishes the selected workspace; `RunsController#index` and `Run#active` provide the workspace-scoped current-run data semantics; existing nested route helpers preserve workspace-first links.

## Verification

- Referenced artifact resolved: `workspace-run-switcher-approval-blocker.md`.
- Approval status: absent; no answered operator approval reference exists.
- Repository changes: none.
- Commands run: none; repository mutation was prohibited and unnecessary for this approval-boundary diagnosis.
