class AddTelegramPersistedCharactersToWorkspaceAdminChatMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_admin_chat_messages, :telegram_persisted_characters, :integer, null: false, default: 0
  end
end
