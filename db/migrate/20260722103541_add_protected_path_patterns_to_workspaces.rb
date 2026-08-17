class AddProtectedPathPatternsToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :protected_path_patterns, :json, default: [], null: false
  end
end
