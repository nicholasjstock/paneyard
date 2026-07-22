# Workspace/run navigation baseline

Run: `run-20260722-161402-b491`
Scope: workspace-run-switcher-baseline.md
Mode: diagnosis; read-only evidence gathering
Repository root: `/Users/stockn/Source/workflow-orchestrator/i-want-current-runs-to-be-displayed-in-a-dropdow-b491`

## Confirmed route map

Authoritative source: `config/routes.rb`.

- Root: `GET /` -> `workspaces#index` (`root "workspaces#index"`).
- Workspace resource: `/workspaces` index/show/new/create/edit/update/destroy -> `WorkspacesController`.
- Nested runs: `/workspaces/:workspace_id/runs` index/new/create/show -> `RunsController`.
- Nested run member actions: `POST /workspaces/:workspace_id/runs/:id/stop`, `switch_launcher`, and `retry_publication`.
- Other workspace-scoped navigation targets: nested workers index/show plus stop, questions index, events index, chats index/create/show plus nested messages create, and run_commands member stop.

Verbatim route evidence:

> `resources :workspaces, only: %i[index show new create edit update destroy]`  
> `resources :runs, only: %i[index new create show] do`  
> `  member do`  
> `    post :stop`  
> `    post :switch_launcher`  
> `    post :retry_publication`  
> `  end`  
> `end`

> `root "workspaces#index"`

## Controller boundaries and current behavior

### Workspace selection

`app/controllers/application_controller.rb` defines `current_workspace` as a helper and sets it only through the nested `workspace_id` parameter:

> `helper_method :current_workspace`

> `def current_workspace`  
> `  @current_workspace`  
> `end`

> `def require_workspace`  
> `  @current_workspace = Workspace.find(params[:workspace_id])`  
> `end`

`app/controllers/workspaces_controller.rb` sends workspace show directly to that workspace's run list:

> `def show`  
> `  workspace = Workspace.find(params[:id])`  
> `  redirect_to workspace_runs_path(workspace)`  
> `end`

Workspace index renders every workspace, with each name linking to its own nested run list:

> `<%= link_to workspace.name, workspace_runs_path(workspace) %>`

### Runs

`app/controllers/runs_controller.rb` applies `require_workspace` to all run actions and scopes every lookup through `current_workspace`:

> `before_action :require_workspace`

> `def index`  
> `  @runs = current_workspace.runs.order(created_at: :desc)`  
> `end`

> `def set_run`  
> `  @run = current_workspace.runs.find_by!(run_id: params[:id])`  
> `end`

Current run list behavior: all runs for the selected workspace, newest first; no dropdown is present. The list shows worktree/run id, status badge, task, branch, PR link, launcher, start/stop timestamps, and a stale-launch warning. Its links preserve the selected workspace:

> `<%= link_to run.worktree_name.presence || run.run_id, workspace_run_path(current_workspace, run), class: "mono" %>`

The run detail page also remains nested under the selected workspace and displays the current workspace name:

> `<span class="muted"><%= current_workspace.name %> &middot; <%= @run.launcher_variant %></span>`

The launch form posts to the selected workspace's nested runs collection:

> `<%= form_with model: @run, url: workspace_runs_path(current_workspace), local: true do |form| %>`

### Current-run definition

`app/models/run.rb` defines “active/current” as non-terminal statuses `launching`, `running`, or `stopping`:

> `STATUSES = %w[launching running stopping stopped completed failed].freeze`

> `NON_TERMINAL_STATUSES = %w[launching running stopping].freeze`

> `scope :active, -> { where(status: NON_TERMINAL_STATUSES) }`

> `def active?`  
> `  NON_TERMINAL_STATUSES.include?(status)`  
> `end`

Run records belong to a workspace:

> `belongs_to :workspace`

Therefore a workspace-first current-runs dropdown can use `current_workspace.runs.active` and link each item with `workspace_run_path(current_workspace, run)`, without changing routing or persistence contracts.

## Existing navigation that renders the UI

The global shell is `app/views/layouts/application.html.erb`. It renders the brand, a Workspaces link, and—only when `current_workspace` exists—the workspace-scoped Runs, Workers, Questions, and Events links:

> `<nav>`  
> `  <%= link_to "Workspaces", workspaces_path, class: current_page?(workspaces_path) ? "active" : nil %>`  
> `  <% if current_workspace %>`  
> `    <%= link_to "Runs", workspace_runs_path(current_workspace), class: current_page?(workspace_runs_path(current_workspace)) ? "active" : nil %>`  
> `    <%= link_to "Workers", workspace_workers_path(current_workspace), class: current_page?(workspace_workers_path(current_workspace)) ? "active" : nil %>`  
> `    <%= link_to "Questions", workspace_questions_path(current_workspace), class: current_page?(workspace_questions_path(current_workspace)) ? "active" : nil %>`  
> `    <%= link_to "Events", workspace_events_path(current_workspace), class: current_page?(workspace_events_path(current_workspace)) ? "active" : nil %>`  
> `  <% end %>`  
> `</nav>`

The layout is therefore the correct shared insertion point for a current-runs dropdown. On `/` and `/workspaces`, `current_workspace` is nil, so workspace-scoped run navigation is intentionally absent. On nested workspace pages it is present.

The runs index’s page-local toolbar has “Re-run project setup” and, once initialized, “Launch task”; it does not currently offer a run switcher:

> `<div class="toolbar">`  
> `  <h1><%= current_workspace.name %> Runs</h1>`  
> `  <%= button_to "Re-run project setup", workspace_project_setup_path(current_workspace), method: :post, class: "btn" %>`  
> `  <% if current_workspace.initialized? %>`  
> `    <%= link_to "Launch task", new_workspace_run_path(current_workspace), class: "btn primary" %>`

## Smallest bounded implementation surface

No application files were changed.

The smallest source surface for a workspace-scoped current-runs dropdown is:

1. `app/views/layouts/application.html.erb` — add the dropdown to the existing `current_workspace` navigation shell; use nested run links and preserve the selected workspace.
2. `app/controllers/application_controller.rb` — only if the view should receive a preloaded collection/helper (for example, a helper method returning `current_workspace.runs.active.order(created_at: :desc)`). This is the shared boundary because the layout is rendered for all controllers.
3. `app/models/run.rb` — no change is required: the existing `active` scope already defines the current/non-terminal set.
4. Optional nearest regression coverage: `spec/system/runs_spec.rb` for a system assertion that the dropdown appears only with the selected workspace and links to `workspace_run_path(workspace, run)`. This is test scope, not required for the UI boundary itself.

No route, controller action, migration, API, or public contract change is indicated by the baseline. The dropdown should not query or link runs without first scoping through `current_workspace`.

## Verification notes

Read-only commands used:

- `rg --files app config spec`
- `rg -n "workspaces|runs|workspace|Run|Current|nav|navigation|link_to|form_with|select" app/views app/controllers app/helpers spec/system spec/requests`
- `nl -ba` on the route, controller, model, helper, layout, workspace index, runs index/show/new files
- `bin/rails routes | rg "workspace|run|root"` was attempted but could not boot in this source-protected worker: Rails attempted to write `tmp/local_secret.txt` and `log/development.log`, returning `Errno::EPERM`. This does not affect the checked-in route evidence above.

Confirmed boundary: the shared layout owns navigation rendering; `ApplicationController#require_workspace` establishes the selected workspace; `RunsController#index` and `Run#active` provide the workspace-scoped current-run data semantics; existing nested route helpers preserve workspace-first links.
