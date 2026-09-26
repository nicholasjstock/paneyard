class DropWorkspaceMemoryEntries < ActiveRecord::Migration[8.1]
  def change
    drop_table :workspace_memory_entries do |t|
      t.text :content, null: false
      t.string :entry_key, null: false
      t.string :evidence_ref, null: false
      t.string :kind, null: false
      t.string :recorded_by, null: false
      t.string :status, null: false
      t.references :supersedes, foreign_key: { to_table: :workspace_memory_entries }
      t.references :workspace, null: false, foreign_key: true

      t.timestamps
    end
  end
end
