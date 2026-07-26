class RemoveClaudeCodexFieldsFromTerminalSessions < ActiveRecord::Migration[8.1]
  def change
    remove_column :terminal_sessions, :launcher_variant, :string
    remove_column :terminal_sessions, :cli_session_id, :string
  end
end
