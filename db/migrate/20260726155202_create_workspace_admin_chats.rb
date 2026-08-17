class CreateWorkspaceAdminChats < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_admin_chats do |t|
      t.references :workspace, null: false, foreign_key: true, index: { unique: true }
      t.string :active_provider, null: false, default: "claude"
      t.string :claude_session_id
      t.string :codex_session_id
      t.string :claude_model
      t.string :codex_model
      t.string :active_turn_id
      t.string :status, null: false, default: "idle"
      t.text :last_error

      t.timestamps
    end
  end
end
