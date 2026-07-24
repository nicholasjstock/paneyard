class CreateTerminalSessions < ActiveRecord::Migration[8.1]
  def change
    drop_table :workspace_chat_messages, if_exists: true
    drop_table :workspace_chats, if_exists: true

    create_table :terminal_sessions do |t|
      t.references :workspace, null: false, foreign_key: true, index: { unique: true }
      t.string :launcher_variant, null: false, default: "claude"
      t.string :status, null: false, default: "starting"
      t.string :cli_session_id
      t.integer :pid
      t.integer :process_group_id
      t.string :log_path
      t.string :exit_status_path
      t.integer :exit_code
      t.integer :signal
      t.datetime :started_at
      t.datetime :stopped_at
      t.datetime :last_attached_at
      t.timestamps
    end
  end
end
