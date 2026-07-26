class AddPortToRunCommands < ActiveRecord::Migration[8.1]
  def change
    add_column :run_commands, :port, :integer
  end
end
