class AddTelegramDraftToWorkspaceAdminChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_admin_chat_messages, :telegram_draft_id, :integer
  end
end
