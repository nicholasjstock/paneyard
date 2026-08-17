class CreateTelegramConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_conversations do |t|
      t.references :workspace, foreign_key: true
      t.string :telegram_chat_id, null: false
      t.string :telegram_user_id, null: false

      t.timestamps
    end

    add_index :telegram_conversations, :telegram_chat_id, unique: true
  end
end
