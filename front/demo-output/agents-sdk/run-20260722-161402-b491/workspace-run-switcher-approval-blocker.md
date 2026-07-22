# Workspace/run switcher approval blocker

Run: `run-20260722-161402-b491`
Scope: `workspace-run-switcher-approval-blocker.md`
Mode: diagnosis; evidence gathering only

## Confirmed protected implementation target

Exact protected implementation target: `app/views/layouts/application.html.erb`.

The baseline identifies this shared layout as the smallest required UI source file and the correct insertion point for the workspace-scoped current-runs dropdown. No application file was changed during this diagnosis.

## Preserved requirements

- The dropdown must render only when `current_workspace` exists.
- Current runs must use the existing non-terminal/current semantics: `launching`, `running`, and `stopping`.
- Run data must remain scoped through `current_workspace.runs.active`.
- Each item must preserve workspace scope through `workspace_run_path(current_workspace, run)`.
- No route, controller action, migration, API, persistence, or public-contract change is indicated.

## Approval blocker

The target path is protected under this workspace's declared source-protected policy. No operator approval exists for the protected path. Implementation is therefore on hold and awaits an answered operator approval reference. This artifact records the boundary only; it does not authorize or implement the change.

## Evidence citations

The following citations are copied verbatim from `workspace-run-switcher-baseline.md`:

> The global shell is `app/views/layouts/application.html.erb`. It renders the brand, a Workspaces link, and—only when `current_workspace` exists—the workspace-scoped Runs, Workers, Questions, and Events links:

> `app/views/layouts/application.html.erb` — add the dropdown to the existing `current_workspace` navigation shell; use nested run links and preserve the selected workspace.

> Therefore a workspace-first current-runs dropdown can use `current_workspace.runs.active` and link each item with `workspace_run_path(current_workspace, run)`, without changing routing or persistence contracts.

> Confirmed boundary: the shared layout owns navigation rendering; `ApplicationController#require_workspace` establishes the selected workspace; `RunsController#index` and `Run#active` provide the workspace-scoped current-run data semantics; existing nested route helpers preserve workspace-first links.
