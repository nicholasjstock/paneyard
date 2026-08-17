class CreateWorkspaceMemoryEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :workspace_memory_entries do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :entry_key, null: false
      t.string :kind, null: false
      t.string :status, null: false
      t.text :content, null: false
      t.string :evidence_ref, null: false
      t.string :recorded_by, null: false
      t.references :supersedes, foreign_key: { to_table: :workspace_memory_entries }

      t.timestamps
    end

    add_index :workspace_memory_entries, [ :workspace_id, :entry_key ]
    add_index :workspace_memory_entries, [ :workspace_id, :status ]
  end
end
