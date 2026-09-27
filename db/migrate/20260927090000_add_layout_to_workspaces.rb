class AddLayoutToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    # YAML text; NULL means Orchestrator::WorkspaceLayout's default.
    add_column :workspaces, :layout, :text
  end
end
