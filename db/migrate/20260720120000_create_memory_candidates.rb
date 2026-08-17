class CreateMemoryCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :memory_candidates do |t|
      t.string :candidate_id, null: false
      t.string :run_id, null: false
      t.string :worker_id
      t.string :lineage_key, null: false
      t.string :role
      t.string :status, null: false, default: "proposed"
      t.text :approach, null: false
      t.text :reason, null: false
      t.text :next_approach
      t.timestamps
    end

    add_index :memory_candidates, :candidate_id, unique: true
    add_index :memory_candidates, [ :run_id, :lineage_key ]
    add_index :memory_candidates, :status
  end
end
