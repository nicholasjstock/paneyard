class AddLauncherVariantToWorkspaceChats < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_chats, :launcher_variant, :string, default: "claude", null: false
    remove_column :workspace_chats, :session_id, :string
  end
end
