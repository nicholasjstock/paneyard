class AddTelegramDeliveryToWorkspaceAdminChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_reference :workspace_admin_chat_messages, :telegram_conversation, foreign_key: true
    add_column :workspace_admin_chat_messages, :telegram_delivered_at, :datetime
  end
end
