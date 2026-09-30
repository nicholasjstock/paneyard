# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# A sandbox instance (bin/sandbox, bin/preflight) seeds its own scratch
# workspace with `bin/rails sandbox:seed` and must never register a real one.
return if Orchestrator::Sandbox.enabled?

# No workspace is registered by default: add one from the UI (or /mcp/admin).
# PANEYARD_TARGET_ROOT, if set, registers that project directory (the one
# holding its `main` checkout) as a workspace named after it, and backfills
# the workspace of any runs that were pointed at it before workspaces existed.
if (default_root_path = ENV["PANEYARD_TARGET_ROOT"].presence)
  default_workspace = Workspace.find_or_create_by!(root_path: default_root_path) do |workspace|
    workspace.name = File.basename(File.expand_path(default_root_path))
  end
  Run.where(target_root: default_workspace.root_path, workspace_id: nil).update_all(workspace_id: default_workspace.id)
end

# Demo fixtures for UI states that don't depend on any real model output --
# e.g. the current-runs drawer panel and its count badge just need Run rows
# in active statuses, spread across a few workspaces, with a range of
# title/worktree_name lengths to look at. Never seeded in production: that
# database holds this machine's one real history.
if Rails.env.development?
  demo_workspace = Workspace.find_or_create_by!(root_path: "/tmp/paneyard-demo/my-project") do |workspace|
    workspace.name = "demo: my-project"
  end

  [
    { suffix: "short-title", status: "running", worktree_name: "add-cart-total", task: "Add cart total" },
    { suffix: "long-title", status: "running", worktree_name: "rework-checkout-flow-error-states",
      task: "Rework the checkout flow's error states so a failed payment shows the specific gateway " \
        "decline reason instead of a generic 'something went wrong' banner, matching what support " \
        "already sees in the gateway dashboard" },
    { suffix: "launching", status: "launching", worktree_name: "add-discount-codes", task: "Add discount codes" },
    { suffix: "queued", status: "queued", worktree_name: "fix-tax-rounding", task: "Fix tax rounding" },
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

  launch_artifact_run = Run.find_or_create_by!(run_id: "demo-launch-artifacts") do |run|
    run.workspace = demo_workspace
    run.task = "Review the uploaded launch artifacts"
    run.target_root = File.join(demo_workspace.root_path, "launch-artifacts")
    run.launcher_variant = "claude"
    run.status = "running"
    run.worktree_name = "review-launch-artifacts"
  end

  launch_artifacts = [
    { "name" => "requirements.txt", "source_run_id" => launch_artifact_run.run_id,
      "source_path" => "requirements.txt" },
    { "name" => "sample-data.json", "source_run_id" => launch_artifact_run.run_id,
      "source_path" => "sample-data.json" }
  ]
  launch_artifact_run.update!(launch_artifacts: launch_artifacts)
  seed_runner = Orchestrator::Runner.for(launch_artifact_run.workspace)
  seed_runner.store_attachment(source_root: launch_artifact_run.workspace.source_root, run_id: launch_artifact_run.run_id,
                               name: "requirements.txt", content: "Uploaded at launch\n- artifact manifest\n")
  seed_runner.store_attachment(source_root: launch_artifact_run.workspace.source_root, run_id: launch_artifact_run.run_id,
                               name: "sample-data.json", content: '{"source":"synthetic demo fixture","records":2}' + "\n")

  second_demo_workspace = Workspace.find_or_create_by!(root_path: "/tmp/paneyard-demo/inventory-service") do |workspace|
    workspace.name = "demo: inventory-service"
  end
  Run.find_or_create_by!(run_id: "demo-inventory-review") do |run|
    run.workspace = second_demo_workspace
    run.task = "Review inventory synchronization"
    run.target_root = File.join(second_demo_workspace.root_path, "review-inventory-sync")
    run.launcher_variant = "claude"
    run.status = "running"
    run.worktree_name = "review-inventory-sync"
  end
end
