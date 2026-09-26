class AddInteractiveMode < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :interactive_mode, :boolean, null: false, default: false
    add_column :workers, :interactive, :boolean, null: false, default: false
  end
end
