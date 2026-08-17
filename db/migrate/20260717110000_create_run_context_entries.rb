class CreateRunContextEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :run_context_entries do |t|
      t.string :run_id, null: false
      t.string :entry_key, null: false
      t.string :kind, null: false
      t.string :status, null: false
      t.text :content, null: false
      t.string :evidence_ref
      t.string :created_by, null: false

      t.timestamps
    end

    add_index :run_context_entries, [ :run_id, :entry_key ], unique: true
    add_index :run_context_entries, [ :run_id, :kind ]
  end
end
