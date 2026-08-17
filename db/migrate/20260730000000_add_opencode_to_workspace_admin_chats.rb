class AddOpencodeToWorkspaceAdminChats < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_admin_chats, :opencode_model, :string
    add_column :workspace_admin_chats, :opencode_session_id, :string
  end
end
