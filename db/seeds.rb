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
