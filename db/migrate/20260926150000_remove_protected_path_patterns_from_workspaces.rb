# Protected paths only ever reached a session as a line of prose in its
# prompt once the per-step sandbox went away, and the bootstrap run that
# discovered them is gone too.
class RemoveProtectedPathPatternsFromWorkspaces < ActiveRecord::Migration[8.1]
  def change
    remove_column :workspaces, :protected_path_patterns, :json, default: [], null: false
  end
end
