class CreatePlannerDecisionAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :planner_decision_attempts do |t|
      t.references :planner_decision, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.string :model_tier, null: false
      t.string :model
      t.string :outcome, null: false
      t.string :disposition, null: false, default: "proposed"
      t.json :proposal, null: false, default: {}
      t.json :usage, null: false, default: {}
      t.text :rejection_reason

      t.timestamps
    end

    add_index :planner_decision_attempts, [ :planner_decision_id, :sequence ], unique: true
  end
end
