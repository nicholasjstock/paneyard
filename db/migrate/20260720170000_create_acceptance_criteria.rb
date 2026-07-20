class CreateAcceptanceCriteria < ActiveRecord::Migration[8.1]
  def change
    create_table :acceptance_criteria do |t|
      t.string :run_id, null: false
      t.string :key, null: false
      t.text :content, null: false
      t.string :status, null: false, default: "pending"
      t.string :evidence_ref
      t.references :parent, foreign_key: { to_table: :acceptance_criteria }
      t.timestamps
    end
    add_index :acceptance_criteria, [ :run_id, :key ], unique: true

    create_table :acceptance_criterion_steps do |t|
      t.references :acceptance_criterion, null: false, foreign_key: { to_table: :acceptance_criteria }
      t.string :run_id, null: false
      t.string :lineage_key, null: false
      t.timestamps
    end
    add_index :acceptance_criterion_steps, [ :acceptance_criterion_id, :lineage_key ]
  end
end
