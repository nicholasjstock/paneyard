class AddPidToWorkspaceAdminChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_admin_chat_messages, :pid, :integer
    add_column :workspace_admin_chat_messages, :process_group_id, :integer
  end
end
