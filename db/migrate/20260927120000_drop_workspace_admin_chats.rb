# The workspace admin chat ran its own one-shot agent turns from a workspace
# root, which predates the one-interactive-session-per-run model and could
# never actually steer a run's session. Telegram now talks to the sessions
# directly (Telegram::UpdateProcessor), so the chat, its transcript, and the
# Telegram conversation -> workspace selection it needed are all gone.
# telegram_update_cursors stays: the poller still needs it.
class DropWorkspaceAdminChats < ActiveRecord::Migration[8.1]
  def change
    drop_table :workspace_admin_chat_messages do |t|
      t.text :content, default: "", null: false
      t.text :error_message
      t.json :events, default: [], null: false
      t.integer :pid
      t.integer :process_group_id
      t.string :provider
      t.string :role, null: false
      t.string :status, default: "queued", null: false
      t.integer :telegram_conversation_id
      t.datetime :telegram_delivered_at
      t.integer :telegram_draft_id
      t.integer :telegram_message_id
      t.integer :telegram_persisted_characters, default: 0, null: false
      t.text :telegram_synced_content
      t.string :turn_id
      t.json :usage, default: {}, null: false
      t.integer :workspace_admin_chat_id, null: false
      t.timestamps
      t.index :telegram_conversation_id, name: "idx_on_telegram_conversation_id_d672f9d019"
      t.index :turn_id
      t.index :workspace_admin_chat_id
      t.foreign_key :telegram_conversations
      t.foreign_key :workspace_admin_chats
    end

    drop_table :workspace_admin_chats do |t|
      t.string :active_provider, default: "claude", null: false
      t.string :active_turn_id
      t.string :capability_token_digest
      t.string :claude_model
      t.string :claude_session_id
      t.string :codex_model
      t.string :codex_session_id
      t.text :last_error
      t.string :opencode_model
      t.string :opencode_session_id
      t.string :status, default: "idle", null: false
      t.integer :workspace_id, null: false
      t.timestamps
      t.index :capability_token_digest, unique: true
      t.index :workspace_id, unique: true
      t.foreign_key :workspaces
    end

    drop_table :telegram_conversations do |t|
      t.string :telegram_chat_id, null: false
      t.string :telegram_user_id, null: false
      t.integer :workspace_id
      t.timestamps
      t.index :telegram_chat_id, unique: true
      t.index :workspace_id
      t.foreign_key :workspaces
    end
  end
end
