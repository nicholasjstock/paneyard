class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces do |t|
      t.string :name, null: false
      t.string :root_path, null: false

      t.timestamps
    end
    add_index :workspaces, :name, unique: true
    add_index :workspaces, :root_path, unique: true
  end
end
