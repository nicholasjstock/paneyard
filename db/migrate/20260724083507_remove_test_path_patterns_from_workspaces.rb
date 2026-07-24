class RemoveTestPathPatternsFromWorkspaces < ActiveRecord::Migration[8.1]
  def change
    remove_column :workspaces, :test_path_patterns, :json, default: [], null: false
  end
end
