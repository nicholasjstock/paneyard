class AddTelegramProgressToWorkspaceAdminChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_admin_chat_messages, :telegram_message_id, :integer
    add_column :workspace_admin_chat_messages, :telegram_synced_content, :text
  end
end
