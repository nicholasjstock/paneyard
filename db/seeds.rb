# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# The one workspace every run was implicitly pointed at before workspaces
# existed as a real concept -- keeps pre-existing runs working the same
# way, and backfills their workspace_id for display/traceability.
default_root_path = ENV.fetch("WORKFLOW_TARGET_ROOT", "/Users/stockn/Source/simple-retail-planner/main")
default_workspace = Workspace.find_or_create_by!(root_path: default_root_path) do |workspace|
  workspace.name = "simple-retail-planner"
end
Run.where(target_root: default_workspace.root_path, workspace_id: nil).update_all(workspace_id: default_workspace.id)

# Demo fixtures for UI states that don't depend on any real model output --
# e.g. the current-runs dropdown just needs Run rows in active statuses
# with a range of title/worktree_name lengths to look at. Never seeded in
# production: that database holds this machine's one real history.
if Rails.env.development?
  demo_workspace = Workspace.find_or_create_by!(root_path: "/tmp/workflow-demo/simple-retail-planner") do |workspace|
    workspace.name = "demo: simple-retail-planner"
  end

  [
    { suffix: "short-title", status: "running", worktree_name: "add-cart-total", task: "Add cart total" },
    { suffix: "long-title", status: "running", worktree_name: "rework-checkout-flow-error-states",
      task: "Rework the checkout flow's error states so a failed payment shows the specific gateway " \
        "decline reason instead of a generic 'something went wrong' banner, matching what support " \
        "already sees in the gateway dashboard" },
    { suffix: "launching", status: "launching", worktree_name: "add-discount-codes", task: "Add discount codes" },
    { suffix: "stopping", status: "stopping", worktree_name: "fix-tax-rounding", task: "Fix tax rounding" },
    { suffix: "no-worktree-name", status: "running", worktree_name: nil, task: "Runs before worktree naming existed" }
  ].each do |attrs|
    run_id = "demo-#{attrs[:suffix]}"
    Run.find_or_create_by!(run_id: run_id) do |run|
      run.workspace = demo_workspace
      run.task = attrs[:task]
      run.target_root = File.join(demo_workspace.root_path, attrs[:suffix])
      run.launcher_variant = "claude"
      run.status = attrs[:status]
      run.worktree_name = attrs[:worktree_name]
    end
  end
end
