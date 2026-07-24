class AddDimensionsToTerminalSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :terminal_sessions, :cols, :integer
    add_column :terminal_sessions, :rows, :integer
  end
end
